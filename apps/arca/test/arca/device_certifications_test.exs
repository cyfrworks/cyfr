# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.DeviceCertificationsTest do
  @moduledoc """
  What a home certified for its people's devices at other homes: one row
  per person, other home and client, written by a fresh certification
  under the person's lock with its confirmation consumed in the same
  transaction and the person's head the certification's `key_epoch`, and
  extended by a renewal only while every condition still holds under that
  lock. One person's certification never blocks another's, and a person
  reaches only their own.
  """

  # Takes the cell's slot, which is process-wide; each case restores it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{DeviceCertifications, Users}
  alias Arca.Schemas.{CellLease, DeviceCertification, PersonIdentity, User}

  @hub "https://hub.example"

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    slot = hold_slot!()
    {:ok, person: enrolled!(), slot: slot}
  end

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

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

  defp digest(seed), do: Prima.Digest.sha256("#{seed}-#{System.unique_integer()}")

  # A person whose keys are here, enrolled under an identifier at a head.
  defp enrolled! do
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
          key: "github|https://github.com|dcf#{n}",
          provider: "github",
          issuer: "https://github.com",
          subject: "dcf#{n}",
          first_seen_at: now,
          last_seen_at: now
        }
      )

    identifier = "per_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    head = digest("genesis")

    Arca.Repo.insert!(%PersonIdentity{
      id: Prima.UUID7.generate_id("pid"),
      user_id: person.id,
      identifier: identifier,
      provenance: "local",
      enrollment: "enrolled",
      head_hash: head,
      genesis_hash: head
    })

    %{id: person.id, identifier: identifier, head: head}
  end

  defp as(person), do: %Prima.Actor{user_id: person.id}

  defp attrs(person, overrides \\ %{}) do
    Map.merge(
      %{
        user_id: person.id,
        identifier: person.identifier,
        key_epoch: person.head,
        client_id: "pcl_hub1",
        device_public_key: :crypto.strong_rand_bytes(32),
        audience_home: @hub,
        audience_athanor: "ath_hub1",
        expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
      },
      overrides
    )
  end

  defp ok, do: fn -> :ok end

  defp move_head!(person) do
    head = digest("rotate")

    {1, _} =
      Arca.Repo.update_all(
        from(p in PersonIdentity, where: p.user_id == ^person.id),
        set: [head_hash: head]
      )

    head
  end

  defp rows(person),
    do: Arca.Repo.all(from(c in DeviceCertification, where: c.user_id == ^person.id))

  describe "certify/3" do
    test "records one row per person, home and client, replaced by a fresh certification",
         %{person: person} do
      first = attrs(person)
      assert {:ok, row} = DeviceCertifications.certify(as(person), first, ok())
      assert "dcf_" <> _ = row.id
      assert row.state == "active"
      assert row.key_epoch == person.head
      assert row.audience_athanor == "ath_hub1"

      # The same binding again, for another device key: the row is
      # replaced, never a second one written.
      again = attrs(person, %{device_public_key: :crypto.strong_rand_bytes(32)})
      assert {:ok, replaced} = DeviceCertifications.certify(as(person), again, ok())
      assert replaced.id == row.id
      assert replaced.device_public_key == again.device_public_key
      assert replaced.revision == row.revision + 1
      assert [_one] = rows(person)

      # Another client at the same home is a row of its own.
      other = attrs(person, %{client_id: "pcl_hub2"})
      assert {:ok, _} = DeviceCertifications.certify(as(person), other, ok())
      assert length(rows(person)) == 2
    end

    test "one person's certification never blocks another's of the same home and client",
         %{person: person} do
      someone = enrolled!()
      assert {:ok, _} = DeviceCertifications.certify(as(person), attrs(person), ok())
      assert {:ok, theirs} = DeviceCertifications.certify(as(someone), attrs(someone), ok())
      assert theirs.user_id == someone.id
    end

    test "the verify step's refusal, and a head that is not the key_epoch, write nothing",
         %{person: person} do
      assert {:error, :refused_here} =
               DeviceCertifications.certify(as(person), attrs(person), fn ->
                 {:error, :refused_here}
               end)

      assert rows(person) == []

      move_head!(person)

      assert {:error, :stale_key_epoch} =
               DeviceCertifications.certify(as(person), attrs(person), ok())

      assert rows(person) == []
    end

    test "a person reaches only their own; a malformed one is refused before any write",
         %{person: person} do
      someone = enrolled!()

      assert {:error, :cross_tenant} =
               DeviceCertifications.certify(as(someone), attrs(person), ok())

      assert {:error, {:invalid, errors}} =
               DeviceCertifications.certify(
                 as(person),
                 attrs(person, %{audience_home: "not a home", key_epoch: "nope"}),
                 ok()
               )

      assert Map.has_key?(errors, :audience_home)
      assert Map.has_key?(errors, :key_epoch)
      assert rows(person) == []

      assert {:error, :cross_tenant} =
               DeviceCertifications.get(as(someone), person.id, @hub, "pcl_hub1")
    end
  end

  describe "renew/3" do
    setup %{person: person} do
      binding = attrs(person)
      {:ok, row} = DeviceCertifications.certify(as(person), binding, ok())
      %{row: row, binding: binding}
    end

    defp renewal(binding, overrides \\ %{}) do
      Map.merge(
        %{
          key_epoch: binding.key_epoch,
          device_public_key: binding.device_public_key,
          audience_athanor: binding.audience_athanor,
          expires_at: DateTime.add(binding.expires_at, 1_800, :second)
        },
        overrides
      )
    end

    test "moves the expiry, and nothing else; an earlier one leaves it as it is",
         %{row: row, binding: binding} do
      later = renewal(binding)
      assert {:ok, renewed} = DeviceCertifications.renew(Prima.Actor.system(), row.id, later)
      assert DateTime.compare(renewed.expires_at, later.expires_at) == :eq
      assert renewed.key_epoch == row.key_epoch
      assert renewed.device_public_key == row.device_public_key

      earlier = renewal(binding, %{expires_at: binding.expires_at})
      assert {:ok, kept} = DeviceCertifications.renew(Prima.Actor.system(), row.id, earlier)
      assert DateTime.compare(kept.expires_at, later.expires_at) == :eq
    end

    test "a head that moved ends the certification, whatever the renewal names",
         %{person: person, row: row, binding: binding} do
      head = move_head!(person)

      assert {:error, :certification_ended} =
               DeviceCertifications.renew(Prima.Actor.system(), row.id, renewal(binding))

      assert {:error, :certification_ended} =
               DeviceCertifications.renew(
                 Prima.Actor.system(),
                 row.id,
                 renewal(binding, %{key_epoch: head})
               )

      assert [%{expires_at: expires_at}] = rows(person)
      assert DateTime.compare(expires_at, binding.expires_at) == :eq
    end

    test "another device key or athanor, a denied person or a withdrawn row renews nothing",
         %{person: person, row: row, binding: binding} do
      assert {:error, :binding_changed} =
               DeviceCertifications.renew(
                 Prima.Actor.system(),
                 row.id,
                 renewal(binding, %{device_public_key: :crypto.strong_rand_bytes(32)})
               )

      assert {:error, :binding_changed} =
               DeviceCertifications.renew(
                 Prima.Actor.system(),
                 row.id,
                 renewal(binding, %{audience_athanor: "ath_other"})
               )

      {1, _} =
        Arca.Repo.update_all(from(u in User, where: u.id == ^person.id), set: [status: "denied"])

      assert {:error, :not_standing} =
               DeviceCertifications.renew(Prima.Actor.system(), row.id, renewal(binding))

      {1, _} =
        Arca.Repo.update_all(from(u in User, where: u.id == ^person.id), set: [status: "active"])

      {1, _} =
        Arca.Repo.update_all(from(c in DeviceCertification, where: c.id == ^row.id),
          set: [state: "revoked"]
        )

      assert {:error, :revoked} =
               DeviceCertifications.renew(Prima.Actor.system(), row.id, renewal(binding))

      assert {:error, :not_found} =
               DeviceCertifications.renew(Prima.Actor.system(), "dcf_nobody", renewal(binding))
    end

    test "a person renews only their own", %{row: row, binding: binding} do
      someone = enrolled!()

      assert {:error, :cross_tenant} =
               DeviceCertifications.renew(as(someone), row.id, renewal(binding))
    end

    test "a member that no longer holds its slot writes nothing",
         %{person: person, row: row, binding: binding, slot: slot} do
      {1, _} =
        Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
          set: [owner: "someone-else", generation: slot.generation + 1]
        )

      assert {:error, :not_owner} =
               DeviceCertifications.renew(Prima.Actor.system(), row.id, renewal(binding))

      assert {:error, :not_owner} =
               DeviceCertifications.certify(
                 as(person),
                 attrs(person, %{client_id: "pcl_hub3"}),
                 ok()
               )

      assert [%{expires_at: expires_at}] = rows(person)
      assert DateTime.compare(expires_at, binding.expires_at) == :eq
    end
  end
end
