# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.StaleMemberUnitRemovalTest do
  @moduledoc """
  A unit's removal is the slot holder's, as its commit is: ARCHITECTURE.md
  §6.1 has a stale owner overwrite no successor's state, with the
  guarantee verified live in the transaction that writes. A member whose
  slot a successor took over is refused `{:error, :not_owner}` at the
  unit's retirement (`Arca.StorageUnits.stamped_retire/4`), with the row
  and the bytes untouched — whether its cached standing still says it
  holds the slot, or has already read it lost while a handler admitted
  earlier goes on. The fence is the retirement's own transaction, never
  the entry gate the removal passed on its way in.
  """

  # Writes the process-wide standing record, the claimant switch and the
  # storage base path; each case restores them.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ControlPlane
  alias Arca.Schemas.CellLease
  alias Arca.Storage.UnitLocator
  alias Arca.StorageUnits

  @sentinel "cyfr-manifest.json"
  @observer :stale_member_unit_removal_observer

  @slot_keys [
    {ControlPlane, :standing},
    {ControlPlane, :generation},
    {ControlPlane, :slot}
  ]

  # A declared provider whose one operation removes a unit through the
  # facade, as `Compendium.Registry`'s cleanup does: it tells the test it
  # was admitted, then waits to be resumed.
  defmodule RemovalProvider do
    @behaviour Prima.Provider

    def service, do: "removal_fence"

    def tools do
      [
        Prima.Operation.tool([
          Prima.Operation.new(
            "unit_removal",
            "remove",
            "Remove a unit",
            [Prima.Arg.new("unit", :string, required: true)],
            kind: :write,
            sources: [],
            planes: [:external]
          )
        ])
      ]
    end

    def handle("unit_removal", ctx, %{"action" => "remove", "unit" => unit}) do
      send(:stale_member_unit_removal_observer, {:entered, self()})

      receive do
        :resume ->
          case Arca.delete_tree(Sanctum.Context.actor(ctx), String.split(unit, "/")) do
            :ok -> {:ok, %{removed: true}}
            error -> error
          end
      end
    end
  end

  setup tags do
    # Shared: the gate's handler runs in a task of its own.
    Cyfr.Test.Sandbox.setup!(tags)

    base = Path.join(System.tmp_dir!(), "removal_fence_#{System.unique_integer([:positive])}")
    seed = Path.join(base, "seed")
    File.mkdir_p!(seed)
    prev_base = Application.fetch_env!(:arca, :base_path)
    prev_seed = Application.fetch_env!(:arca, :seed_path)
    Application.put_env(:arca, :base_path, Path.join(base, "data"))
    Application.put_env(:arca, :seed_path, seed)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, prev_base)
      Application.put_env(:arca, :seed_path, prev_seed)
      File.rm_rf!(base)
    end)

    # The work a case starts stops before its directory goes.
    Cyfr.Test.Sandbox.stop_work_on_exit()

    ctx = Sanctum.TestContext.local()
    name = "fence-#{System.unique_integer([:positive])}"

    {:ok,
     ctx: ctx,
     actor: Sanctum.Context.actor(ctx),
     unit: ["components", "catalysts", "local", name, "1.0.0"]}
  end

  describe "a unit removal under the member's live slot" do
    test "a member whose slot was taken over, its cached standing still held, retires nothing and deletes nothing",
         %{actor: actor, unit: unit} do
      slot = claimant!("cached")
      assert {:ok, _} = commit(actor, unit, "one")
      {root, key} = UnitLocator.unit_key(unit)

      assert {:ok, %{state: "committed", current_revision: revision}} =
               StorageUnits.current(actor, root, key)

      physical = UnitLocator.revision_prefix(unit, revision) ++ [@sentinel]

      :ok = take_over!(slot)
      assert ControlPlane.held?()

      # Control: the same member's commit is refused by the slot fence.
      assert {:error, :not_owner} = commit(actor, unit, "two")

      assert {:error, :not_owner} = Arca.delete_tree(actor, unit)

      assert {:ok, %{state: "committed", current_revision: ^revision}} =
               StorageUnits.current(actor, root, key)

      assert Arca.get(actor, unit ++ [@sentinel]) == {:ok, body("one")}
      assert Arca.Adapters.Local.get(actor, physical) == {:ok, body("one")}
    end

    test "a removal admitted under the slot and resumed after the member lost it leaves the successor's unit intact",
         %{ctx: ctx, actor: actor, unit: unit} do
      old = claimant!("resumed")
      assert {:ok, _} = commit(actor, unit, "one")
      {root, key} = UnitLocator.unit_key(unit)
      Process.register(self(), @observer)

      Sanctum.Catalog.with_providers([RemovalProvider], fn ->
        request =
          Task.async(fn ->
            Sanctum.Gate.call_external(
              "unit_removal",
              ctx,
              %{"action" => "remove", "unit" => Enum.join(unit, "/")},
              runner: :inline
            )
          end)

        assert_receive {:entered, handler}, 5_000

        # The handler passed its entry gate under the slot. A takeover
        # lands while it is stopped before the unit's retirement: the
        # lease runs out on the cell's clock and a successor boot takes
        # the row.
        :ok = lapse_slot!(old)
        assert {:ok, successor} = ControlPlane.take(old.node, old.node <> "#boot_b", 60_000)
        assert successor.generation > old.generation

        # The successor commits a new revision of the same unit.
        assert {:ok, _} = commit(actor, unit, "two")
        assert {:ok, %{current_revision: revision}} = StorageUnits.current(actor, root, key)
        physical = UnitLocator.revision_prefix(unit, revision) ++ [@sentinel]
        assert Arca.Adapters.Local.get(actor, physical) == {:ok, body("two")}

        # This member's cached standing reads its own slot as lost, as it
        # does once its countdown has run out.
        ControlPlane.record_slot(old)
        ControlPlane.record_generation(old.generation)
        ControlPlane.record(:lost)
        assert ControlPlane.check_held(old) == :lost
        assert ControlPlane.member_slot() == {:error, :not_owner}

        # Control: the same member's commit is refused for the slot.
        assert {:error, :not_owner} = commit(actor, unit, "stale")

        send(handler, :resume)
        assert Task.await(request, 5_000) == {:error, :not_owner}

        assert {:ok, %{state: "committed", current_revision: ^revision}} =
                 StorageUnits.current(actor, root, key)

        assert Arca.get(actor, unit ++ [@sentinel]) == {:ok, body("two")}
        assert Arca.Adapters.Local.get(actor, physical) == {:ok, body("two")}
      end)
    end
  end

  defp body(tag), do: ~s({"type":"catalyst","revision":"#{tag}"})

  defp commit(actor, unit, tag),
    do: Arca.Overlay.commit_unit(actor, unit, {:files, [{[@sentinel], body(tag)}]}, cap: :exempt)

  # A claimant runs, as a deployment's does, and this member holds its
  # slot: the umbrella's test configuration runs none. Restored when the
  # case ends, registered before anything changes.
  defp claimant!(name) do
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
    node = "node-removal-#{name}-#{System.unique_integer([:positive])}"
    {:ok, slot} = ControlPlane.take(node, node <> "#boot_a", 60_000)
    slot
  end

  # A successor boot takes the member's row over, as a takeover past the
  # lease does; this member's cached standing does not hear of it.
  defp take_over!(%{node: node, generation: generation}) do
    {1, _} =
      Arca.Repo.update_all(
        from(l in CellLease, where: l.node == ^node),
        set: [owner: node <> "#boot_b", generation: generation + 1]
      )

    :ok
  end

  # The lease ran out on the cell's clock, as time would leave it.
  defp lapse_slot!(%{node: node}) do
    {1, _} =
      Arca.Repo.update_all(from(l in CellLease, where: l.node == ^node),
        set: [lease_until: DateTime.add(Arca.ServerMetaStorage.now!(), -60, :second)]
      )

    :ok
  end
end
