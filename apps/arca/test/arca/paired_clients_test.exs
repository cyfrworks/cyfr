# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PairedClientsTest do
  @moduledoc """
  The paired client rows: recorded active, with a known source (a
  device's carrying its public key), once per credential in an athanor,
  and only by a member that owns its slot; listed and revoked in the
  actor's own athanor, with `revoked` terminal; revoked by person, across
  athanors only for the platform's own actor. Standing alone decides: no
  row carries a rank.
  """

  # Takes a slot through `Arca.ControlPlane`, which writes the process-wide
  # standing record; each case saves and restores it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ControlPlane
  alias Arca.PairedClients
  alias Arca.Schemas.{CellLease, PairedClient}

  @keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    saved = Map.new(@keys, &{&1, :persistent_term.get(&1, :absent)})
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

    # A claimant runs, and this member holds its slot.
    Application.put_env(:arca, :control_plane_claim_enabled, true)
    node = "node-pcl-#{System.unique_integer([:positive])}"
    {:ok, slot} = ControlPlane.take(node, node <> "#boot_a", 60_000)

    athanor = "ath_pcl_#{System.unique_integer([:positive])}"
    {:ok, actor: Prima.Actor.in_athanor(athanor), slot: slot}
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        user_id: "usr_pcl",
        source_kind: "session",
        source_id: "src_#{System.unique_integer([:positive])}",
        label: "Firefox on the desk"
      },
      overrides
    )
  end

  defp record!(actor, overrides \\ %{}) do
    {:ok, row} = PairedClients.record(actor, attrs(overrides))
    row
  end

  describe "record/2" do
    test "records an active client in the actor's athanor, as a plain map", %{actor: actor} do
      assert {:ok, row} = PairedClients.record(actor, attrs())
      refute is_struct(row)
      assert "pcl_" <> _ = row.id
      assert row.standing == "active"
      refute Map.has_key?(row, :class)
      assert row.athanor_id == actor.athanor_id
      assert {:ok, [^row]} = PairedClients.list(actor, [])
    end

    test "a device client carries its key, under the id its invitation reserved", %{actor: actor} do
      device_key = :crypto.strong_rand_bytes(32)
      reserved = Prima.UUID7.generate_id("pcl")

      assert {:ok, row} =
               PairedClients.record(
                 actor,
                 attrs(%{
                   id: reserved,
                   source_kind: "device_cert",
                   device_public_key: device_key
                 })
               )

      assert row.id == reserved
      assert row.device_public_key == device_key

      assert {:error, :conflict} =
               PairedClients.record(
                 actor,
                 attrs(%{id: reserved, source_kind: "device_cert", device_public_key: device_key})
               )

      assert {:error, {:invalid, %{device_public_key: _}}} =
               PairedClients.record(actor, attrs(%{source_kind: "device_cert"}))

      assert {:error, {:invalid, %{device_public_key: _}}} =
               PairedClients.record(actor, attrs(%{device_public_key: device_key}))
    end

    test "every source kind is recorded, and nothing else", %{actor: actor} do
      assert {:ok, _} = PairedClients.record(actor, attrs(%{source_kind: "api_key"}))

      assert {:error, {:invalid, %{source_kind: _}}} =
               PairedClients.record(actor, attrs(%{source_kind: "cookie"}))

      assert {:error, {:invalid, %{source_id: _}}} =
               PairedClients.record(actor, Map.delete(attrs(), :source_id))

      assert {:error, {:invalid, %{user_id: _}}} =
               PairedClients.record(actor, Map.delete(attrs(), :user_id))
    end

    test "one client per credential in an athanor", %{actor: actor} do
      row = record!(actor)
      assert {:error, :conflict} = PairedClients.record(actor, attrs(%{source_id: row.source_id}))

      other = Prima.Actor.in_athanor("ath_pcl_other_#{System.unique_integer([:positive])}")
      assert {:ok, _} = PairedClients.record(other, attrs(%{source_id: row.source_id}))
    end

    test "a stale owner records nothing", %{actor: actor, slot: slot} do
      {1, _} =
        Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
          set: [owner: "someone-else", generation: slot.generation + 1]
        )

      assert {:error, :not_owner} = PairedClients.record(actor, attrs())
      assert Arca.Repo.aggregate(PairedClient, :count) == 0
    end

    test "an actor that names no athanor is refused" do
      assert {:error, :no_athanor} = PairedClients.record(Prima.Actor.system(), attrs())
      assert {:error, :no_athanor} = PairedClients.list(Prima.Actor.system(), [])
      assert {:error, :no_athanor} = PairedClients.revoke(Prima.Actor.system(), "pcl_x")
    end
  end

  describe "list/2" do
    test "narrows by person and by standing, active by default", %{actor: actor} do
      mine = record!(actor)
      theirs = record!(actor, %{user_id: "usr_other"})
      gone = record!(actor)
      {:ok, _} = PairedClients.revoke(actor, gone.id)

      assert {:ok, active} = PairedClients.list(actor, [])
      assert Enum.map(active, & &1.id) |> Enum.sort() == Enum.sort([mine.id, theirs.id])

      assert {:ok, [%{id: id}]} = PairedClients.list(actor, user_id: "usr_other")
      assert id == theirs.id

      assert {:ok, [%{id: revoked_id}]} = PairedClients.list(actor, standing: :revoked)
      assert revoked_id == gone.id
      assert {:ok, all} = PairedClients.list(actor, standing: :all)
      assert length(all) == 3

      other = Prima.Actor.in_athanor("ath_pcl_other_#{System.unique_integer([:positive])}")
      assert {:ok, []} = PairedClients.list(other, [])
    end
  end

  describe "revocation" do
    test "revoke/2 is terminal, and another athanor's row is not found", %{actor: actor} do
      row = record!(actor)
      other = Prima.Actor.in_athanor("ath_pcl_other")

      assert {:error, :not_found} = PairedClients.revoke(other, row.id)
      assert {:ok, %{standing: "revoked"} = revoked} = PairedClients.revoke(actor, row.id)
      assert {:ok, ^revoked} = PairedClients.revoke(actor, row.id)
      assert {:error, :not_found} = PairedClients.revoke(actor, "pcl_absent")
    end

    test "a member that lost its slot may still revoke", %{actor: actor, slot: slot} do
      row = record!(actor)

      {1, _} =
        Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
          set: [owner: "someone-else", generation: slot.generation + 1]
        )

      assert {:ok, %{standing: "revoked"}} = PairedClients.revoke(actor, row.id)
    end

    test "a person's clients go in every athanor only for the platform's own actor", %{
      actor: actor
    } do
      elsewhere = Prima.Actor.in_athanor("ath_pcl_elsewhere_#{System.unique_integer([:positive])}")
      here = record!(actor)
      there = record!(elsewhere)
      bystander = record!(actor, %{user_id: "usr_bystander"})

      assert {:ok, [id]} = PairedClients.revoke_for_user(actor, "usr_pcl")
      assert id == here.id
      assert {:ok, [%{id: there_id}]} = PairedClients.list(elsewhere, [])
      assert there_id == there.id

      assert {:ok, [id]} = PairedClients.revoke_for_user(Prima.Actor.system(), "usr_pcl")
      assert id == there.id
      assert {:ok, []} = PairedClients.revoke_for_user(Prima.Actor.system(), "usr_pcl")
      assert {:ok, [%{id: bystander_id}]} = PairedClients.list(actor, [])
      assert bystander_id == bystander.id
    end
  end
end
