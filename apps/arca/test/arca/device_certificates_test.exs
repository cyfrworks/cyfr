# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.DeviceCertificatesTest do
  @moduledoc """
  The device certificates a home issued: recorded only for a standing
  paired client of the same person whose recorded device key is the
  certificate's (a client paired without one is never certified), naming
  the person's account, the device key's `kid` and the cached head of the
  account when it is recorded, scoped by athanor,
  `active`, `revoked` or `expired` by the database's clock, revoked once
  (a second revocation answers it as it is), and revoked with the client
  it was issued to.
  """

  # Takes the cell's slot, which is process-wide; each case restores it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{DeviceCertificates, PairedClients}
  alias Arca.Schemas.DeviceCertificate

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    hold_slot!()
    athanor = "ath_dct_#{System.unique_integer([:positive])}"
    {:ok, actor: Prima.Actor.in_athanor(athanor), person: person!()}
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

  # A person with an account this home has read.
  defp person! do
    now = DateTime.utc_now()

    {:ok, person} =
      Arca.Test.People.mint(
        Prima.Actor.system(),
        %{
          id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        },
        nil
      )

    Map.merge(person, Arca.Test.People.account!(person.id))
  end

  defp device_client!(actor, person) do
    device_key = :crypto.strong_rand_bytes(32)

    {:ok, client} =
      PairedClients.record(actor, %{
        user_id: person.id,
        source_kind: "device_cert",
        source_id: Prima.Digest.sha256(device_key),
        device_public_key: device_key,
        kid: Prima.Identity.Key.kid(device_key),
        head: person.head
      })

    client
  end

  defp attrs(client, person, overrides \\ %{}) do
    now = DateTime.utc_now()

    Map.merge(
      %{
        paired_client_id: client.id,
        user_id: person.id,
        identifier: person.identifier,
        kid: client.device_public_key && Prima.Identity.Key.kid(client.device_public_key),
        head: person.head,
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
    actor: actor,
    person: person
  } do
    client = device_client!(actor, person)

    assert {:ok, cert} = DeviceCertificates.record(actor, attrs(client, person))
    assert cert.status == "active"
    assert cert.athanor_id == actor.athanor_id
    assert cert.kid == client.kid
    assert cert.head == person.head
    assert {:ok, ^cert} = DeviceCertificates.current(actor, client.id)
    assert {:ok, [^cert]} = DeviceCertificates.list(actor, paired_client_id: client.id)
  end

  test "refuses another person's, another key's, or a revoked client's certificate", %{
    actor: actor,
    person: person
  } do
    client = device_client!(actor, person)
    other = person!()

    assert {:error, :client_not_active} =
             DeviceCertificates.record(actor, attrs(client, other))

    another_key = :crypto.strong_rand_bytes(32)

    assert {:error, :device_key_mismatch} =
             DeviceCertificates.record(
               actor,
               attrs(client, person, %{
                 device_public_key: another_key,
                 kid: Prima.Identity.Key.kid(another_key)
               })
             )

    {:ok, _} = PairedClients.revoke(actor, client.id)
    assert {:error, :client_not_active} = DeviceCertificates.record(actor, attrs(client, person))

    elsewhere = Prima.Actor.in_athanor("ath_dct_other_#{System.unique_integer([:positive])}")
    fresh = device_client!(actor, person)

    assert {:error, :client_not_active} =
             DeviceCertificates.record(elsewhere, attrs(fresh, person))
  end

  test "a client paired without a device key is never certified", %{
    actor: actor,
    person: person
  } do
    for {kind, source} <- [{"session", "ses_dct"}, {"api_key", "key_dct"}] do
      {:ok, client} =
        PairedClients.record(actor, %{
          user_id: person.id,
          source_kind: kind,
          source_id: "#{source}_#{System.unique_integer([:positive])}"
        })

      assert is_nil(client.device_public_key)
      key = :crypto.strong_rand_bytes(32)

      assert {:error, :no_device_key} =
               DeviceCertificates.record(
                 actor,
                 attrs(client, person, %{device_public_key: key, kid: Prima.Identity.Key.kid(key)})
               )
    end

    assert {:ok, []} = DeviceCertificates.list(actor, status: :all)
  end

  test "a certificate names the person's account, its device key's kid and the cached head", %{
    actor: actor,
    person: person
  } do
    client = device_client!(actor, person)

    assert {:error, {:invalid, %{identifier: _, kid: _, head: _}}} =
             DeviceCertificates.record(
               actor,
               attrs(client, person, %{identifier: nil, kid: Prima.Digest.sha256("x"), head: nil})
             )

    assert {:error, :stale_head} =
             DeviceCertificates.record(
               actor,
               attrs(client, person, %{head: Prima.Digest.sha256("gone")})
             )

    other = person!()

    assert {:error, :stale_head} =
             DeviceCertificates.record(
               actor,
               attrs(client, person, %{identifier: other.identifier})
             )

    assert {:ok, _} = DeviceCertificates.record(actor, attrs(client, person))
  end

  test "expiry is read from the clock and never stored", %{actor: actor, person: person} do
    client = device_client!(actor, person)
    past = DateTime.add(DateTime.utc_now(), -10, :second)

    {:ok, cert} =
      DeviceCertificates.record(
        actor,
        attrs(client, person, %{not_before: DateTime.add(past, -60, :second), expires_at: past})
      )

    assert cert.status == "expired"
    assert cert.state == "active"
    assert {:error, :not_found} = DeviceCertificates.current(actor, client.id)
    assert {:ok, [%{id: id}]} = DeviceCertificates.list(actor, status: :expired)
    assert id == cert.id
  end

  test "a certificate revoked twice answers it as it is; another athanor's is not found", %{
    actor: actor,
    person: person
  } do
    client = device_client!(actor, person)
    {:ok, cert} = DeviceCertificates.record(actor, attrs(client, person))

    assert {:ok, %{status: "revoked"} = revoked} = DeviceCertificates.revoke(actor, cert.id)
    assert {:ok, ^revoked} = DeviceCertificates.revoke(actor, cert.id)

    other = Prima.Actor.in_athanor("ath_dct_elsewhere")
    assert {:error, :not_found} = DeviceCertificates.revoke(other, cert.id)
    assert {:error, :not_found} = DeviceCertificates.get(other, cert.id)
  end

  test "revoking a paired client revokes its certificates", %{actor: actor, person: person} do
    client = device_client!(actor, person)
    {:ok, cert} = DeviceCertificates.record(actor, attrs(client, person))

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
