# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PairingInvitationsTest do
  @moduledoc """
  Pairing invitations: opened under the issuance locks and the caller's
  verifier, stored by the hash of their secret with a reserved client id;
  looked up by hash for routing alone; redeemed once, under the person,
  athanor and membership locked first and the invitation last, with its
  state, expiry and the member's ownership rechecked, the client and its
  certificate recorded and the invitation consumed in one transaction, or
  nothing. A standing transition revokes the pending ones and nothing
  resurrects them.
  """

  # Takes the cell's slot for the stale-owner case; every case restores it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{ControlPlane, DeviceCertificates, Members, PairedClients, PairingInvitations, Users}
  alias Arca.Schemas.{CellLease, PairedClient}

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    slot = hold_slot!()
    athanor = "ath_pin_#{System.unique_integer([:positive])}"
    Arca.Test.Actor.ensure_athanor_row(athanor)
    person = person!()

    {:ok, membership} =
      Members.seat(Prima.Actor.in_athanor(athanor), %{
        user_id: person.id,
        scope: "athanor",
        status: "active"
      })

    actor = %{Prima.Actor.in_athanor(athanor) | user_id: person.id}
    {:ok, actor: actor, person: person, membership: membership, slot: slot}
  end

  # The writes under test are fenced by the member's slot: a claimant runs
  # and this member holds its slot. The process-wide standing and the claim
  # switch are restored after each case.
  defp hold_slot! do
    saved = Map.new(@slot_keys, &{&1, :persistent_term.get(&1, :absent)})
    claim = Application.get_env(:arca, :control_plane_claim_enabled)

    on_exit(fn ->
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
    node = "node-#{System.unique_integer([:positive])}"
    {:ok, slot} = ControlPlane.take(node, node <> "#boot", 60_000)
    slot
  end

  defp server, do: Prima.Actor.system()

  defp person! do
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()

    {:ok, person} =
      Users.mint(
        server(),
        %{
          id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
          provider: "github",
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        },
        %{
          key: "github|https://github.com|pin#{n}",
          provider: "github",
          issuer: "https://github.com",
          subject: "pin#{n}",
          first_seen_at: now,
          last_seen_at: now
        }
      )

    person
  end

  defp admits(_locked), do: :ok

  defp open!(actor, person, membership, secret \\ nil) do
    secret = secret || "secret-#{System.unique_integer()}"

    {:ok, invitation} =
      PairingInvitations.open(
        actor,
        %{
          user_id: person.id,
          membership_id: membership.id,
          secret_hash: Prima.Digest.sha256(secret),
          audience_home: "https://home.example",
          lifetime_ms: 300_000
        },
        &admits/1
      )

    {invitation, Prima.Digest.sha256(secret)}
  end

  # The issuance a redemption runs: the paired client under the reserved
  # id, and its certificate.
  defp issue(actor) do
    fn invitation ->
      device_key = :crypto.strong_rand_bytes(32)

      with {:ok, client} <-
             PairedClients.record(actor, %{
               id: invitation.prospective_client_id,
               user_id: invitation.user_id,
               source_kind: "device_cert",
               source_id: Prima.Digest.sha256(device_key),
               device_public_key: device_key
             }),
           {:ok, cert} <-
             DeviceCertificates.record(actor, %{
               paired_client_id: client.id,
               user_id: client.user_id,
               subject_kind: "local",
               device_public_key: device_key,
               issuing_home: "https://home.example",
               audience_home: "https://home.example",
               not_before: DateTime.utc_now(),
               expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
               certificate: "cert-#{System.unique_integer()}",
               digest: Prima.Digest.sha256("cert-#{System.unique_integer()}")
             }) do
        {:ok, %{client: client, certificate: cert}}
      end
    end
  end

  test "opens under the verifier, storing the hash and reserving a client id", %{
    actor: actor,
    person: person,
    membership: membership
  } do
    me = self()

    {:ok, invitation} =
      PairingInvitations.open(
        actor,
        %{
          user_id: person.id,
          membership_id: membership.id,
          secret_hash: Prima.Digest.sha256("the secret"),
          audience_home: "https://home.example",
          lifetime_ms: 300_000
        },
        fn locked ->
          send(me, {:locked, locked.user.id, locked.membership.id})
          :ok
        end
      )

    assert_received {:locked, user_id, membership_id}
    assert {user_id, membership_id} == {person.id, membership.id}
    assert invitation.state == "pending"
    assert "pcl_" <> _ = invitation.prospective_client_id
    refute invitation.secret_hash =~ "the secret"

    assert {:error, :not_member} =
             PairingInvitations.open(
               actor,
               %{
                 user_id: person.id,
                 membership_id: membership.id,
                 secret_hash: Prima.Digest.sha256("another"),
                 audience_home: "https://home.example",
                 lifetime_ms: 300_000
               },
               fn _locked -> {:error, :not_member} end
             )
  end

  test "lookup answers routing by hash alone", %{actor: actor, person: person, membership: m} do
    {invitation, hash} = open!(actor, person, m)

    assert {:ok, routing} = PairingInvitations.lookup(hash)
    assert routing.athanor_id == actor.athanor_id
    assert routing.prospective_client_id == invitation.prospective_client_id
    refute Map.has_key?(routing, :secret_hash)
    assert {:error, :not_found} = PairingInvitations.lookup(Prima.Digest.sha256("unknown"))
  end

  test "redeems once: one client, one certificate, the invitation consumed", %{
    actor: actor,
    person: person,
    membership: m
  } do
    {invitation, hash} = open!(actor, person, m)

    assert {:ok, %{client: client, certificate: cert}} =
             PairingInvitations.consume(actor, hash, &admits/1, issue(actor))

    assert client.id == invitation.prospective_client_id
    assert cert.paired_client_id == client.id

    assert {:error, :consumed} = PairingInvitations.consume(actor, hash, &admits/1, issue(actor))
    assert {:ok, [%{state: "consumed"}]} = PairingInvitations.list(actor, state: :consumed)

    assert Arca.Repo.aggregate(
             from(p in PairedClient, where: p.athanor_id == ^actor.athanor_id),
             :count
           ) == 1
  end

  test "a failed issuance rolls everything back and the invitation stays pending", %{
    actor: actor,
    person: person,
    membership: m
  } do
    {_invitation, hash} = open!(actor, person, m)

    failing = fn invitation ->
      {:ok, _client} =
        PairedClients.record(actor, %{
          id: invitation.prospective_client_id,
          user_id: invitation.user_id,
          source_kind: "device_cert",
          source_id: "src",
          device_public_key: :crypto.strong_rand_bytes(32)
        })

      {:error, :certificate_refused}
    end

    assert {:error, :certificate_refused} =
             PairingInvitations.consume(actor, hash, &admits/1, failing)

    assert Arca.Repo.aggregate(
             from(p in PairedClient, where: p.athanor_id == ^actor.athanor_id),
             :count
           ) == 0

    assert {:ok, [%{state: "pending"}]} = PairingInvitations.list(actor, [])
  end

  test "revoked, expired, refused by standing, or asked from another athanor: nothing issued", %{
    actor: actor,
    person: person,
    membership: m
  } do
    {revoked, revoked_hash} = open!(actor, person, m)
    {:ok, %{state: "revoked"}} = PairingInvitations.revoke(actor, revoked.id)

    assert {:error, :revoked} =
             PairingInvitations.consume(actor, revoked_hash, &admits/1, issue(actor))

    {expired, expired_hash} = open!(actor, person, m)

    {1, _} =
      Arca.Repo.update_all(
        from(i in Arca.Schemas.PairingInvitation, where: i.id == ^expired.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

    assert {:error, :expired} =
             PairingInvitations.consume(actor, expired_hash, &admits/1, issue(actor))

    {_denied, denied_hash} = open!(actor, person, m)

    assert {:error, :not_a_member} =
             PairingInvitations.consume(
               actor,
               denied_hash,
               fn _ -> {:error, :not_a_member} end,
               issue(actor)
             )

    other = Prima.Actor.in_athanor("ath_pin_other")

    assert {:error, :not_found} =
             PairingInvitations.consume(other, denied_hash, &admits/1, issue(other))
  end

  test "a standing transition revokes pending invitations, and an allow never resurrects them", %{
    actor: actor,
    person: person,
    membership: m
  } do
    {invitation, _hash} = open!(actor, person, m)

    {:ok, change} =
      Arca.SecurityTransitions.leave_athanor(actor, person.id, verify: fn _ -> :ok end)

    assert change.revoked_pairing_invitation_ids == [invitation.id]

    {:ok, _} = Arca.SecurityTransitions.deny_user(server(), person.id, verify: fn _ -> :ok end)
    {:ok, _} = Arca.SecurityTransitions.allow_user(server(), person.id, verify: fn _ -> :ok end)

    assert {:ok, [%{state: "revoked"}]} = PairingInvitations.list(actor, state: :all)
  end

  describe "the member fence" do
    test "a stale owner redeems nothing", %{
      actor: actor,
      person: person,
      membership: m,
      slot: slot
    } do
      {_invitation, hash} = open!(actor, person, m)

      {1, _} =
        Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
          set: [owner: "someone-else", generation: slot.generation + 1]
        )

      assert {:error, :not_owner} =
               PairingInvitations.consume(actor, hash, &admits/1, issue(actor))

      assert {:ok, [%{state: "pending"}]} = PairingInvitations.list(actor, [])
    end
  end
end

defmodule Arca.PairingInvitationsRaceTest do
  @moduledoc """
  Redemptions of a pairing invitation racing each other, a revocation and
  the invitation's expiry, on two real connections outside the sandbox. A
  redemption takes the person's lock first and the invitation's last, and
  decides on what it reads there and on the database's time read after
  its locks: a second redemption waiting behind the first reads it
  consumed; a revocation waiting behind a redemption finds it consumed,
  and a redemption waiting behind a revocation reads it revoked; an
  invitation that expires while its redemption waits is refused. On
  PostgreSQL the waiter blocks on the row named; on SQLite at the lock
  its transaction takes at entry.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.{ControlPlane, DeviceCertificates, Members, PairedClients, PairingInvitations, Users}

  alias Arca.Schemas.{
    Athanor,
    CellLease,
    DeviceCertificate,
    ExternalIdentity,
    Membership,
    PairedClient,
    PairingInvitation,
    User
  }

  alias Ecto.Adapters.SQL.Sandbox

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  @gate 7_310_003

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
  defp server, do: Prima.Actor.system()
  defp postgres?, do: Arca.Repo.adapter() == Ecto.Adapters.Postgres
  defp admits(_locked), do: :ok

  setup do
    hold_slot!()
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()
    user_id = Prima.UUID7.generate_id(Prima.PersonId.prefix())
    athanor_id = "ath_pin_race_#{n}"

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(where(PairingInvitation, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(DeviceCertificate, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(PairedClient, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(Membership, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(ExternalIdentity, user_id: ^user_id))
        Arca.Repo.delete_all(where(User, id: ^user_id))
        Arca.Repo.delete_all(where(Athanor, id: ^athanor_id))
      end)
    end)

    membership =
      unboxed(fn ->
        Arca.Test.Actor.ensure_athanor_row(athanor_id)

        {:ok, _} =
          Users.mint(
            server(),
            %{
              id: user_id,
              provider: "github",
              first_seen_at: now,
              last_seen_at: now,
              created_at: now,
              updated_at: now
            },
            %{
              key: "github|https://github.com|pin-race#{n}",
              provider: "github",
              issuer: "https://github.com",
              subject: "pin-race#{n}",
              first_seen_at: now,
              last_seen_at: now
            }
          )

        {:ok, membership} =
          Members.seat(Prima.Actor.in_athanor(athanor_id), %{
            user_id: user_id,
            scope: "athanor",
            status: "active"
          })

        membership
      end)

    actor = %{Prima.Actor.in_athanor(athanor_id) | user_id: user_id}
    {:ok, actor: actor, membership: membership}
  end

  # This member's slot, taken on a real connection so every connection
  # reads the lease; the lease row, the process-wide standing and the
  # claim switch are given back after the case.
  defp hold_slot! do
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
    {:ok, slot} = unboxed(fn -> ControlPlane.take(node, node <> "#boot", 60_000) end)
    slot
  end

  # The connection's backend, on PostgreSQL, for the test to watch it wait.
  defp backend do
    if postgres?(), do: hd(hd(Arca.Repo.query!("SELECT pg_backend_pid()").rows))
  end

  # On PostgreSQL, `backend` is blocked on a lock, at the gate (`:gate`) or
  # in a statement naming every one of `fragments`.
  defp await_wait!(backend, at, tries \\ 250) do
    [[type, event, query]] =
      unboxed(fn ->
        Arca.Repo.query!(
          "SELECT wait_event_type, wait_event, query FROM pg_stat_activity WHERE pid = $1",
          [backend]
        ).rows
      end)

    waiting? =
      type == "Lock" and
        case at do
          :gate -> event == "advisory"
          fragments -> event != "advisory" and Enum.all?(fragments, &String.contains?(query, &1))
        end

    cond do
      waiting? ->
        :ok

      tries == 0 ->
        flunk("backend #{backend} is not waiting at #{inspect(at)}: #{type} #{event} #{query}")

      true ->
        retry_wait!(backend, at, tries)
    end
  end

  defp retry_wait!(backend, at, tries) do
    Process.sleep(20)
    await_wait!(backend, at, tries - 1)
  end

  defp assert_waits!(task, backend, fragments) do
    if postgres?(), do: await_wait!(backend, fragments)
    refute Task.yield(task, 300), "the waiter decided while the other side held its lock"
  end

  # A row trigger that holds a connection which set `arca_test.gate` at
  # `table`'s next updated row, once the row is locked, until the test
  # opens the gate.
  defp install_gate!(table) do
    unboxed(fn ->
      Arca.Repo.query!("""
      CREATE OR REPLACE FUNCTION arca_test_gate() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF current_setting('arca_test.gate', true) = 'on' THEN
          PERFORM pg_advisory_lock(#{@gate});
          PERFORM pg_advisory_unlock(#{@gate});
        END IF;
        IF TG_LEVEL = 'ROW' THEN RETURN NEW; END IF;
        RETURN NULL;
      END $$
      """)

      Arca.Repo.query!(
        "CREATE TRIGGER arca_test_gate BEFORE UPDATE ON #{table} " <>
          "FOR EACH ROW EXECUTE FUNCTION arca_test_gate()"
      )
    end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.query!("DROP TRIGGER IF EXISTS arca_test_gate ON #{table}")
        Arca.Repo.query!("DROP FUNCTION IF EXISTS arca_test_gate()")
      end)
    end)
  end

  defp close_gate! do
    test = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.query!("SELECT pg_advisory_lock($1)", [@gate])
          send(test, :gate_closed)

          receive do
            :open -> Arca.Repo.query!("SELECT pg_advisory_unlock($1)", [@gate])
          end
        end)
      end)

    assert_receive :gate_closed, 5_000
    holder
  end

  defp open_gate!(holder) do
    send(holder.pid, :open)
    Task.await(holder)
  end

  defp gated(fun) do
    Arca.Repo.query!("SELECT set_config('arca_test.gate', 'on', false)")

    try do
      fun.()
    after
      Arca.Repo.query!("SELECT set_config('arca_test.gate', '', false)")
    end
  end

  defp open!(actor, membership, lifetime_ms \\ 300_000) do
    secret = "secret-#{System.unique_integer()}"

    {:ok, invitation} =
      unboxed(fn ->
        PairingInvitations.open(
          actor,
          %{
            user_id: actor.user_id,
            membership_id: membership.id,
            secret_hash: Prima.Digest.sha256(secret),
            audience_home: "https://home.example",
            lifetime_ms: lifetime_ms
          },
          &admits/1
        )
      end)

    {invitation, Prima.Digest.sha256(secret)}
  end

  # The issuance a redemption runs: the paired client under the reserved
  # id, and its certificate.
  defp issue(actor) do
    fn invitation ->
      device_key = :crypto.strong_rand_bytes(32)

      with {:ok, client} <-
             PairedClients.record(actor, %{
               id: invitation.prospective_client_id,
               user_id: invitation.user_id,
               source_kind: "device_cert",
               source_id: Prima.Digest.sha256(device_key),
               device_public_key: device_key
             }),
           {:ok, cert} <-
             DeviceCertificates.record(actor, %{
               paired_client_id: client.id,
               user_id: client.user_id,
               subject_kind: "local",
               device_public_key: device_key,
               issuing_home: "https://home.example",
               audience_home: "https://home.example",
               not_before: DateTime.utc_now(),
               expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
               certificate: "cert-#{System.unique_integer()}",
               digest: Prima.Digest.sha256("cert-#{System.unique_integer()}")
             }) do
        {:ok, %{client: client, certificate: cert}}
      end
    end
  end

  # A redemption held inside its issuance, every lock of it taken.
  defp held_redemption(actor, hash) do
    test = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          PairingInvitations.consume(actor, hash, &admits/1, fn invitation ->
            send(test, :redemption_holds)

            receive do
              :go -> issue(actor).(invitation)
            end
          end)
        end)
      end)

    assert_receive :redemption_holds, 5_000
    task
  end

  defp redemption(actor, hash) do
    test = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:waiter, backend()})
          PairingInvitations.consume(actor, hash, &admits/1, issue(actor))
        end)
      end)

    assert_receive {:waiter, pid}, 5_000
    {task, pid}
  end

  defp clients(actor) do
    unboxed(fn ->
      Arca.Repo.aggregate(where(PairedClient, athanor_id: ^actor.athanor_id), :count)
    end)
  end

  test "a second redemption waits behind the first and reads it consumed", %{
    actor: actor,
    membership: membership
  } do
    {invitation, hash} = open!(actor, membership)
    first = held_redemption(actor, hash)
    {second, pid} = redemption(actor, hash)
    assert_waits!(second, pid, [~s("users"), "FOR UPDATE"])

    send(first.pid, :go)
    assert {:ok, %{client: %{id: client_id}}} = Task.await(first, 25_000)
    assert client_id == invitation.prospective_client_id
    assert {:error, :consumed} = Task.await(second, 25_000)
    assert clients(actor) == 1
  end

  test "a revocation waits behind a redemption and finds it consumed", %{
    actor: actor,
    membership: membership
  } do
    {invitation, hash} = open!(actor, membership)
    first = held_redemption(actor, hash)
    test = self()

    revoker =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:revoker, backend()})
          PairingInvitations.revoke(actor, invitation.id)
        end)
      end)

    assert_receive {:revoker, pid}, 5_000
    assert_waits!(revoker, pid, [~s(UPDATE "pairing_invitations")])

    send(first.pid, :go)
    assert {:ok, _} = Task.await(first, 25_000)
    assert {:ok, %{state: "consumed"}} = Task.await(revoker, 25_000)
    assert clients(actor) == 1
  end

  if Arca.Repo.adapter() != Ecto.Adapters.Postgres do
    @tag skip:
           "the revocation has no pause point but a PostgreSQL trigger; SQLite's write lock orders it"
  end

  test "a redemption waiting behind a revocation reads it revoked", %{
    actor: actor,
    membership: membership
  } do
    {invitation, hash} = open!(actor, membership)
    install_gate!("pairing_invitations")
    gate = close_gate!()
    test = self()

    revoker =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:revoker, backend()})
          gated(fn -> PairingInvitations.revoke(actor, invitation.id) end)
        end)
      end)

    assert_receive {:revoker, revoking}, 5_000
    await_wait!(revoking, :gate)
    {second, pid} = redemption(actor, hash)
    assert_waits!(second, pid, [~s("pairing_invitations"), "FOR UPDATE"])

    open_gate!(gate)
    assert {:ok, %{state: "revoked"}} = Task.await(revoker, 25_000)
    assert {:error, :revoked} = Task.await(second, 25_000)
    assert clients(actor) == 0
  end

  test "an invitation that expires while its redemption waits is refused", %{
    actor: actor,
    membership: membership
  } do
    {_other, holding} = open!(actor, membership)
    {short, hash} = open!(actor, membership, 2_000)

    # Another redemption of the same person holds the person's lock.
    first = held_redemption(actor, holding)
    {second, pid} = redemption(actor, hash)
    assert_waits!(second, pid, [~s("users"), "FOR UPDATE"])

    now = unboxed(fn -> Arca.ServerMetaStorage.now!() end)

    assert DateTime.compare(now, short.expires_at) == :lt,
           "the redemption did not wait before expiry"

    await_past!(short.expires_at)

    send(first.pid, :go)
    assert {:ok, _} = Task.await(first, 25_000)
    assert {:error, :expired} = Task.await(second, 25_000)
    assert clients(actor) == 1
  end

  # The database's clock is past `instant`, polled at most 5 seconds.
  defp await_past!(instant, tries \\ 250) do
    now = unboxed(fn -> Arca.ServerMetaStorage.now!() end)

    cond do
      DateTime.compare(now, instant) == :gt -> :ok
      tries == 0 -> flunk("the database's clock never passed #{instant}")
      true -> retry_past!(instant, tries)
    end
  end

  defp retry_past!(instant, tries) do
    Process.sleep(20)
    await_past!(instant, tries - 1)
  end
end
