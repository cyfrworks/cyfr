# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.DeviceCertificatesTest do
  @moduledoc """
  The device certificates a home issued: recorded only for a standing
  paired client of the same person whose recorded device key is the
  certificate's (a client paired without one is never certified), an
  identity subject only under the `key_epoch` current when it is recorded,
  scoped by athanor,
  `active`, `revoked` or `expired` by the database's clock, revoked once
  (a second revocation answers it as it is), and revoked with the client
  it was issued to.
  """

  # Takes the cell's slot, which is process-wide; each case restores it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{DeviceCertificates, DirectoryHeads, PairedClients, PersonIdentities, Users}
  alias Arca.Schemas.DeviceCertificate

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    hold_slot!()
    athanor = "ath_dct_#{System.unique_integer([:positive])}"
    {:ok, actor: Prima.Actor.in_athanor(athanor)}
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

  defp device_client!(actor, user_id \\ "usr_dct") do
    device_key = :crypto.strong_rand_bytes(32)

    {:ok, client} =
      PairedClients.record(actor, %{
        user_id: user_id,
        source_kind: "device_cert",
        source_id: Prima.Digest.sha256(device_key),
        device_public_key: device_key,
        label: "phone"
      })

    client
  end

  defp identifier, do: "per_" <> Prima.Digest.sha256_hex("g-#{System.unique_integer()}")

  defp cached!(identifier, epoch) do
    {:ok, _head} =
      DirectoryHeads.put(Prima.Actor.system(), %{
        identifier: identifier,
        genesis: "genesis",
        directory_url: "https://dir.example",
        head_hash: epoch,
        key_epoch: epoch,
        state: "{}"
      })

    :ok
  end

  # A person whose own identity, `identifier`, this home holds the keys of.
  defp local_enrolled!(identifier) do
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()

    {:ok, person} =
      Users.mint(
        Prima.Actor.system(),
        %{
          id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
          provider: "github",
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        },
        %{
          key: "github|https://github.com|dct#{n}",
          provider: "github",
          issuer: "https://github.com",
          subject: "dct#{n}",
          first_seen_at: now,
          last_seen_at: now
        },
        also: fn person ->
          {:ok, _} =
            PersonIdentities.create(Prima.Actor.system(), %{
              user_id: person.id,
              provenance: "local",
              identifier: identifier,
              head_hash: Prima.Digest.sha256("head-#{n}"),
              directory_url: "https://dir.example",
              live_public_key: :crypto.strong_rand_bytes(32),
              operational_public_key: :crypto.strong_rand_bytes(32),
              live_key_sealed: "l",
              operational_key_sealed: "o"
            })

          :ok
        end
      )

    person
  end

  defp attrs(client, overrides \\ %{}) do
    now = DateTime.utc_now()

    Map.merge(
      %{
        paired_client_id: client.id,
        user_id: client.user_id,
        subject_kind: "local",
        device_public_key: client.device_public_key,
        issuing_home: "https://home.example",
        audience_home: "https://home.example",
        not_before: DateTime.add(now, -60, :second),
        expires_at: DateTime.add(now, 3600, :second),
        certificate: "cert-#{System.unique_integer()}",
        digest: Prima.Digest.sha256("cert-#{System.unique_integer()}")
      },
      overrides
    )
  end

  test "records a certificate for a standing device client, answered with its status", %{
    actor: actor
  } do
    client = device_client!(actor)

    assert {:ok, cert} = DeviceCertificates.record(actor, attrs(client))
    assert cert.status == "active"
    assert cert.athanor_id == actor.athanor_id
    assert {:ok, ^cert} = DeviceCertificates.current(actor, client.id)
    assert {:ok, [^cert]} = DeviceCertificates.list(actor, paired_client_id: client.id)
  end

  test "refuses another person's, another key's, or a revoked client's certificate", %{
    actor: actor
  } do
    client = device_client!(actor)

    assert {:error, :client_not_active} =
             DeviceCertificates.record(actor, attrs(client, %{user_id: "usr_other"}))

    assert {:error, :device_key_mismatch} =
             DeviceCertificates.record(
               actor,
               attrs(client, %{device_public_key: :crypto.strong_rand_bytes(32)})
             )

    {:ok, _} = PairedClients.revoke(actor, client.id)
    assert {:error, :client_not_active} = DeviceCertificates.record(actor, attrs(client))

    other = Prima.Actor.in_athanor("ath_dct_other_#{System.unique_integer([:positive])}")
    fresh = device_client!(actor)
    assert {:error, :client_not_active} = DeviceCertificates.record(other, attrs(fresh))
  end

  test "a client paired without a device key is never certified", %{actor: actor} do
    for {kind, source} <- [{"session", "ses_dct"}, {"api_key", "key_dct"}] do
      {:ok, client} =
        PairedClients.record(actor, %{
          user_id: "usr_dct",
          source_kind: kind,
          source_id: "#{source}_#{System.unique_integer([:positive])}"
        })

      assert is_nil(client.device_public_key)

      assert {:error, :no_device_key} =
               DeviceCertificates.record(
                 actor,
                 attrs(client, %{device_public_key: :crypto.strong_rand_bytes(32)})
               )
    end

    assert {:ok, []} = DeviceCertificates.list(actor, status: :all)
  end

  test "an identity subject names its identifier and key_epoch; a local one names neither", %{
    actor: actor
  } do
    client = device_client!(actor)
    identifier = identifier()
    epoch = Prima.Digest.sha256("epoch-#{System.unique_integer()}")
    cached!(identifier, epoch)

    assert {:error, {:invalid, %{identifier: _, key_epoch: _}}} =
             DeviceCertificates.record(actor, attrs(client, %{subject_kind: "identity"}))

    assert {:error, {:invalid, %{identifier: _}}} =
             DeviceCertificates.record(actor, attrs(client, %{identifier: identifier}))

    assert {:ok, %{subject_kind: "identity"}} =
             DeviceCertificates.record(
               actor,
               attrs(client, %{subject_kind: "identity", identifier: identifier, key_epoch: epoch})
             )
  end

  test "an identity subject binds only the key_epoch current when it is recorded", %{
    actor: actor
  } do
    client = device_client!(actor)
    identifier = identifier()
    epoch = Prima.Digest.sha256("epoch-#{System.unique_integer()}")

    identity = fn id, key_epoch ->
      attrs(client, %{subject_kind: "identity", identifier: id, key_epoch: key_epoch})
    end

    # No cached head of the identifier, and not the person's own: no epoch
    # of it is current here.
    assert {:error, :stale_key_epoch} =
             DeviceCertificates.record(actor, identity.(identifier, epoch))

    cached!(identifier, epoch)

    assert {:error, :stale_key_epoch} =
             DeviceCertificates.record(actor, identity.(identifier, Prima.Digest.sha256("gone")))

    assert {:ok, _} = DeviceCertificates.record(actor, identity.(identifier, epoch))
    assert {:ok, [_]} = DeviceCertificates.list(actor, status: :all)
  end

  test "an identity subject of the person's own local identity binds its current head", %{
    actor: actor
  } do
    identifier = identifier()
    person = local_enrolled!(identifier)
    client = device_client!(actor, person.id)

    head =
      Arca.Repo.one!(
        from(p in Arca.Schemas.PersonIdentity,
          where: p.user_id == ^person.id,
          select: p.head_hash
        )
      )

    own = fn key_epoch ->
      attrs(client, %{subject_kind: "identity", identifier: identifier, key_epoch: key_epoch})
    end

    # No cached head is needed for the person's own identity, but its epoch
    # is still compared: only the current head, the entry that introduced
    # the live key, is current.
    assert {:error, :stale_key_epoch} =
             DeviceCertificates.record(actor, own.(Prima.Digest.sha256("own-epoch")))

    assert {:ok, %{identifier: ^identifier}} = DeviceCertificates.record(actor, own.(head))

    # Another person's identifier this home caches no head of is not theirs.
    other = device_client!(actor, local_enrolled!(identifier()).id)

    assert {:error, :stale_key_epoch} =
             DeviceCertificates.record(
               actor,
               attrs(other, %{
                 subject_kind: "identity",
                 identifier: identifier,
                 key_epoch: Prima.Digest.sha256("own-epoch")
               })
             )
  end

  test "expiry is read from the clock and never stored", %{actor: actor} do
    client = device_client!(actor)
    past = DateTime.add(DateTime.utc_now(), -10, :second)

    {:ok, cert} =
      DeviceCertificates.record(
        actor,
        attrs(client, %{not_before: DateTime.add(past, -60, :second), expires_at: past})
      )

    assert cert.status == "expired"
    assert cert.state == "active"
    assert {:error, :not_found} = DeviceCertificates.current(actor, client.id)
    assert {:ok, [%{id: id}]} = DeviceCertificates.list(actor, status: :expired)
    assert id == cert.id
  end

  test "a certificate revoked twice answers it as it is; another athanor's is not found", %{
    actor: actor
  } do
    client = device_client!(actor)
    {:ok, cert} = DeviceCertificates.record(actor, attrs(client))

    assert {:ok, %{status: "revoked"} = revoked} = DeviceCertificates.revoke(actor, cert.id)
    assert {:ok, ^revoked} = DeviceCertificates.revoke(actor, cert.id)

    other = Prima.Actor.in_athanor("ath_dct_elsewhere")
    assert {:error, :not_found} = DeviceCertificates.revoke(other, cert.id)
    assert {:error, :not_found} = DeviceCertificates.get(other, cert.id)
  end

  test "revoking a paired client revokes its certificates", %{actor: actor} do
    client = device_client!(actor)
    {:ok, cert} = DeviceCertificates.record(actor, attrs(client))

    {:ok, _} = PairedClients.revoke(actor, client.id)

    assert %{state: "revoked"} =
             Arca.Repo.one(from(c in DeviceCertificate, where: c.id == ^cert.id))
  end

  test "an actor with no athanor is refused" do
    system = Prima.Actor.system()
    assert {:error, :no_athanor} = DeviceCertificates.record(system, %{})
    assert {:error, :no_athanor} = DeviceCertificates.list(system, [])
    assert {:error, :no_athanor} = DeviceCertificates.revoke(system, "dct_x")
  end
end
