# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PasskeysTest do
  @moduledoc """
  A person's passkeys at this relying home: person-scoped, pinned to an RP
  ID, `pending | active | revoked`. A pending registration activates only
  unexpired and exactly as registered, with its authorization consumed in
  the same transaction; a remote person's credential names its
  `key_epoch` and a head that retires the epoch revokes it; every active
  credential marks the person's first-method flag for good; a revocation
  voids the confirmations the credential confirmed.
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

  # This home's cached head of `identifier` at `epoch`: the epoch a remote
  # person's credential may bind.
  defp cached!(identifier, epoch) do
    {:ok, _head} =
      DirectoryHeads.put(server(), %{
        identifier: identifier,
        genesis: "genesis",
        directory_url: "https://dir.example",
        head_hash: epoch,
        key_epoch: epoch,
        state: "{}"
      })

    :ok
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

    test "a remote person's credential names the current key_epoch; a local one names none" do
      identifier = "per_" <> Prima.Digest.sha256_hex("g-#{System.unique_integer()}")
      remote = remote!(identifier)
      local = local!()
      epoch = digest("epoch")

      # No head cached: no epoch is current.
      assert {:error, :stale_key_epoch} =
               Passkeys.register(as(remote), attrs(remote, %{identity_key_epoch: epoch}))

      cached!(identifier, epoch)

      assert {:error, :identity_key_epoch_required} =
               Passkeys.register(as(remote), attrs(remote, %{}))

      assert {:error, :stale_key_epoch} =
               Passkeys.register(as(remote), attrs(remote, %{identity_key_epoch: digest("gone")}))

      assert {:ok, %{identity_key_epoch: ^epoch}} =
               Passkeys.register(as(remote), attrs(remote, %{identity_key_epoch: epoch}))

      assert {:error, :unexpected_key_epoch} =
               Passkeys.register(as(local), attrs(local, %{identity_key_epoch: epoch}))
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
          attrs(person, %{state: "pending", identity_key_epoch: epoch, expires_at: expires})
        )

      {:ok, person: person, pending: pending, epoch: epoch}
    end

    test "activates exactly the registration named, with its authorization", %{
      pending: pending,
      epoch: epoch
    } do
      assert {:error, :mismatch} =
               Passkeys.activate(server(), pending.id,
                 registration_digest: digest("substituted"),
                 identity_key_epoch: epoch
               )

      assert {:error, :mismatch} =
               Passkeys.activate(server(), pending.id,
                 registration_digest: pending.registration_digest,
                 identity_key_epoch: digest("another epoch")
               )

      assert {:ok, active} =
               Passkeys.activate(server(), pending.id,
                 registration_digest: pending.registration_digest,
                 identity_key_epoch: epoch,
                 admin_confirmation_id: "cnf_admin"
               )

      assert active.state == "active"
      assert active.admin_confirmation_id == "cnf_admin"

      assert {:error, :not_pending} =
               Passkeys.activate(server(), pending.id,
                 registration_digest: pending.registration_digest,
                 identity_key_epoch: epoch
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
                 identity_key_epoch: epoch
               )
    end
  end

  test "a head that retires the key_epoch revokes the credentials registered under it" do
    identifier = "per_" <> Prima.Digest.sha256_hex("g-#{System.unique_integer()}")
    person = remote!(identifier)
    old = digest("old")
    cached!(identifier, old)
    {:ok, passkey} = Passkeys.register(as(person), attrs(person, %{identity_key_epoch: old}))

    new = digest("new")
    passkey_id = passkey.id

    assert {:ok, %{retired: %{passkey_ids: [^passkey_id]}}} =
             DirectoryHeads.advance(server(), identifier, old, %{
               genesis: "genesis",
               directory_url: "https://dir.example",
               head_hash: new,
               key_epoch: new,
               state: "{}"
             })

    assert {:ok, %{state: "revoked"}} = Passkeys.get(server(), passkey.id)

    # The retired epoch binds nothing new; the current one does.
    assert {:error, :stale_key_epoch} =
             Passkeys.register(as(person), attrs(person, %{identity_key_epoch: old}))

    assert {:ok, _} = Passkeys.register(as(person), attrs(person, %{identity_key_epoch: new}))
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
