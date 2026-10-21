# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PairedClientsTest do
  @moduledoc """
  The paired client rows: recorded active, with a known source (a
  device's carrying its public key), once per credential in an athanor,
  and only by a member that owns its slot; listed and revoked in the
  actor's own athanor, with `revoked` terminal; revoked by person, across
  athanors only for the platform's own actor. Standing alone decides: no
  row carries a rank. A suspended row, a declared restore's, is listed only
  when its standing is asked for, and re-enabled only from `suspended`,
  under its verifier, by an owner of the slot, closing its person's restore
  and no one else's; a revoked row is never re-enabled.
  """

  # Takes a slot through `Arca.ControlPlane`, which writes the process-wide
  # standing record; each case saves and restores it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ControlPlane
  alias Arca.PairedClients
  alias Arca.Schemas.{CellLease, PairedClient, RestorePerson}

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
        source_id: "src_#{System.unique_integer([:positive])}"
      },
      overrides
    )
  end

  defp record!(actor, overrides \\ %{}) do
    {:ok, row} = PairedClients.record(actor, attrs(overrides))
    row
  end

  defp suspend!(row) do
    {1, _} =
      Arca.Repo.update_all(from(p in PairedClient, where: p.id == ^row.id),
        set: [standing: "suspended"]
      )

    row
  end

  # A person this home holds, whom a restore row can name.
  defp person! do
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()

    {:ok, person} =
      Arca.Users.mint(
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
          key: "github|https://github.com|pcl#{n}",
          provider: "github",
          issuer: "https://github.com",
          subject: "pcl#{n}",
          first_seen_at: now,
          last_seen_at: now
        }
      )

    person.id
  end

  # The person's open row of a declared restore, as the transition writes it.
  defp recovering!(user_id) do
    restore_id = Prima.UUID7.generate_id("rst")
    Arca.Repo.insert!(%RestorePerson{restore_id: restore_id, user_id: user_id, open: true})
    restore_id
  end

  defp open?(user_id, restore_id) do
    Arca.Repo.one(
      from(r in RestorePerson,
        where: r.user_id == ^user_id and r.restore_id == ^restore_id,
        select: r.open
      )
    )
  end

  defp standing(id),
    do: Arca.Repo.one(from(p in PairedClient, where: p.id == ^id, select: p.standing))

  describe "record/2" do
    test "records an active client in the actor's athanor, as a plain map", %{actor: actor} do
      assert {:ok, row} = PairedClients.record(actor, attrs())
      refute is_struct(row)
      assert "pcl_" <> _ = row.id
      assert row.standing == "active"
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

    test "a suspended client is listed only when its standing is asked for", %{actor: actor} do
      active = record!(actor)
      suspended = actor |> record!() |> suspend!()

      assert {:ok, [%{id: active_id}]} = PairedClients.list(actor, [])
      assert active_id == active.id
      assert {:ok, [%{id: ^active_id}]} = PairedClients.list(actor, standing: :active)

      assert {:ok, [%{id: suspended_id, standing: "suspended"}]} =
               PairedClients.list(actor, standing: :suspended)

      assert suspended_id == suspended.id
      assert {:ok, all} = PairedClients.list(actor, standing: :all)
      assert Enum.sort(Enum.map(all, & &1.id)) == Enum.sort([active.id, suspended.id])
    end

    test "the platform's own actor reads one named person's clients in every athanor", %{
      actor: actor
    } do
      elsewhere = Prima.Actor.in_athanor("ath_pcl_far_#{System.unique_integer([:positive])}")
      user_id = "usr_pcl_#{System.unique_integer([:positive])}"
      here = record!(actor, %{user_id: user_id})
      there = elsewhere |> record!(%{user_id: user_id}) |> suspend!()
      _bystander = record!(actor, %{user_id: "usr_pcl_bystander"})

      assert {:ok, rows} =
               PairedClients.list(Prima.Actor.system(), user_id: user_id, standing: :all)

      assert Enum.sort(Enum.map(rows, & &1.id)) == Enum.sort([here.id, there.id])

      assert {:ok, [%{id: there_id}]} =
               PairedClients.list(Prima.Actor.system(), user_id: user_id, standing: :suspended)

      assert there_id == there.id
      assert {:error, :no_athanor} = PairedClients.list(Prima.Actor.system(), standing: :all)
    end
  end

  describe "reenable/4" do
    test "moves a suspended client active under its verifier and closes its person's restore alone",
         %{actor: actor} do
      user_id = person!()
      bystander = person!()
      client = actor |> record!(%{user_id: user_id}) |> suspend!()
      restore_id = recovering!(user_id)
      bystanders = recovering!(bystander)
      test = self()

      verify = fn row ->
        send(test, {:verified, row})
        :ok
      end

      assert {:ok, %{standing: "active", closed_restore_ids: [^restore_id]} = row} =
               PairedClients.reenable(actor, user_id, client.id, verify: verify)

      refute is_struct(row)
      assert row.id == client.id

      # The verifier saw the row as it stood under the lock: suspended.
      assert_received {:verified, %{id: id, standing: "suspended"} = seen}
      assert id == client.id
      refute is_struct(seen)

      assert standing(client.id) == "active"
      assert open?(user_id, restore_id) == false
      assert open?(bystander, bystanders) == true

      # Nothing to re-enable twice, and a person with no open row closes none.
      assert {:error, :not_suspended} =
               PairedClients.reenable(actor, user_id, client.id, verify: verify)

      other = actor |> record!(%{user_id: user_id}) |> suspend!()

      assert {:ok, %{closed_restore_ids: []}} =
               PairedClients.reenable(actor, user_id, other.id, verify: verify)
    end

    test "a verifier's refusal rolls everything back", %{actor: actor} do
      user_id = person!()
      client = actor |> record!(%{user_id: user_id}) |> suspend!()
      restore_id = recovering!(user_id)

      assert {:error, :not_this_proof} =
               PairedClients.reenable(actor, user_id, client.id,
                 verify: fn _row -> {:error, :not_this_proof} end
               )

      assert standing(client.id) == "suspended"
      assert open?(user_id, restore_id) == true
    end

    test "a revoked client is never revived; another person's or athanor's is not found", %{
      actor: actor
    } do
      user_id = person!()
      restore_id = recovering!(user_id)
      ok = fn _row -> :ok end

      revoked = actor |> record!(%{user_id: user_id}) |> suspend!()
      {:ok, %{standing: "revoked"}} = PairedClients.revoke(actor, revoked.id)
      assert {:error, :revoked} = PairedClients.reenable(actor, user_id, revoked.id, verify: ok)
      assert standing(revoked.id) == "revoked"

      suspended = actor |> record!(%{user_id: user_id}) |> suspend!()
      other = Prima.Actor.in_athanor("ath_pcl_other_#{System.unique_integer([:positive])}")

      assert {:error, :not_found} =
               PairedClients.reenable(other, user_id, suspended.id, verify: ok)

      assert {:error, :not_found} =
               PairedClients.reenable(actor, person!(), suspended.id, verify: ok)

      assert {:error, :no_athanor} =
               PairedClients.reenable(Prima.Actor.system(), user_id, suspended.id, verify: ok)

      assert standing(suspended.id) == "suspended"
      assert open?(user_id, restore_id) == true
    end

    test "a stale owner re-enables nothing", %{actor: actor, slot: slot} do
      user_id = person!()
      client = actor |> record!(%{user_id: user_id}) |> suspend!()
      restore_id = recovering!(user_id)

      {1, _} =
        Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
          set: [owner: "someone-else", generation: slot.generation + 1]
        )

      assert {:error, :not_owner} =
               PairedClients.reenable(actor, user_id, client.id, verify: fn _row -> :ok end)

      assert standing(client.id) == "suspended"
      assert open?(user_id, restore_id) == true
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

    test "a suspended client may be revoked, which is terminal", %{actor: actor} do
      row = actor |> record!() |> suspend!()
      assert {:ok, %{standing: "revoked"}} = PairedClients.revoke(actor, row.id)
      assert standing(row.id) == "revoked"
    end

    test "a member that lost its slot may still revoke", %{actor: actor, slot: slot} do
      row = record!(actor)

      {1, _} =
        Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
          set: [owner: "someone-else", generation: slot.generation + 1]
        )

      assert {:ok, %{standing: "revoked"}} = PairedClients.revoke(actor, row.id)
    end
  end
end
