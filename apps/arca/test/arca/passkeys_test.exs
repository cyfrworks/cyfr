# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PasskeysTest do
  @moduledoc """
  A person's passkeys at this relying home: person-scoped, pinned to an RP
  ID, `pending | active | revoked`. A pending registration activates only
  unexpired and exactly as registered, with its authorization consumed in
  the same transaction and under the epochs the cached head names now; a
  remote person's credential names its `recovery_epoch` and a head whose
  recovery replaced it revokes it, while an ordinary rotation keeps it;
  every active credential marks the person's first-method flag for good; a
  revocation voids the confirmations the credential confirmed.
  """

  # Takes the cell's slot, which is process-wide; each case restores it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{DirectoryHeads, Passkeys, PendingConfirmations, PersonIdentities, Users}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    hold_slot!()
    :ok
  end

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

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
    {:ok, slot} = Arca.ControlPlane.take(node, node <> "#boot", 60_000)
    slot
  end

  defp server, do: Prima.Actor.system()
  defp digest(seed), do: Prima.Digest.sha256("#{seed}-#{System.unique_integer()}")

  defp person!(identity) do
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
          key: "github|https://github.com|psk#{n}",
          provider: "github",
          issuer: "https://github.com",
          subject: "psk#{n}",
          first_seen_at: now,
          last_seen_at: now
        },
        also: fn person ->
          {:ok, _} = PersonIdentities.create(server(), Map.put(identity, :user_id, person.id))
          :ok
        end
      )

    person
  end

  defp local! do
    person!(%{
      provenance: "local",
      live_public_key: :crypto.strong_rand_bytes(32),
      operational_public_key: :crypto.strong_rand_bytes(32),
      live_key_sealed: "l",
      operational_key_sealed: "o"
    })
  end

  defp remote!(identifier) do
    person!(%{provenance: "remote", identifier: identifier, directory_url: "https://dir.example"})
  end

  # This home's cached head of `identifier` at `epoch`, its recovery epoch
  # `recovery` (the same, when none is named): the epoch a remote person's
  # credential may bind.
  defp cached!(identifier, epoch, recovery \\ nil) do
    {:ok, _head} =
      DirectoryHeads.put(server(), %{
        identifier: identifier,
        genesis: "genesis",
        directory_url: "https://dir.example",
        head_hash: epoch,
        key_epoch: epoch,
        recovery_epoch: recovery || epoch,
        state: "{}"
      })

    :ok
  end

  defp advance!(identifier, old, key_epoch, recovery_epoch) do
    DirectoryHeads.advance(server(), identifier, old, %{
      genesis: "genesis",
      directory_url: "https://dir.example",
      head_hash: key_epoch,
      key_epoch: key_epoch,
      recovery_epoch: recovery_epoch,
      state: "{}"
    })
  end

  defp attrs(person, overrides) do
    Map.merge(
      %{
        user_id: person.id,
        credential_id: "cred-#{System.unique_integer([:positive])}",
        rp_id: "home.example",
        relying_home: "https://home.example",
        public_key: "cose-key",
        registration_digest: digest("registration"),
        possession_verified: true,
        state: "active"
      },
      overrides
    )
  end

  defp as(person), do: %Prima.Actor{user_id: person.id}

  describe "registration" do
    test "an active credential marks the first method, and the exception is then spent" do
      person = local!()

      assert {:ok, first} = Passkeys.register(as(person), attrs(person, %{}), first_method: true)
      assert first.state == "active"
      assert {:ok, %{first_method_at: %DateTime{}}} = PersonIdentities.get(server(), person.id)

      assert {:error, :first_method_used} =
               Passkeys.register(as(person), attrs(person, %{}), first_method: true)

      {:ok, _} = Passkeys.revoke(as(person), first.id)

      # Revoking every method never reopens the exception.
      assert {:error, :first_method_used} =
               Passkeys.register(as(person), attrs(person, %{}), first_method: true)

      assert {:ok, _} = Passkeys.register(as(person), attrs(person, %{}))
    end

    test "a credential is live once per RP ID" do
      person = local!()
      {:ok, first} = Passkeys.register(as(person), attrs(person, %{}))

      assert {:error, :conflict} =
               Passkeys.register(as(person), attrs(person, %{credential_id: first.credential_id}))

      assert {:ok, _} =
               Passkeys.register(
                 as(person),
                 attrs(person, %{credential_id: first.credential_id, rp_id: "other.example"})
               )
    end

    test "a remote person's credential names the current recovery_epoch; a local one names none" do
      identifier = "per_" <> Prima.Digest.sha256_hex("g-#{System.unique_integer()}")
      remote = remote!(identifier)
      local = local!()
      key_epoch = digest("key")
      recovery = digest("recovery")

      # No head cached: no epoch is current.
      assert {:error, :stale_key_epoch} =
               Passkeys.register(as(remote), attrs(remote, %{identity_recovery_epoch: recovery}))

      cached!(identifier, key_epoch, recovery)

      assert {:error, :identity_key_epoch_required} =
               Passkeys.register(as(remote), attrs(remote, %{}))

      assert {:error, :stale_key_epoch} =
               Passkeys.register(
                 as(remote),
                 attrs(remote, %{identity_recovery_epoch: digest("gone")})
               )

      # The key epoch is not what a passkey binds.
      assert {:error, :stale_key_epoch} =
               Passkeys.register(as(remote), attrs(remote, %{identity_recovery_epoch: key_epoch}))

      assert {:ok, %{identity_recovery_epoch: ^recovery}} =
               Passkeys.register(as(remote), attrs(remote, %{identity_recovery_epoch: recovery}))

      assert {:error, :unexpected_key_epoch} =
               Passkeys.register(as(local), attrs(local, %{identity_recovery_epoch: recovery}))
    end

    test "a pending registration carries its expiry, and possession is required" do
      person = local!()

      assert {:error, {:invalid, %{expires_at: _}}} =
               Passkeys.register(as(person), attrs(person, %{state: "pending"}))

      assert {:error, {:invalid, %{possession_verified: _}}} =
               Passkeys.register(as(person), attrs(person, %{possession_verified: false}))
    end

    test "a person registers only their own" do
      person = local!()

      assert {:error, :cross_tenant} =
               Passkeys.register(%Prima.Actor{user_id: "usr_other"}, attrs(person, %{}))
    end
  end

  describe "activation" do
    setup do
      identifier = "per_" <> Prima.Digest.sha256_hex("g-#{System.unique_integer()}")
      person = remote!(identifier)
      epoch = digest("epoch")
      cached!(identifier, epoch)
      expires = DateTime.add(DateTime.utc_now(), 300, :second)

      {:ok, pending} =
        Passkeys.register(
          as(person),
          attrs(person, %{state: "pending", identity_recovery_epoch: epoch, expires_at: expires})
        )

      {:ok, identifier: identifier, person: person, pending: pending, epoch: epoch}
    end

    test "activates exactly the registration named, with its authorization", %{
      pending: pending,
      epoch: epoch
    } do
      assert {:error, :mismatch} =
               Passkeys.activate(server(), pending.id,
                 registration_digest: digest("substituted"),
                 identity_key_epoch: epoch,
                 identity_recovery_epoch: epoch
               )

      assert {:error, :mismatch} =
               Passkeys.activate(server(), pending.id,
                 registration_digest: pending.registration_digest,
                 identity_key_epoch: epoch,
                 identity_recovery_epoch: digest("another epoch")
               )

      assert {:ok, active} =
               Passkeys.activate(server(), pending.id,
                 registration_digest: pending.registration_digest,
                 identity_key_epoch: epoch,
                 identity_recovery_epoch: epoch,
                 admin_confirmation_id: "cnf_admin"
               )

      assert active.state == "active"
      assert active.admin_confirmation_id == "cnf_admin"

      assert {:error, :not_pending} =
               Passkeys.activate(server(), pending.id,
                 registration_digest: pending.registration_digest,
                 identity_key_epoch: epoch,
                 identity_recovery_epoch: epoch
               )
    end

    test "an authorization named under a key epoch the head has moved past activates nothing",
         %{identifier: identifier, pending: pending, epoch: epoch} do
      # An ordinary rotation keeps the pending registration, but not an
      # authorization made under the key epoch it replaced.
      rotated = digest("rotated")
      assert {:ok, %{retired: %{passkey_ids: []}}} = advance!(identifier, epoch, rotated, epoch)

      assert {:error, :stale_key_epoch} =
               Passkeys.activate(server(), pending.id,
                 registration_digest: pending.registration_digest,
                 identity_key_epoch: epoch,
                 identity_recovery_epoch: epoch
               )

      assert {:ok, %{state: "active"}} =
               Passkeys.activate(server(), pending.id,
                 registration_digest: pending.registration_digest,
                 identity_key_epoch: rotated,
                 identity_recovery_epoch: epoch
               )
    end

    test "a recovery retires the pending registration: nothing it names activates after", %{
      identifier: identifier,
      pending: pending,
      epoch: epoch
    } do
      recovered = digest("recovered")
      pending_id = pending.id

      assert {:ok, %{retired: %{passkey_ids: [^pending_id]}}} =
               advance!(identifier, epoch, recovered, recovered)

      assert {:error, :not_pending} =
               Passkeys.activate(server(), pending.id,
                 registration_digest: pending.registration_digest,
                 identity_key_epoch: recovered,
                 identity_recovery_epoch: epoch
               )
    end

    test "an authorization that cannot be consumed activates nothing", %{
      pending: pending,
      epoch: epoch
    } do
      assert {:error, :confirmation_consumed} =
               Passkeys.activate(server(), pending.id,
                 registration_digest: pending.registration_digest,
                 identity_key_epoch: epoch,
                 identity_recovery_epoch: epoch,
                 also: fn _passkey -> {:error, :confirmation_consumed} end
               )

      assert {:ok, %{state: "pending"}} = Passkeys.get(server(), pending.id)
    end

    test "an expired registration does not activate", %{pending: pending, epoch: epoch} do
      {1, _} =
        Arca.Repo.update_all(
          from(p in Arca.Schemas.Passkey, where: p.id == ^pending.id),
          set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      assert {:error, :expired} =
               Passkeys.activate(server(), pending.id,
                 registration_digest: pending.registration_digest,
                 identity_key_epoch: epoch,
                 identity_recovery_epoch: epoch
               )
    end
  end

  test "a recovery that replaces the live key revokes the credentials of the old recovery epoch; a rotation keeps them" do
    identifier = "per_" <> Prima.Digest.sha256_hex("g-#{System.unique_integer()}")
    person = remote!(identifier)
    old = digest("old")
    cached!(identifier, old)

    {:ok, passkey} =
      Passkeys.register(as(person), attrs(person, %{identity_recovery_epoch: old}))

    passkey_id = passkey.id

    # An ordinary rotation: the key epoch moves, the recovery epoch stays.
    rotated = digest("rotated")
    assert {:ok, %{retired: %{passkey_ids: []}}} = advance!(identifier, old, rotated, old)
    assert {:ok, %{state: "active"}} = Passkeys.get(server(), passkey.id)

    # A recovery that replaces the live key moves both.
    recovered = digest("recovered")

    assert {:ok, %{retired: %{passkey_ids: [^passkey_id]}}} =
             advance!(identifier, rotated, recovered, recovered)

    assert {:ok, %{state: "revoked"}} = Passkeys.get(server(), passkey.id)

    # The retired epoch binds nothing new; the current one does.
    assert {:error, :stale_key_epoch} =
             Passkeys.register(as(person), attrs(person, %{identity_recovery_epoch: old}))

    assert {:ok, _} =
             Passkeys.register(as(person), attrs(person, %{identity_recovery_epoch: recovered}))
  end

  test "a revocation voids the confirmations the credential confirmed" do
    person = local!()
    {:ok, passkey} = Passkeys.register(as(person), attrs(person, %{}))
    actor = %{Prima.Actor.in_athanor("ath_test") | user_id: person.id}

    {:ok, record} =
      Prima.Confirmation.new(
        id: Prima.Confirmation.ref("cnf_#{System.unique_integer([:positive])}"),
        home: "https://home.example",
        rp_id: "home.example",
        athanor: "ath_test",
        person: person.id,
        operation: "vault.create",
        args_digest: digest("args"),
        action: "credential_entry",
        preview: %{home: "https://home.example", athanor: "Test", operation: "vault.create"},
        challenge: :crypto.strong_rand_bytes(32),
        expires_at: System.system_time(:millisecond) + 300_000
      )

    {:ok, _} =
      PendingConfirmations.open(actor, %{
        record: record,
        opener: "session:passkeys-test",
        asker: %{"kind" => "session"}
      })

    {:ok, _} =
      PendingConfirmations.confirm(actor, record.id, %{proof: "passkey", passkey_id: passkey.id})

    passkey_id = passkey.id

    assert {:ok,
            %{passkey: %{id: ^passkey_id, state: "revoked"}, voided_confirmation_ids: [voided]}} =
             Passkeys.revoke(as(person), passkey.id)

    assert voided == record.id
    assert {:ok, %{state: "voided"}} = PendingConfirmations.get(actor, record.id)
  end

  test "a revocation's check runs in its transaction, and its refusal revokes nothing" do
    person = local!()
    {:ok, passkey} = Passkeys.register(as(person), attrs(person, %{}))
    passkey_id = passkey.id
    test = self()

    keep = fn handed ->
      send(test, {:handed, handed})
      {:error, :last_way_in}
    end

    assert {:error, :last_way_in} = Passkeys.revoke(as(person), passkey.id, also: keep)
    assert_received {:handed, %{passkey: %{id: ^passkey_id, state: "revoked"}, was: "active"}}
    assert {:ok, %{state: "active", revoked_at: nil}} = Passkeys.get(as(person), passkey.id)

    assert {:ok, %{passkey: %{state: "revoked"}}} =
             Passkeys.revoke(as(person), passkey.id, also: fn %{was: "active"} -> :ok end)

    # A revoked credential answers as it is, the state it stood in handed on.
    assert {:ok, %{passkey: %{state: "revoked"}, voided_confirmation_ids: []}} =
             Passkeys.revoke(as(person), passkey.id, also: fn %{was: "revoked"} -> :ok end)

    other = local!()
    assert {:error, :cross_tenant} = Passkeys.revoke(as(other), passkey.id, also: keep)
    refute_received {:handed, _}
  end

  test "a counter moves by compare-and-set only" do
    person = local!()
    {:ok, passkey} = Passkeys.register(as(person), attrs(person, %{}))

    assert {:ok, %{sign_count: 5}} = Passkeys.record_use(as(person), passkey.id, 0, 5)
    assert {:error, :stale} = Passkeys.record_use(as(person), passkey.id, 0, 6)
    assert {:ok, %{sign_count: 6}} = Passkeys.record_use(as(person), passkey.id, 5, 6)
  end

  test "the sign-in lookup is the platform's, and finds only live credentials" do
    person = local!()
    {:ok, passkey} = Passkeys.register(as(person), attrs(person, %{}))

    assert {:error, :cross_tenant} =
             Passkeys.get_by_credential(as(person), passkey.rp_id, passkey.credential_id)

    assert {:ok, %{id: id}} =
             Passkeys.get_by_credential(server(), passkey.rp_id, passkey.credential_id)

    assert id == passkey.id
    {:ok, _} = Passkeys.revoke(as(person), passkey.id)

    assert {:error, :not_found} =
             Passkeys.get_by_credential(server(), passkey.rp_id, passkey.credential_id)

    assert {:ok, [%{id: ^id}]} = Passkeys.list(as(person), person.id, state: :revoked)
  end
end

defmodule Arca.PasskeysRaceTest do
  @moduledoc """
  A person's last passkey revoked while their last door is unlinked, on
  two real connections outside the sandbox. Each checks, under the
  person's lock, that the person keeps a way in without what it removes,
  and both take that lock first, so the second waits for the first to
  commit and then sees its removal: the two never both commit. On
  PostgreSQL the waiter blocks on the person's row; on SQLite at the lock
  its transaction takes at entry.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.{ControlPlane, Passkeys, PersonIdentities, Users}
  alias Arca.Schemas.{CellLease, ExternalIdentity, Passkey, PersonIdentity, User}
  alias Ecto.Adapters.SQL.Sandbox

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
  defp server, do: Prima.Actor.system()
  defp postgres?, do: Arca.Repo.adapter() == Ecto.Adapters.Postgres

  setup do
    hold_slot!()
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()
    user_id = Prima.UUID7.generate_id(Prima.PersonId.prefix())
    key = "github|https://github.com|psk-race#{n}"

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(where(Passkey, user_id: ^user_id))
        Arca.Repo.delete_all(where(PersonIdentity, user_id: ^user_id))
        Arca.Repo.delete_all(where(ExternalIdentity, user_id: ^user_id))
        Arca.Repo.delete_all(where(User, id: ^user_id))
      end)
    end)

    passkey =
      unboxed(fn ->
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
              key: key,
              provider: "github",
              issuer: "https://github.com",
              subject: "psk-race#{n}",
              first_seen_at: now,
              last_seen_at: now
            },
            also: fn person ->
              {:ok, _} =
                PersonIdentities.create(server(), %{
                  user_id: person.id,
                  provenance: "local",
                  live_public_key: :crypto.strong_rand_bytes(32),
                  operational_public_key: :crypto.strong_rand_bytes(32),
                  live_key_sealed: "l",
                  operational_key_sealed: "o"
                })

              :ok
            end
          )

        {:ok, passkey} =
          Passkeys.register(server(), %{
            user_id: user_id,
            credential_id: "cred-race#{n}",
            rp_id: "home.example",
            relying_home: "https://home.example",
            public_key: "cose-key",
            registration_digest: Prima.Digest.sha256("registration-#{n}"),
            possession_verified: true,
            state: "active"
          })

        passkey
      end)

    {:ok, user_id: user_id, key: key, passkey: passkey}
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

  # On PostgreSQL, `backend` is blocked on a lock, in a statement naming
  # every one of `fragments`.
  defp await_wait!(backend, fragments, tries \\ 250) do
    [[type, event, query]] =
      unboxed(fn ->
        Arca.Repo.query!(
          "SELECT wait_event_type, wait_event, query FROM pg_stat_activity WHERE pid = $1",
          [backend]
        ).rows
      end)

    cond do
      type == "Lock" and Enum.all?(fragments, &String.contains?(query, &1)) ->
        :ok

      tries == 0 ->
        flunk(
          "backend #{backend} is not waiting at #{inspect(fragments)}: #{type} #{event} #{query}"
        )

      true ->
        retry_wait!(backend, fragments, tries)
    end
  end

  defp retry_wait!(backend, fragments, tries) do
    Process.sleep(20)
    await_wait!(backend, fragments, tries - 1)
  end

  # The callers' check, as they make it under the lock: the person keeps
  # a door or an active passkey.
  defp keeps_a_way_in(user_id) do
    doors = Arca.Repo.aggregate(where(ExternalIdentity, user_id: ^user_id), :count)
    passkeys = Arca.Repo.aggregate(where(Passkey, user_id: ^user_id, state: "active"), :count)
    if doors + passkeys > 0, do: :ok, else: {:error, :last_way_in}
  end

  test "a revocation waits behind the unlinking of the last door, then keeps the passkey",
       %{user_id: user_id, key: key, passkey: passkey} do
    test = self()

    unlinker =
      Task.async(fn ->
        unboxed(fn ->
          Users.unlink_identity(server(), user_id, key,
            also: fn %{remaining: 0} ->
              send(test, :unlinking)

              receive do
                :go -> keeps_a_way_in(user_id)
              end
            end
          )
        end)
      end)

    assert_receive :unlinking, 5_000

    revoker =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:revoker, backend()})

          Passkeys.revoke(server(), passkey.id,
            also: fn %{was: "active"} -> keeps_a_way_in(user_id) end
          )
        end)
      end)

    assert_receive {:revoker, pid}, 5_000
    if postgres?(), do: await_wait!(pid, [~s(FROM "users"), "FOR UPDATE"])
    refute Task.yield(revoker, 300), "the revocation decided while the unlinking held the person"

    send(unlinker.pid, :go)
    assert {:ok, %{remaining: 0}} = Task.await(unlinker, 25_000)
    assert {:error, :last_way_in} = Task.await(revoker, 25_000)

    assert %{state: "active"} = unboxed(fn -> Arca.Repo.get!(Passkey, passkey.id) end)
    assert [] = unboxed(fn -> Arca.Repo.all(where(ExternalIdentity, user_id: ^user_id)) end)
  end
end
