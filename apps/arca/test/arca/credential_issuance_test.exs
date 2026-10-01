# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CredentialIssuanceTest do
  @moduledoc """
  A session or a key is written in the issuance transaction
  (`Arca.SecurityTransitions.Issuance`): the rows its standing rests on
  locked and reread, the caller's policy asked over them, the credential
  written only if it agrees.

  Under two real connections, outside the sandbox, an issuance and a
  denial serialize in both orders: an issuance waiting behind a denial
  reads the denial's commit — and the database's own time after the wait
  — and refuses; a denial waiting behind an issuance retires the
  credential the issuance just wrote. On PostgreSQL the waiter blocks on
  the person's row; on SQLite at the lock its transaction takes at entry.

  A paired device's issuance holds its paired client the same way, after
  the person, the athanor and the seat: a revocation of the client that
  commits while the issuance holds those, before it reaches the client,
  is what the issuance reads; one that starts once the issuance holds the
  client waits for the credential.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.Schemas.{
    ApiKey,
    Athanor,
    CellLease,
    DeviceCertificate,
    ExternalIdentity,
    Membership,
    PairedClient,
    PairingInvitation,
    Session,
    User,
    VaultEntry,
    Webhook
  }

  alias Arca.SecurityTransitions
  alias Arca.SecurityTransitions.Issuance
  alias Ecto.Adapters.SQL.Sandbox

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
  defp server, do: Prima.Actor.system()
  defp admit, do: fn _rows -> :ok end
  defp postgres?, do: Arca.Repo.adapter() == Ecto.Adapters.Postgres

  setup do
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()
    user_id = Prima.UUID7.generate_id(Prima.PersonId.prefix())
    athanor_id = Prima.UUID7.generate_id("ath")

    unboxed(fn ->
      {:ok, _} =
        Arca.Users.mint(
          server(),
          %{
            id: user_id,
            provider: "github",
            email: "ci#{n}@example.com",
            email_verified: true,
            first_seen_at: now,
            last_seen_at: now,
            created_at: now,
            updated_at: now
          },
          %{
            key: "github|https://github.com|ci#{n}",
            provider: "github",
            issuer: "https://github.com",
            subject: "ci#{n}",
            first_seen_at: now,
            last_seen_at: now
          }
        )

      {:ok, _} =
        Arca.Athanors.insert(server(), %{
          id: athanor_id,
          kind: "group",
          name: "CI #{n}",
          slug: "ci-#{n}",
          created_by: user_id
        })
    end)

    {:ok, seat} =
      unboxed(fn ->
        Arca.Members.seat(Prima.Actor.in_athanor(athanor_id), %{user_id: user_id, added_by: "x"})
      end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(where(PairingInvitation, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(Webhook, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(VaultEntry, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(DeviceCertificate, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(PairedClient, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(Membership, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(Membership, user_id: ^user_id))
        Arca.Repo.delete_all(where(Session, user_id: ^user_id))
        Arca.Repo.delete_all(where(ApiKey, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(ExternalIdentity, user_id: ^user_id))
        Arca.Repo.delete_all(where(User, id: ^user_id))
        Arca.Repo.delete_all(where(Athanor, id: ^athanor_id))
      end)
    end)

    {:ok, user_id: user_id, athanor_id: athanor_id, seat_id: seat.id}
  end

  defp targets(user_id, athanor_id),
    do: %{user_id: user_id, athanor_id: athanor_id, membership_id: nil, source: nil}

  # The identity domain's policy in miniature: the person and the athanor
  # active at the generations the issuing context read (1, at birth).
  defp at_birth(test) do
    fn rows ->
      send(test, {:read, rows})

      if rows.user.status == "active" and rows.user.security_generation == 1 and
           rows.athanor.status == "active" and rows.athanor.security_generation == 1,
         do: :ok,
         else: {:error, :stale_generation}
    end
  end

  defp session_attrs(user_id, athanor_id) do
    %{
      user_id: user_id,
      provider: "github",
      athanor_id: athanor_id,
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    }
  end

  defp key_attrs(user_id, athanor_id) do
    n = System.unique_integer([:positive])

    %{
      name: "ci-key-#{n}",
      key_hash: :crypto.hash(:sha256, "ci-key-#{n}"),
      key_prefix: "cyfr_sk_ci",
      type: "service",
      created_by: user_id,
      athanor_id: athanor_id
    }
  end

  defp paused_denial(user_id) do
    test = self()

    Task.async(fn ->
      unboxed(fn ->
        SecurityTransitions.deny_user(server(), user_id,
          verify: fn _rows ->
            send(test, :denial_holds)

            receive do
              :go -> send(test, {:released_at, Arca.ServerMetaStorage.now!()})
            end

            :ok
          end
        )
      end)
    end)
  end

  defp paused(test, verify) do
    fn rows ->
      send(test, :issuance_holds)

      receive do
        :go -> verify.(rows)
      end
    end
  end

  describe "an issuance waiting behind a denial" do
    test "a session reads the denial's commit and fresh time, and is refused", %{
      user_id: user_id,
      athanor_id: athanor_id
    } do
      test = self()
      denier = paused_denial(user_id)
      assert_receive :denial_holds, 5_000
      hash = :crypto.strong_rand_bytes(32)

      issuer =
        Task.async(fn ->
          unboxed(fn ->
            Arca.SessionStorage.create_session(hash, session_attrs(user_id, athanor_id),
              lock: targets(user_id, athanor_id),
              verify: at_birth(test)
            )
          end)
        end)

      refute Task.yield(issuer, 300), "the issuance decided while the denial held the person"
      send(denier.pid, :go)
      assert {:ok, %{transitioned: true}} = Task.await(denier, 25_000)
      assert_receive {:released_at, released_at}

      assert {:error, :stale_generation} = Task.await(issuer, 25_000)
      assert_receive {:read, rows}
      assert rows.user.status == "denied"
      assert rows.user.security_generation == 2
      assert DateTime.compare(rows.now, released_at) != :lt

      refute unboxed(fn -> Arca.Repo.exists?(where(Session, token_hash: ^hash)) end)
    end

    test "a key reads the denial's commit and is refused", %{
      user_id: user_id,
      athanor_id: athanor_id
    } do
      test = self()

      # The athanor stays open: the person is one of two, so the denial
      # leaves the group standing and the refusal is the person's.
      other = Prima.UUID7.generate_id(Prima.PersonId.prefix())

      unboxed(fn ->
        Arca.Members.seat(Prima.Actor.in_athanor(athanor_id), %{user_id: other, added_by: "x"})
      end)

      denier = paused_denial(user_id)
      assert_receive :denial_holds, 5_000
      attrs = key_attrs(user_id, athanor_id)

      issuer =
        Task.async(fn ->
          unboxed(fn ->
            Arca.ApiKeyStorage.create_key(attrs,
              lock: targets(user_id, athanor_id),
              verify: at_birth(test)
            )
          end)
        end)

      refute Task.yield(issuer, 300)
      send(denier.pid, :go)
      assert {:ok, _} = Task.await(denier, 25_000)
      assert {:error, :stale_generation} = Task.await(issuer, 25_000)

      refute unboxed(fn -> Arca.Repo.exists?(where(ApiKey, key_hash: ^attrs.key_hash)) end)
    end

    test "a rotation reads the archive's commit and is refused", %{
      user_id: user_id,
      athanor_id: athanor_id
    } do
      test = self()
      attrs = key_attrs(user_id, athanor_id)

      :ok =
        unboxed(fn ->
          Arca.ApiKeyStorage.create_key(attrs,
            lock: targets(user_id, athanor_id),
            verify: admit()
          )
        end)

      archiver =
        Task.async(fn ->
          unboxed(fn ->
            SecurityTransitions.archive_athanor(server(), athanor_id,
              verify: fn _rows ->
                send(test, :archive_holds)

                receive do
                  :go -> :ok
                end
              end
            )
          end)
        end)

      assert_receive :archive_holds, 5_000

      rotator =
        Task.async(fn ->
          unboxed(fn ->
            Arca.ApiKeyStorage.rotate_key(
              Prima.Actor.in_athanor(athanor_id),
              attrs.name,
              :crypto.hash(:sha256, "rotated"),
              "cyfr_sk_rot",
              lock: targets(user_id, athanor_id),
              verify: at_birth(test)
            )
          end)
        end)

      refute Task.yield(rotator, 300)
      send(archiver.pid, :go)
      assert {:ok, %{transitioned: true}} = Task.await(archiver, 25_000)
      assert {:error, :stale_generation} = Task.await(rotator, 25_000)

      assert unboxed(fn ->
               Arca.Repo.one(from(k in ApiKey, where: k.name == ^attrs.name, select: k.revoked))
             end)
    end
  end

  describe "a denial waiting behind an issuance" do
    test "retires the session the issuance wrote", %{user_id: user_id, athanor_id: athanor_id} do
      test = self()
      hash = :crypto.strong_rand_bytes(32)

      issuer =
        Task.async(fn ->
          unboxed(fn ->
            Arca.SessionStorage.create_session(hash, session_attrs(user_id, athanor_id),
              lock: targets(user_id, athanor_id),
              verify: paused(test, at_birth(test))
            )
          end)
        end)

      assert_receive :issuance_holds, 5_000

      denier =
        Task.async(fn ->
          unboxed(fn -> SecurityTransitions.deny_user(server(), user_id, verify: admit()) end)
        end)

      refute Task.yield(denier, 300), "the denial decided while the issuance held the person"
      send(issuer.pid, :go)
      assert :ok = Task.await(issuer, 25_000)

      assert {:ok, change} = Task.await(denier, 25_000)
      assert change.revoked_session_hashes == [hash]
      refute unboxed(fn -> Arca.Repo.exists?(where(Session, token_hash: ^hash)) end)
    end

    test "revokes the key the issuance wrote, and a rotation's new secret with it", %{
      user_id: user_id,
      athanor_id: athanor_id
    } do
      test = self()
      attrs = key_attrs(user_id, athanor_id)

      :ok =
        unboxed(fn ->
          Arca.ApiKeyStorage.create_key(attrs,
            lock: targets(user_id, athanor_id),
            verify: admit()
          )
        end)

      rotated = :crypto.hash(:sha256, "rotated-#{System.unique_integer([:positive])}")

      rotator =
        Task.async(fn ->
          unboxed(fn ->
            Arca.ApiKeyStorage.rotate_key(
              Prima.Actor.in_athanor(athanor_id),
              attrs.name,
              rotated,
              "cyfr_sk_rot",
              lock: targets(user_id, athanor_id),
              verify: paused(test, at_birth(test))
            )
          end)
        end)

      assert_receive :issuance_holds, 5_000

      denier =
        Task.async(fn ->
          unboxed(fn -> SecurityTransitions.deny_user(server(), user_id, verify: admit()) end)
        end)

      refute Task.yield(denier, 300)
      send(rotator.pid, :go)
      assert :ok = Task.await(rotator, 25_000)
      assert {:ok, change} = Task.await(denier, 25_000)
      assert length(change.revoked_api_key_ids) == 1

      assert {:ok, %{revoked: true}} =
               unboxed(fn -> Arca.ApiKeyStorage.get_key_by_hash(rotated) end)
    end
  end

  # ---------------------------------------------------------------------------
  # A paired device's issuance
  # ---------------------------------------------------------------------------

  defp device_targets(user_id, athanor_id, seat_id, device) do
    %{
      user_id: user_id,
      athanor_id: athanor_id,
      membership_id: seat_id,
      source: {:device, device.client_id, device.expires_at}
    }
  end

  # The identity domain's device policy in miniature: the client active and
  # the certificate it presented unrevoked.
  defp device_stands(test) do
    fn rows ->
      send(test, {:read, rows})

      case rows.source do
        %{kind: :device, row: %{standing: "active"}, certificates: [%{state: "active"}]} -> :ok
        _ended -> {:error, :not_standing}
      end
    end
  end

  # A telemetry handler on every repo statement: the process that put
  # `{test, point}` under `:issuance_hold` is held at its first statement
  # `point` names, until the test releases it.
  @doc false
  def hold(_event, _measurements, metadata, _config) do
    with {test, point} <- Process.get(:issuance_hold),
         true <- point.(metadata) do
      Process.delete(:issuance_hold)
      send(test, {:issuance_held, self()})

      receive do
        :release -> :ok
      end
    end

    :ok
  end

  defp hold_issuances! do
    handler = "credential-issuance-hold-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(handler, [:arca, :repo, :query], &__MODULE__.hold/4, nil)
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # Inside the issuance's transaction, the last moment another writer can
  # still commit before the issuance reaches the client: on PostgreSQL once
  # the seat is locked; on SQLite once the transaction has begun, before it
  # takes the one write lock.
  defp before_the_client(%{source: "memberships", query: query}),
    do: postgres?() and query =~ "FOR UPDATE"

  defp before_the_client(%{query: "begin"}), do: not postgres?()
  defp before_the_client(_metadata), do: false

  # The connection's backend, on PostgreSQL, for the test to watch it wait.
  defp backend do
    if postgres?(), do: hd(hd(Arca.Repo.query!("SELECT pg_backend_pid()").rows))
  end

  # On PostgreSQL, `backend` is blocked on a lock in a statement naming
  # every one of `fragments`.
  defp await_wait!(backend, fragments, tries \\ 250) do
    [[type, query]] =
      unboxed(fn ->
        Arca.Repo.query!(
          "SELECT wait_event_type, query FROM pg_stat_activity WHERE pid = $1",
          [backend]
        ).rows
      end)

    cond do
      type == "Lock" and Enum.all?(fragments, &String.contains?(query, &1)) ->
        :ok

      tries == 0 ->
        flunk("backend #{backend} is not waiting at #{inspect(fragments)}: #{type} #{query}")

      true ->
        Process.sleep(20)
        await_wait!(backend, fragments, tries - 1)
    end
  end

  describe "a paired device's issuance" do
    test "reads a revocation of its client that commits before it reaches the client, and is refused",
         %{user_id: user_id, athanor_id: athanor_id, seat_id: seat_id} do
      test = self()
      hold_issuances!()
      device = unboxed(fn -> Arca.CredentialIssuanceTest.Device.record!(user_id, athanor_id) end)
      attrs = key_attrs(user_id, athanor_id)

      issuer =
        Task.async(fn ->
          Process.put(:issuance_hold, {test, &before_the_client/1})

          unboxed(fn ->
            Arca.ApiKeyStorage.create_key(attrs,
              lock: device_targets(user_id, athanor_id, seat_id, device),
              verify: device_stands(test)
            )
          end)
        end)

      assert_receive {:issuance_held, holder}, 5_000

      # The revocation commits inside the issuance's transaction: on
      # PostgreSQL while the issuance holds the person, the athanor and the
      # seat, which a client's revocation does not wait for.
      assert {:ok, %{standing: "revoked"}} =
               unboxed(fn ->
                 Arca.PairedClients.revoke(Prima.Actor.in_athanor(athanor_id), device.client_id)
               end)

      send(holder, :release)
      assert {:error, :not_standing} = Task.await(issuer, 25_000)

      assert_receive {:read, %{source: %{row: row, certificates: [certificate]}}}
      assert {row.standing, certificate.state} == {"revoked", "revoked"}
      refute unboxed(fn -> Arca.Repo.exists?(where(ApiKey, key_hash: ^attrs.key_hash)) end)
    end

    test "holds its client: a revocation that starts once it holds the client waits for the credential",
         %{user_id: user_id, athanor_id: athanor_id, seat_id: seat_id} do
      test = self()
      device = unboxed(fn -> Arca.CredentialIssuanceTest.Device.record!(user_id, athanor_id) end)
      attrs = key_attrs(user_id, athanor_id)

      issuer =
        Task.async(fn ->
          unboxed(fn ->
            Arca.ApiKeyStorage.create_key(attrs,
              lock: device_targets(user_id, athanor_id, seat_id, device),
              verify: paused(test, device_stands(test))
            )
          end)
        end)

      assert_receive :issuance_holds, 5_000

      revoker =
        Task.async(fn ->
          unboxed(fn ->
            send(test, {:revoker, backend()})
            Arca.PairedClients.revoke(Prima.Actor.in_athanor(athanor_id), device.client_id)
          end)
        end)

      assert_receive {:revoker, pid}, 5_000
      if postgres?(), do: await_wait!(pid, [~s("paired_clients"), "FOR UPDATE"])
      refute Task.yield(revoker, 300), "the revocation decided while the issuance held the client"

      send(issuer.pid, :go)
      assert :ok = Task.await(issuer, 25_000)
      assert {:ok, %{standing: "revoked"}} = Task.await(revoker, 25_000)

      # The issuance was admitted before the revocation, and its credential
      # stands: retiring the client takes back nothing it issued.
      assert {:ok, %{revoked: false}} =
               unboxed(fn -> Arca.ApiKeyStorage.get_key_by_hash(attrs.key_hash) end)
    end
  end

  # ---------------------------------------------------------------------------
  # A paired device's other credential writes
  # ---------------------------------------------------------------------------

  # Each write a device makes that is not a key or a session, run under the
  # device's issuance (`Arca.SecurityTransitions.Issuance.held/2`, or
  # `open/3`'s source): its fixture laid first, the write as a function of
  # the issuance options, and whether it wrote.
  defp other_write(:webhook_create, user_id, athanor_id, _seat_id) do
    attrs = webhook_attrs(user_id, athanor_id)

    {&Arca.WebhookStorage.create_webhook(attrs, &1),
     fn -> Arca.Repo.exists?(where(Webhook, athanor_id: ^athanor_id, name: ^attrs.name)) end}
  end

  defp other_write(:webhook_rotate, user_id, athanor_id, _seat_id) do
    attrs = webhook_attrs(user_id, athanor_id)
    :ok = Arca.WebhookStorage.create_webhook(attrs)
    grace = DateTime.add(DateTime.utc_now(), 3600, :second)

    {&Arca.WebhookStorage.rotate_secret(
       Prima.Actor.in_athanor(athanor_id),
       attrs.name,
       "rotated-secret",
       grace,
       &1
     ),
     fn ->
       Arca.Repo.one!(
         from(w in Webhook,
           where: w.athanor_id == ^athanor_id and w.name == ^attrs.name,
           select: w.secret_encrypted
         )
       ) != attrs.secret_encrypted
     end}
  end

  defp other_write(:vault_put, _user_id, athanor_id, _seat_id) do
    actor = Prima.Actor.in_athanor(athanor_id)
    name = "glass-entry-#{System.unique_integer([:positive])}"

    {&Arca.VaultStorage.put(actor, %{name: name, kind: "api_key", sealed_payload: "sealed"}, &1),
     fn -> match?({:ok, _}, Arca.VaultStorage.get_by_name(actor, name)) end}
  end

  defp other_write(:vault_commit, _user_id, athanor_id, _seat_id) do
    actor = Prima.Actor.in_athanor(athanor_id)
    name = "glass-entry-#{System.unique_integer([:positive])}"

    {:ok, entry} =
      Arca.VaultStorage.put(actor, %{name: name, kind: "api_key", sealed_payload: "v1"})

    plan = %{expected_rev: entry.payload_rev, sealed_payload: "v2", status: nil, rebind: nil}

    {&Arca.VaultStorage.commit_payload(actor, entry.id, plan, &1),
     fn -> match?({:ok, %{sealed_payload: "v2"}}, Arca.VaultStorage.get(actor, entry.id)) end}
  end

  defp other_write(:invitation_open, user_id, athanor_id, seat_id) do
    actor = Prima.Actor.in_athanor(athanor_id)
    secret_hash = Prima.Digest.sha256("glass-#{System.unique_integer([:positive])}")

    open = fn opts ->
      attrs = %{
        user_id: user_id,
        membership_id: seat_id,
        secret_hash: secret_hash,
        audience_home: "https://home.example",
        lifetime_ms: 60_000,
        source: get_in(opts, [:lock, :source])
      }

      case Arca.PairingInvitations.open(actor, attrs, Keyword.fetch!(opts, :verify)) do
        {:ok, _invitation} -> :ok
        {:error, _reason} = refusal -> refusal
      end
    end

    {open, fn -> Arca.Repo.exists?(where(PairingInvitation, secret_hash: ^secret_hash)) end}
  end

  # An invitation is opened only by a member that owns its slot
  # (`Arca.ControlPlane.verify_held/1`): this member's slot, taken on a real
  # connection so every connection reads the lease, as
  # `Arca.PairingInvitationsTest` takes it; the lease row, the process-wide
  # standing and the claim switch are given back after the case. The other
  # writes take no slot.
  defp slot_for(:invitation_open) do
    saved = Map.new(@slot_keys, &{&1, :persistent_term.get(&1, :absent)})
    claim = Application.get_env(:arca, :control_plane_claim_enabled)
    node = "node-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      unboxed(fn -> Arca.Repo.delete_all(from(l in CellLease, where: l.node == ^node)) end)

      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end

      if is_nil(claim),
        do: Application.delete_env(:arca, :control_plane_claim_enabled),
        else: Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)

    Application.put_env(:arca, :control_plane_claim_enabled, true)
    {:ok, _slot} = unboxed(fn -> Arca.ControlPlane.take(node, node <> "#boot", 60_000) end)
    :ok
  end

  defp slot_for(_kind), do: :ok

  defp webhook_attrs(user_id, athanor_id) do
    n = System.unique_integer([:positive])

    %{
      name: "glass-hook-#{n}",
      slug: "wh_glass_#{n}",
      target_ref: "reagent:local.hook-target:1.0.0",
      secret_encrypted: "sealed-secret-#{n}",
      athanor_id: athanor_id,
      profile_id: "prof_fixture",
      created_by: user_id
    }
  end

  describe "a paired device's other credential writes" do
    for kind <- [:webhook_create, :webhook_rotate, :vault_put, :vault_commit, :invitation_open] do
      test "#{kind}: a revocation of the client committing before the write reaches it writes nothing",
           %{user_id: user_id, athanor_id: athanor_id, seat_id: seat_id} do
        test = self()
        slot_for(unquote(kind))
        hold_issuances!()

        device =
          unboxed(fn -> Arca.CredentialIssuanceTest.Device.record!(user_id, athanor_id) end)

        {write, written?} =
          unboxed(fn -> other_write(unquote(kind), user_id, athanor_id, seat_id) end)

        opts = [
          lock: device_targets(user_id, athanor_id, seat_id, device),
          verify: device_stands(test)
        ]

        writer =
          Task.async(fn ->
            Process.put(:issuance_hold, {test, &before_the_client/1})
            unboxed(fn -> write.(opts) end)
          end)

        assert_receive {:issuance_held, holder}, 5_000

        assert {:ok, %{standing: "revoked"}} =
                 unboxed(fn ->
                   Arca.PairedClients.revoke(Prima.Actor.in_athanor(athanor_id), device.client_id)
                 end)

        send(holder, :release)
        assert {:error, :not_standing} = Task.await(writer, 25_000)
        refute unboxed(written?)
      end
    end

    test "an invitation holds its client: a revocation that starts once it holds the client waits",
         %{user_id: user_id, athanor_id: athanor_id, seat_id: seat_id} do
      test = self()
      slot_for(:invitation_open)
      device = unboxed(fn -> Arca.CredentialIssuanceTest.Device.record!(user_id, athanor_id) end)

      {open, written?} =
        unboxed(fn -> other_write(:invitation_open, user_id, athanor_id, seat_id) end)

      opts = [
        lock: device_targets(user_id, athanor_id, seat_id, device),
        verify: paused(test, device_stands(test))
      ]

      opener = Task.async(fn -> unboxed(fn -> open.(opts) end) end)
      assert_receive :issuance_holds, 5_000

      revoker =
        Task.async(fn ->
          unboxed(fn ->
            send(test, {:revoker, backend()})
            Arca.PairedClients.revoke(Prima.Actor.in_athanor(athanor_id), device.client_id)
          end)
        end)

      assert_receive {:revoker, pid}, 5_000
      if postgres?(), do: await_wait!(pid, [~s("paired_clients"), "FOR UPDATE"])

      refute Task.yield(revoker, 300),
             "the revocation decided while the invitation held the client"

      send(opener.pid, :go)
      assert :ok = Task.await(opener, 25_000)
      assert {:ok, %{standing: "revoked"}} = Task.await(revoker, 25_000)
      assert unboxed(written?)
    end
  end
end

defmodule Arca.CredentialIssuanceTest.Device do
  @moduledoc false
  # A paired device of a person in an athanor, as a pairing records one:
  # its client row and the certificate it stands under, whose expiry is a
  # millisecond instant, as every certificate's is. Written on the
  # caller's connection.

  alias Arca.Schemas.{DeviceCertificate, PairedClient}

  @spec record!(String.t(), String.t(), keyword()) :: %{
          client_id: String.t(),
          expires_at: DateTime.t()
        }
  def record!(user_id, athanor_id, opts \\ []) do
    now = DateTime.utc_now()
    expires_at = now |> DateTime.add(3600, :second) |> DateTime.truncate(:millisecond)
    device_key = :crypto.strong_rand_bytes(32)
    client_id = Prima.UUID7.generate_id("pcl")

    {1, _} =
      Arca.Repo.insert_all(PairedClient, [
        %{
          id: client_id,
          athanor_id: athanor_id,
          user_id: user_id,
          source_kind: "device_cert",
          source_id: client_id,
          device_public_key: device_key,
          standing: "active",
          inserted_at: now,
          updated_at: now
        }
      ])

    for at <- [expires_at | Keyword.get(opts, :also_expiring, [])] do
      certificate!(user_id, athanor_id, client_id, device_key, at, opts)
    end

    %{client_id: client_id, expires_at: expires_at}
  end

  defp certificate!(user_id, athanor_id, client_id, device_key, expires_at, opts) do
    now = DateTime.utc_now()
    bytes = :crypto.strong_rand_bytes(64)
    {kind, identifier} = Keyword.get(opts, :subject, {"local", nil})

    {1, _} =
      Arca.Repo.insert_all(DeviceCertificate, [
        %{
          id: Prima.UUID7.generate_id("dct"),
          athanor_id: athanor_id,
          paired_client_id: client_id,
          user_id: user_id,
          subject_kind: kind,
          identifier: identifier,
          key_epoch: if(identifier, do: Prima.Digest.sha256("epoch-#{identifier}")),
          device_public_key: device_key,
          issuing_home: "https://home.example",
          audience_home: "https://home.example",
          not_before: now,
          expires_at: usec(expires_at),
          certificate: bytes,
          digest: Prima.Digest.sha256(bytes),
          state: "active",
          inserted_at: now,
          updated_at: now
        }
      ])
  end

  defp usec(%DateTime{microsecond: {us, _precision}} = at), do: %{at | microsecond: {us, 6}}
end

defmodule Arca.CredentialIssuanceSandboxTest do
  @moduledoc """
  The issuance transaction on one connection: the policy sees the locked
  rows (nil where there is none), and a refusal from it or from the write
  leaves nothing behind. A paired device's source is locked in the
  standing order and handed to the policy narrowed.
  """

  use ExUnit.Case, async: false

  alias Arca.CredentialIssuanceTest.Device
  alias Arca.SecurityTransitions.Issuance

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  test "the policy is handed nil for rows that do not exist, and its refusal writes nothing" do
    test = self()
    hash = :crypto.strong_rand_bytes(32)

    assert {:error, :not_standing} =
             Arca.SessionStorage.create_session(
               hash,
               %{
                 user_id: "usr_nobody",
                 provider: "github",
                 expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
               },
               lock: %{
                 user_id: "usr_nobody",
                 athanor_id: "ath_nowhere",
                 membership_id: "mem_none",
                 source: {:api_key, "key_none"}
               },
               verify: fn rows ->
                 send(test, {:rows, rows})
                 {:error, :not_standing}
               end
             )

    assert_received {:rows, %{user: nil, athanor: nil, membership: nil, source: source, now: now}}
    assert source == %{kind: :api_key, row: nil}
    assert %DateTime{} = now
    assert {:error, :not_found} = Arca.SessionStorage.get_session(hash)
  end

  test "a refused write rolls the transaction back" do
    assert {:error, :not_this_time} =
             Issuance.run(
               %{user_id: "usr_nobody", athanor_id: nil, membership_id: nil, source: nil},
               fn _rows -> :ok end,
               fn _rows -> {:error, :not_this_time} end
             )
  end

  describe "a paired device's source" do
    test "is locked after the person, the athanor and the seat: the client, then its certificate" do
      %{user_id: user_id, athanor_id: athanor_id, seat_id: seat_id} = standing!()
      device = Device.record!(user_id, athanor_id)
      test = self()

      sources =
        ~w(users athanors memberships paired_clients device_certificates person_identities)

      handler = "credential-issuance-order-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:arca, :repo, :query],
          fn _event, _measurements, meta, _config ->
            if self() == test and meta[:source] in sources,
              do: send(test, {:statement, meta[:source], meta[:query]})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, :written} =
               Issuance.run(
                 targets(user_id, athanor_id, seat_id, device),
                 fn _rows -> :ok end,
                 fn _rows -> {:ok, :written} end
               )

      :telemetry.detach(handler)
      statements = statements()

      # Person, athanor, seat, client, its certificate: the standing order,
      # and the identity row read last, under the person's lock.
      assert Enum.map(statements, &elem(&1, 0)) == sources

      if Arca.Repo.adapter() == Ecto.Adapters.Postgres do
        for {source, query} <- Enum.take(statements, 5) do
          assert query =~ "FOR UPDATE", "#{source} is not locked: #{query}"
        end

        assert {"person_identities", read} = List.last(statements)
        refute read =~ "FOR UPDATE"
      end
    end

    test "hands the policy the client, its certificate at the caller's expiry and the person's identity row, narrowed" do
      %{user_id: user_id, athanor_id: athanor_id, seat_id: seat_id} = standing!()
      renewed = DateTime.add(DateTime.utc_now(), 7200, :second)
      identifier = "per_" <> Prima.Digest.sha256_hex("remote-#{System.unique_integer()}")

      device =
        Device.record!(user_id, athanor_id,
          subject: {"identity", identifier},
          also_expiring: [renewed]
        )

      now = DateTime.utc_now()

      {1, _} =
        Arca.Repo.insert_all(Arca.Schemas.PersonIdentity, [
          %{
            id: Prima.UUID7.generate_id("pid"),
            user_id: user_id,
            provenance: "remote",
            enrollment: "enrolled",
            identifier: identifier,
            directory_url: "https://directory.example",
            revision: 1,
            inserted_at: now,
            updated_at: now
          }
        ])

      test = self()

      assert {:ok, :written} =
               Issuance.run(
                 targets(user_id, athanor_id, seat_id, device),
                 fn rows ->
                   send(test, {:rows, rows})
                   :ok
                 end,
                 fn _rows -> {:ok, :written} end
               )

      assert_received {:rows, %{source: source, now: %DateTime{}}}
      assert source.kind == :device

      assert source.row == %{
               id: device.client_id,
               user_id: user_id,
               athanor_id: athanor_id,
               source_kind: "device_cert",
               standing: "active"
             }

      # Only the certificate the caller stands under, not the client's
      # later one, and none of its bytes or key.
      assert [certificate] = source.certificates

      assert Map.keys(certificate) |> Enum.sort() ==
               ~w(expires_at id identifier key_epoch paired_client_id state subject_kind user_id)a

      assert DateTime.compare(certificate.expires_at, device.expires_at) == :eq

      assert {certificate.paired_client_id, certificate.subject_kind, certificate.identifier} ==
               {device.client_id, "identity", identifier}

      assert source.identity == %{user_id: user_id, provenance: "remote", identifier: identifier}
    end

    test "names nothing that is not there: no client, no certificate, no identity row" do
      %{user_id: user_id, athanor_id: athanor_id, seat_id: seat_id} = standing!()
      test = self()
      missing = %{client_id: "pcl_none", expires_at: DateTime.utc_now()}

      assert {:error, :not_standing} =
               Issuance.run(
                 targets(user_id, athanor_id, seat_id, missing),
                 fn rows ->
                   send(test, {:rows, rows})
                   {:error, :not_standing}
                 end,
                 fn _rows -> {:ok, :written} end
               )

      assert_received {:rows, %{source: source}}
      assert source == %{kind: :device, row: nil, certificates: [], identity: nil, head: nil}
    end

    test "reads a remote person's cached head after their identity row, unlocked, and hands its key_epoch" do
      %{user_id: user_id, athanor_id: athanor_id, seat_id: seat_id} = standing!()
      identifier = "per_" <> Prima.Digest.sha256_hex("remote-#{System.unique_integer()}")
      key_epoch = Prima.Digest.sha256("epoch-#{identifier}")
      device = Device.record!(user_id, athanor_id, subject: {"identity", identifier})
      remote_identity!(user_id, identifier)
      cached_head!(identifier, key_epoch)
      test = self()

      sources =
        ~w(users athanors memberships paired_clients device_certificates person_identities directory_heads)

      handler = "credential-issuance-head-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:arca, :repo, :query],
          fn _event, _measurements, meta, _config ->
            if self() == test and meta[:source] in sources,
              do: send(test, {:statement, meta[:source], meta[:query]})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, :written} =
               Issuance.run(
                 targets(user_id, athanor_id, seat_id, device),
                 fn rows ->
                   send(test, {:rows, rows})
                   :ok
                 end,
                 fn _rows -> {:ok, :written} end
               )

      :telemetry.detach(handler)
      statements = statements()

      # The standing order, then the identity row and the head it names,
      # each read under the person's lock that a head's advance takes first.
      assert Enum.map(statements, &elem(&1, 0)) == sources

      if Arca.Repo.adapter() == Ecto.Adapters.Postgres do
        for {source, query} <- Enum.take(statements, 5) do
          assert query =~ "FOR UPDATE", "#{source} is not locked: #{query}"
        end

        for {source, query} <- Enum.drop(statements, 5) do
          refute query =~ "FOR UPDATE", "#{source} is locked: #{query}"
        end
      end

      assert_received {:rows, %{source: %{head: head}}}
      assert head == %{identifier: identifier, key_epoch: key_epoch}
    end
  end

  defp remote_identity!(user_id, identifier) do
    now = DateTime.utc_now()

    {1, _} =
      Arca.Repo.insert_all(Arca.Schemas.PersonIdentity, [
        %{
          id: Prima.UUID7.generate_id("pid"),
          user_id: user_id,
          provenance: "remote",
          enrollment: "enrolled",
          identifier: identifier,
          directory_url: "https://directory.example",
          revision: 1,
          inserted_at: now,
          updated_at: now
        }
      ])
  end

  defp cached_head!(identifier, key_epoch) do
    now = DateTime.utc_now()

    {1, _} =
      Arca.Repo.insert_all(Arca.Schemas.DirectoryHead, [
        %{
          identifier: identifier,
          genesis: "genesis-bytes",
          directory_url: "https://directory.example",
          head_hash: key_epoch,
          key_epoch: key_epoch,
          recovery_epoch: key_epoch,
          state: "{}",
          verified_at: now,
          revision: 1,
          inserted_at: now,
          updated_at: now
        }
      ])
  end

  defp targets(user_id, athanor_id, seat_id, device) do
    %{
      user_id: user_id,
      athanor_id: athanor_id,
      membership_id: seat_id,
      source: {:device, device.client_id, device.expires_at}
    }
  end

  # A person seated in a group of their own, in this case's sandbox.
  defp standing! do
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()
    user_id = Prima.UUID7.generate_id(Prima.PersonId.prefix())
    athanor_id = Prima.UUID7.generate_id("ath")

    {:ok, _} =
      Arca.Users.mint(
        Prima.Actor.system(),
        %{
          id: user_id,
          provider: "github",
          email: "order#{n}@example.com",
          email_verified: true,
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        },
        %{
          key: "github|https://github.com|order#{n}",
          provider: "github",
          issuer: "https://github.com",
          subject: "order#{n}",
          first_seen_at: now,
          last_seen_at: now
        }
      )

    {:ok, _} =
      Arca.Athanors.insert(Prima.Actor.system(), %{
        id: athanor_id,
        kind: "group",
        name: "Order #{n}",
        slug: "order-#{n}",
        created_by: user_id
      })

    {:ok, seat} =
      Arca.Members.seat(Prima.Actor.in_athanor(athanor_id), %{user_id: user_id, added_by: "x"})

    %{user_id: user_id, athanor_id: athanor_id, seat_id: seat.id}
  end

  defp statements(acc \\ []) do
    receive do
      {:statement, source, query} -> statements([{source, query} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
