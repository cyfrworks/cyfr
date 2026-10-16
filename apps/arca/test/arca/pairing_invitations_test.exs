# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PairingInvitationsTest do
  @moduledoc """
  Pairing invitations: opened under the issuance locks and the caller's
  verifier, stored by the hash of their secret with a reserved client id,
  the digest of the one device key that may redeem them and the confirmer
  read from the consumed `pairing.begin` confirmation; looked up by hash
  for routing alone; redeemed once, under the person, athanor and
  membership locked first and the invitation last, with its state, expiry,
  key, confirmer, the person's first-method latch and the member's
  ownership rechecked, the client and its certificate recorded and the
  invitation consumed in one transaction, or nothing. A standing
  transition revokes the pending ones and nothing resurrects them.
  """

  # Takes the cell's slot for the stale-owner case; every case restores it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{
    ControlPlane,
    DeviceCertificates,
    Members,
    PairedClients,
    PairingInvitations,
    Passkeys,
    PendingConfirmations,
    PersonIdentities,
    Users
  }

  alias Arca.PairingInvitationsTest.Confirmations
  alias Arca.Schemas.{CellLease, PairedClient, PairingInvitation}

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
    {person, membership, actor} = member!(athanor)
    passkey = passkey!(person)

    {:ok, actor: actor, person: person, membership: membership, passkey: passkey, slot: slot}
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

  # A person with their identity row (local, its first-method latch open)
  # minted with them, seated in `athanor`, and the actor they act as there.
  defp member!(athanor) do
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
        },
        also: fn person ->
          {:ok, _} = PersonIdentities.create(server(), Confirmations.identity(person.id))
          :ok
        end
      )

    {:ok, membership} =
      Members.seat(Prima.Actor.in_athanor(athanor), %{
        user_id: person.id,
        scope: "athanor",
        status: "active"
      })

    {person, membership, %{Prima.Actor.in_athanor(athanor) | user_id: person.id}}
  end

  # An active passkey of the person: their first method, which sets the latch.
  defp passkey!(person) do
    {:ok, passkey} =
      Passkeys.register(%Prima.Actor{user_id: person.id}, %{
        user_id: person.id,
        credential_id: "cred-#{System.unique_integer([:positive])}",
        rp_id: "home.example",
        relying_home: "https://home.example",
        public_key: "cose-key",
        registration_digest: Prima.Digest.sha256("reg-#{System.unique_integer()}"),
        possession_verified: true,
        state: "active"
      })

    passkey
  end

  # An active paired client of the person in the actor's athanor.
  defp client!(actor, person) do
    {:ok, client} =
      PairedClients.record(actor, %{
        user_id: person.id,
        source_kind: "session",
        source_id: "ses_#{System.unique_integer([:positive])}"
      })

    client
  end

  defp by_passkey(passkey), do: %{proof: "passkey", passkey_id: passkey.id}

  defp admits(_locked), do: :ok

  defp key_digest!, do: Prima.Device.key_digest(:crypto.strong_rand_bytes(32))

  defp attrs(person, membership, confirmation, secret) do
    %{
      user_id: person.id,
      membership_id: membership.id,
      secret_hash: Prima.Digest.sha256(secret),
      key_digest: key_digest!(),
      confirmation_ref: confirmation.ref,
      audience_home: "https://home.example",
      lifetime_ms: 300_000
    }
  end

  # An invitation opened as the identity domain opens one: its
  # `pairing.begin` confirmation, proven by `proof`, consumed by the
  # verifier inside the opening's transaction.
  defp open!(actor, person, membership, proof) do
    secret = "secret-#{System.unique_integer()}"
    confirmation = Confirmations.confirmed!(actor, person.id, proof)
    attrs = attrs(person, membership, confirmation, secret)

    {:ok, invitation} =
      PairingInvitations.open(actor, attrs, Confirmations.consuming(actor, confirmation))

    {invitation, Prima.Digest.sha256(secret), attrs.key_digest}
  end

  defp clients(actor) do
    Arca.Repo.aggregate(from(p in PairedClient, where: p.athanor_id == ^actor.athanor_id), :count)
  end

  defp latch_open?(person), do: PersonIdentities.first_method_open?(server(), person.id)

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

  test "opens under the verifier, storing the hash and key digest and reserving a client id", %{
    actor: actor,
    person: person,
    membership: membership,
    passkey: passkey
  } do
    me = self()
    confirmation = Confirmations.confirmed!(actor, person.id, by_passkey(passkey))
    attrs = attrs(person, membership, confirmation, "the secret")

    {:ok, invitation} =
      PairingInvitations.open(
        actor,
        attrs,
        Confirmations.consuming(actor, confirmation, fn locked ->
          send(me, {:locked, locked.user.id, locked.membership.id})
          :ok
        end)
      )

    assert_received {:locked, user_id, membership_id}
    assert {user_id, membership_id} == {person.id, membership.id}
    assert invitation.state == "pending"
    assert "pcl_" <> _ = invitation.prospective_client_id
    assert invitation.key_digest == attrs.key_digest
    refute invitation.secret_hash =~ "the secret"
    assert {:ok, %{state: "consumed"}} = PendingConfirmations.get(actor, confirmation.ref)

    refused = Confirmations.confirmed!(actor, person.id, by_passkey(passkey))

    assert {:error, :not_member} =
             PairingInvitations.open(
               actor,
               attrs(person, membership, refused, "another"),
               fn _locked -> {:error, :not_member} end
             )

    assert {:ok, %{state: "confirmed"}} = PendingConfirmations.get(actor, refused.ref)
  end

  test "lookup answers routing by hash alone", %{
    actor: actor,
    person: person,
    membership: m,
    passkey: passkey
  } do
    {invitation, hash, digest} = open!(actor, person, m, by_passkey(passkey))

    assert {:ok, routing} = PairingInvitations.lookup(hash)
    assert routing.athanor_id == actor.athanor_id
    assert routing.prospective_client_id == invitation.prospective_client_id
    assert routing.key_digest == digest
    refute Map.has_key?(routing, :secret_hash)
    assert {:error, :not_found} = PairingInvitations.lookup(Prima.Digest.sha256("unknown"))
  end

  test "redeems once: one client, one certificate, the invitation consumed", %{
    actor: actor,
    person: person,
    membership: m,
    passkey: passkey
  } do
    {invitation, hash, digest} = open!(actor, person, m, by_passkey(passkey))

    assert {:ok, %{client: client, certificate: cert}} =
             PairingInvitations.consume(actor, hash, digest, &admits/1, issue(actor))

    assert client.id == invitation.prospective_client_id
    assert cert.paired_client_id == client.id

    assert {:error, :consumed} =
             PairingInvitations.consume(actor, hash, digest, &admits/1, issue(actor))

    assert {:ok, [%{state: "consumed"}]} = PairingInvitations.list(actor, state: :consumed)
    assert clients(actor) == 1
  end

  test "a failed issuance rolls everything back and the invitation stays pending", %{
    actor: actor,
    person: person,
    membership: m,
    passkey: passkey
  } do
    {_invitation, hash, digest} = open!(actor, person, m, by_passkey(passkey))

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
             PairingInvitations.consume(actor, hash, digest, &admits/1, failing)

    assert clients(actor) == 0
    assert {:ok, [%{state: "pending"}]} = PairingInvitations.list(actor, [])
  end

  test "revoked, expired, refused by standing, or asked from another athanor: nothing issued", %{
    actor: actor,
    person: person,
    membership: m,
    passkey: passkey
  } do
    {revoked, revoked_hash, revoked_digest} = open!(actor, person, m, by_passkey(passkey))
    {:ok, %{state: "revoked"}} = PairingInvitations.revoke(actor, revoked.id)

    assert {:error, :revoked} =
             PairingInvitations.consume(
               actor,
               revoked_hash,
               revoked_digest,
               &admits/1,
               issue(actor)
             )

    {expired, expired_hash, expired_digest} = open!(actor, person, m, by_passkey(passkey))

    {1, _} =
      Arca.Repo.update_all(
        from(i in Arca.Schemas.PairingInvitation, where: i.id == ^expired.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

    assert {:error, :expired} =
             PairingInvitations.consume(
               actor,
               expired_hash,
               expired_digest,
               &admits/1,
               issue(actor)
             )

    {_denied, denied_hash, denied_digest} = open!(actor, person, m, by_passkey(passkey))

    assert {:error, :not_a_member} =
             PairingInvitations.consume(
               actor,
               denied_hash,
               denied_digest,
               fn _ -> {:error, :not_a_member} end,
               issue(actor)
             )

    other = Prima.Actor.in_athanor("ath_pin_other")

    assert {:error, :not_found} =
             PairingInvitations.consume(
               other,
               denied_hash,
               denied_digest,
               &admits/1,
               issue(other)
             )

    assert clients(actor) == 0
  end

  test "a standing transition revokes pending invitations, and an allow never resurrects them", %{
    actor: actor,
    person: person,
    membership: m,
    passkey: passkey
  } do
    {invitation, _hash, _digest} = open!(actor, person, m, by_passkey(passkey))

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
      passkey: passkey,
      slot: slot
    } do
      {_invitation, hash, digest} = open!(actor, person, m, by_passkey(passkey))

      {1, _} =
        Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
          set: [owner: "someone-else", generation: slot.generation + 1]
        )

      assert {:error, :not_owner} =
               PairingInvitations.consume(actor, hash, digest, &admits/1, issue(actor))

      assert {:ok, [%{state: "pending"}]} = PairingInvitations.list(actor, [])
    end
  end

  describe "the device key" do
    test "only the key the invitation names redeems it: another is refused and writes nothing", %{
      actor: actor,
      person: person,
      membership: m,
      passkey: passkey
    } do
      {invitation, hash, digest} = open!(actor, person, m, by_passkey(passkey))

      assert {:error, :key_mismatch} =
               PairingInvitations.consume(actor, hash, key_digest!(), &admits/1, issue(actor))

      assert clients(actor) == 0
      assert {:ok, [%{state: "pending"}]} = PairingInvitations.list(actor, [])

      assert {:ok, %{client: %{id: client_id}}} =
               PairingInvitations.consume(actor, hash, digest, &admits/1, issue(actor))

      assert client_id == invitation.prospective_client_id
    end
  end

  describe "the confirmer" do
    test "is the passkey the consumed confirmation names, before a client it also names, else the client, never the caller's",
         %{actor: actor, person: person, membership: m, passkey: passkey} do
      client = client!(actor, person)

      both =
        Confirmations.confirmed!(actor, person.id, %{
          proof: "passkey",
          passkey_id: passkey.id,
          client_id: client.id
        })

      {:ok, by_both} =
        PairingInvitations.open(
          actor,
          attrs(person, m, both, "both")
          |> Map.merge(%{confirmer_kind: "device", confirmer_id: client.id}),
          Confirmations.consuming(actor, both)
        )

      device =
        Confirmations.confirmed!(actor, person.id, %{proof: "email_code", client_id: client.id})

      {:ok, by_device} =
        PairingInvitations.open(
          actor,
          attrs(person, m, device, "device")
          |> Map.merge(%{confirmer_kind: "passkey", confirmer_id: passkey.id}),
          Confirmations.consuming(actor, device)
        )

      for {invitation, expected} <- [
            {by_both, {"passkey", passkey.id}},
            {by_device, {"device", client.id}}
          ] do
        assert {invitation.confirmer_kind, invitation.confirmer_id} == expected
        stored = Arca.Repo.get!(PairingInvitation, invitation.id)
        assert {stored.confirmer_kind, stored.confirmer_id} == expected
      end
    end

    test "a confirmation not consumed, another person's, or another operation's opens nothing", %{
      actor: actor,
      person: person,
      membership: m,
      passkey: passkey
    } do
      {other, _membership, _actor} = member!(actor.athanor_id)

      # Confirmed, never consumed.
      unconsumed = Confirmations.confirmed!(actor, person.id, by_passkey(passkey))

      assert {:error, :confirmation_unconsumed} =
               PairingInvitations.open(actor, attrs(person, m, unconsumed, "a"), &admits/1)

      # Consumed by the verifier, but another person's, or another
      # operation's: the refusal rolls the consumption back with the rest.
      theirs = Confirmations.confirmed!(actor, other.id, %{proof: "oidc_reauth"})

      vault =
        Confirmations.confirmed!(actor, person.id, by_passkey(passkey), operation: "vault.create")

      for {confirmation, secret} <- [{theirs, "b"}, {vault, "c"}] do
        assert {:error, :confirmation_unconsumed} =
                 PairingInvitations.open(
                   actor,
                   attrs(person, m, confirmation, secret),
                   Confirmations.consuming(actor, confirmation)
                 )
      end

      for confirmation <- [unconsumed, theirs, vault] do
        assert {:ok, %{state: "confirmed"}} = PendingConfirmations.get(actor, confirmation.ref)
      end

      assert {:ok, []} = PairingInvitations.list(actor, state: :all)
    end

    test "a passkey revoked before the redemption refuses it, and nothing is written", %{
      actor: actor,
      person: person,
      membership: m,
      passkey: passkey
    } do
      {_invitation, hash, digest} = open!(actor, person, m, by_passkey(passkey))
      {:ok, _} = Passkeys.revoke(%Prima.Actor{user_id: person.id}, passkey.id)

      assert {:error, :confirmer_revoked} =
               PairingInvitations.consume(actor, hash, digest, &admits/1, issue(actor))

      assert clients(actor) == 0
      assert {:ok, [%{state: "pending"}]} = PairingInvitations.list(actor, [])
    end

    test "a paired client revoked before the redemption refuses it, and nothing is written", %{
      actor: actor,
      person: person,
      membership: m
    } do
      client = client!(actor, person)

      {invitation, hash, digest} =
        open!(actor, person, m, %{proof: "email_code", client_id: client.id})

      {:ok, %{standing: "revoked"}} = PairedClients.revoke(actor, client.id)

      assert {:error, :confirmer_revoked} =
               PairingInvitations.consume(actor, hash, digest, &admits/1, issue(actor))

      refute Arca.Repo.get(PairedClient, invitation.prospective_client_id)
      assert {:ok, [%{state: "pending"}]} = PairingInvitations.list(actor, [])
    end
  end

  describe "the first-method latch" do
    setup %{actor: actor} do
      {newcomer, membership, newcomer_actor} = member!(actor.athanor_id)
      {:ok, newcomer: newcomer, newcomer_membership: membership, newcomer_actor: newcomer_actor}
    end

    test "an unattributed confirmation opens an invitation naming no confirmer only while it is open",
         %{newcomer: person, newcomer_membership: m, newcomer_actor: actor} do
      {invitation, hash, digest} = open!(actor, person, m, %{proof: "oidc_reauth"})
      assert {invitation.confirmer_kind, invitation.confirmer_id} == {nil, nil}
      assert {:ok, true} = latch_open?(person)

      assert {:ok, _} = PairingInvitations.consume(actor, hash, digest, &admits/1, issue(actor))
      assert {:ok, %{first_method_at: %DateTime{}}} = PersonIdentities.get(server(), person.id)
      assert {:ok, false} = latch_open?(person)

      late = Confirmations.confirmed!(actor, person.id, %{proof: "oidc_reauth"})

      assert {:error, :first_method_used} =
               PairingInvitations.open(
                 actor,
                 attrs(person, m, late, "late"),
                 Confirmations.consuming(actor, late)
               )

      assert {:ok, %{state: "confirmed"}} = PendingConfirmations.get(actor, late.ref)
      assert {:ok, [%{state: "consumed"}]} = PairingInvitations.list(actor, state: :all)

      # The pairing was the person's first method: a passkey is no longer one.
      assert {:error, :first_method_used} =
               Passkeys.register(
                 %Prima.Actor{user_id: person.id},
                 %{
                   user_id: person.id,
                   credential_id: "cred-#{System.unique_integer([:positive])}",
                   rp_id: "home.example",
                   relying_home: "https://home.example",
                   public_key: "cose-key",
                   registration_digest: Prima.Digest.sha256("late-#{System.unique_integer()}"),
                   possession_verified: true,
                   state: "active"
                 },
                 first_method: true
               )
    end

    test "of two unattributed invitations, the first redeemed sets it and the second is refused",
         %{newcomer: person, newcomer_membership: m, newcomer_actor: actor} do
      {first, first_hash, first_digest} = open!(actor, person, m, %{proof: "oidc_reauth"})
      {second, second_hash, second_digest} = open!(actor, person, m, %{proof: "oidc_reauth"})

      assert {:ok, _} =
               PairingInvitations.consume(
                 actor,
                 first_hash,
                 first_digest,
                 &admits/1,
                 issue(actor)
               )

      assert {:error, :first_method_used} =
               PairingInvitations.consume(
                 actor,
                 second_hash,
                 second_digest,
                 &admits/1,
                 issue(actor)
               )

      assert Arca.Repo.get(PairedClient, first.prospective_client_id)
      refute Arca.Repo.get(PairedClient, second.prospective_client_id)
      assert %{state: "pending"} = Arca.Repo.get!(PairingInvitation, second.id)
    end

    test "a failed issuance leaves it open", %{
      newcomer: person,
      newcomer_membership: m,
      newcomer_actor: actor
    } do
      {_invitation, hash, digest} = open!(actor, person, m, %{proof: "oidc_reauth"})

      assert {:error, :certificate_refused} =
               PairingInvitations.consume(actor, hash, digest, &admits/1, fn _ ->
                 {:error, :certificate_refused}
               end)

      assert {:ok, %{first_method_at: nil}} = PersonIdentities.get(server(), person.id)
      assert {:ok, true} = latch_open?(person)
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
  invitation that expires while its redemption waits is refused; of two
  invitations naming no confirmer, the redemption waiting behind the
  other finds the person's first-method latch set and is refused. On
  PostgreSQL the waiter blocks on the row named; on SQLite at the lock
  its transaction takes at entry.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import Arca.Test.Adapter, only: [postgres?: 0]

  alias Arca.{
    ControlPlane,
    DeviceCertificates,
    Members,
    PairedClients,
    PairingInvitations,
    PersonIdentities,
    Users
  }

  alias Arca.PairingInvitationsTest.Confirmations

  alias Arca.Schemas.{
    Athanor,
    CellLease,
    DeviceCertificate,
    ExternalIdentity,
    Membership,
    PairedClient,
    PairingInvitation,
    PendingConfirmation,
    PersonIdentity,
    User
  }

  alias Arca.Test.LockWait
  alias Ecto.Adapters.SQL.Sandbox

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  @gate 7_310_003

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
  defp server, do: Prima.Actor.system()
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
        Arca.Repo.delete_all(where(PendingConfirmation, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(DeviceCertificate, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(PairedClient, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(Membership, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(ExternalIdentity, user_id: ^user_id))
        Arca.Repo.delete_all(where(PersonIdentity, user_id: ^user_id))
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
            },
            also: fn person ->
              {:ok, _} = PersonIdentities.create(server(), Confirmations.identity(person.id))
              :ok
            end
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

  defp assert_waits!(task, backend, fragments) do
    if postgres?(), do: LockWait.await_lock_wait!(backend, fragments)
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

  # The gate's key is held in a transaction the holder keeps open until
  # `open_gate!/1`. A holder that dies with its case is mid-transaction, so
  # its connection is closed rather than lent again, and the key goes with
  # it: a session lock would stay held on the pooled connection.
  defp close_gate! do
    test = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.transaction(
            fn ->
              Arca.Repo.query!("SELECT pg_advisory_xact_lock($1)", [@gate])
              send(test, :gate_closed)
              receive do: (:open -> :ok)
            end,
            timeout: :infinity
          )
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

  # An invitation on a `pairing.begin` confirmation no passkey or paired
  # client gave (the person holds neither), consumed by the verifier
  # inside the opening's transaction. Every one is opened before any is
  # redeemed, while the person's first-method latch is open.
  defp open!(actor, membership, lifetime_ms \\ 300_000) do
    secret = "secret-#{System.unique_integer()}"
    key_digest = Prima.Device.key_digest(:crypto.strong_rand_bytes(32))

    {:ok, invitation} =
      unboxed(fn ->
        confirmation =
          Confirmations.confirmed!(actor, actor.user_id, %{proof: "oidc_reauth"})

        PairingInvitations.open(
          actor,
          %{
            user_id: actor.user_id,
            membership_id: membership.id,
            secret_hash: Prima.Digest.sha256(secret),
            key_digest: key_digest,
            confirmation_ref: confirmation.ref,
            audience_home: "https://home.example",
            lifetime_ms: lifetime_ms
          },
          Confirmations.consuming(actor, confirmation)
        )
      end)

    {invitation, Prima.Digest.sha256(secret), key_digest}
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
  defp held_redemption(actor, hash, key_digest) do
    test = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          PairingInvitations.consume(actor, hash, key_digest, &admits/1, fn invitation ->
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

  defp redemption(actor, hash, key_digest) do
    test = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:waiter, backend()})
          PairingInvitations.consume(actor, hash, key_digest, &admits/1, issue(actor))
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
    {invitation, hash, digest} = open!(actor, membership)
    first = held_redemption(actor, hash, digest)
    {second, pid} = redemption(actor, hash, digest)
    assert_waits!(second, pid, [~s("users"), "FOR UPDATE"])

    send(first.pid, :go)
    assert {:ok, %{client: %{id: client_id}}} = Task.await(first, 25_000)
    assert client_id == invitation.prospective_client_id
    assert {:error, :consumed} = Task.await(second, 25_000)
    assert clients(actor) == 1
  end

  test "of two invitations naming no confirmer, the redemption waiting behind the other finds the latch set",
       %{actor: actor, membership: membership} do
    {first_invitation, first_hash, first_digest} = open!(actor, membership)
    {second_invitation, second_hash, second_digest} = open!(actor, membership)
    assert {nil, nil} == {first_invitation.confirmer_kind, second_invitation.confirmer_kind}

    first = held_redemption(actor, first_hash, first_digest)
    {second, pid} = redemption(actor, second_hash, second_digest)
    assert_waits!(second, pid, [~s("users"), "FOR UPDATE"])

    send(first.pid, :go)
    assert {:ok, %{client: %{id: client_id}}} = Task.await(first, 25_000)
    assert client_id == first_invitation.prospective_client_id
    assert {:error, :first_method_used} = Task.await(second, 25_000)
    assert clients(actor) == 1

    assert {:ok, false} =
             unboxed(fn -> PersonIdentities.first_method_open?(server(), actor.user_id) end)

    assert %{state: "pending"} =
             unboxed(fn -> Arca.Repo.get!(PairingInvitation, second_invitation.id) end)
  end

  test "a revocation waits behind a redemption and finds it consumed", %{
    actor: actor,
    membership: membership
  } do
    {invitation, hash, digest} = open!(actor, membership)
    first = held_redemption(actor, hash, digest)
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

  # The revocation has no pause point but a PostgreSQL trigger; SQLite's write lock orders it.
  @tag :postgres
  test "a redemption waiting behind a revocation reads it revoked", %{
    actor: actor,
    membership: membership
  } do
    {invitation, hash, digest} = open!(actor, membership)
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
    LockWait.await_lock_wait!(revoking, [~s(UPDATE "pairing_invitations")], event: "advisory")
    {second, pid} = redemption(actor, hash, digest)
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
    {_other, holding, holding_digest} = open!(actor, membership)
    {short, hash, digest} = open!(actor, membership, 2_000)

    # Another redemption of the same person holds the person's lock.
    first = held_redemption(actor, holding, holding_digest)
    {second, pid} = redemption(actor, hash, digest)
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

defmodule Arca.PairingInvitationsTest.Confirmations do
  @moduledoc false
  # A `pairing.begin` confirmation of a person in an athanor, opened and
  # proven through `Arca.PendingConfirmations` as the identity domain
  # proves one, and consumed as `Sanctum.Pairing.begin/2` consumes it:
  # by the opening's verifier, inside the transaction that opens the
  # invitation. Written on the caller's connection.

  alias Arca.PendingConfirmations

  @opener "session:pairing-invitations-test"

  @type t :: %{secret: String.t(), ref: String.t(), expected: map()}

  @doc "A local identity row's attributes for `user_id`: no method yet, its latch open."
  @spec identity(String.t()) :: map()
  def identity(user_id) do
    %{
      user_id: user_id,
      provenance: "local",
      live_public_key: :crypto.strong_rand_bytes(32),
      operational_public_key: :crypto.strong_rand_bytes(32),
      live_key_sealed: "sealed-live",
      operational_key_sealed: "sealed-op"
    }
  end

  @doc """
  Open a confirmation of `user_id`'s in the actor's athanor and confirm it
  with `proof` (`Arca.PendingConfirmations.confirm/3`). `:operation`
  defaults to `pairing.begin`.
  """
  @spec confirmed!(Prima.Actor.t(), String.t(), map(), keyword()) :: t()
  def confirmed!(actor, user_id, proof, opts \\ []) do
    secret = "cnf_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    operation = Keyword.get(opts, :operation, "pairing.begin")

    {:ok, record} =
      Prima.Confirmation.new(
        id: Prima.Confirmation.ref(secret),
        home: "https://home.example",
        rp_id: "home.example",
        athanor: actor.athanor_id,
        person: user_id,
        operation: operation,
        args_digest: Prima.Digest.sha256("args-#{System.unique_integer()}"),
        action: "device_pairing",
        preview: %{home: "https://home.example", athanor: "Home", operation: operation},
        challenge: :crypto.strong_rand_bytes(32),
        expires_at: System.system_time(:millisecond) + 300_000
      )

    {:ok, _} =
      PendingConfirmations.open(actor, %{
        record: record,
        opener: @opener,
        asker: %{"kind" => "session"}
      })

    {:ok, %{state: "confirmed"}} = PendingConfirmations.confirm(actor, record.id, proof)

    %{
      secret: secret,
      ref: record.id,
      expected: %{
        user_id: user_id,
        operation: operation,
        args_digest: record.args_digest,
        preview: record.preview,
        opener: @opener
      }
    }
  end

  @doc """
  An opening's verifier: `verify` over the locked rows, then the
  confirmation consumed in the opening's transaction.
  """
  @spec consuming(Prima.Actor.t(), t(), (map() -> :ok | {:error, term()})) ::
          (map() -> :ok | {:error, term()})
  def consuming(actor, confirmation, verify \\ fn _locked -> :ok end) do
    fn locked ->
      with :ok <- verify.(locked),
           {:ok, _consumed} <-
             PendingConfirmations.consume(actor, confirmation.secret, confirmation.expected) do
        :ok
      end
    end
  end
end
