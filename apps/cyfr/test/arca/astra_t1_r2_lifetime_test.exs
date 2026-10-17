# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.AstraT1R2LifetimeTest.Park do
  @moduledoc false
  # Parks the armed holder at its delete of a tree — a removal's delete
  # of the retired revision's prefix — once.
  use Arca.Storage.TestDouble

  @gate {__MODULE__, :gate}
  def arm(parent, operation), do: :persistent_term.put(@gate, {parent, self(), operation})
  def clear, do: :persistent_term.erase(@gate)

  def delete_tree(actor, path) do
    park(:delete_tree)
    Arca.Adapters.Local.delete_tree(actor, path)
  end

  defp park(operation) do
    case :persistent_term.get(@gate, nil) do
      {parent, holder, ^operation} when holder == self() ->
        clear()
        send(parent, {:parked, holder, operation})

        receive do
          :continue -> :ok
        end

      _ ->
        :ok
    end
  end
end

defmodule Arca.AstraT1R2LifetimeTest do
  @moduledoc """
  A holder killed with an untrappable exit while it holds the unit:
  adopted from Astra's second T1 review and re-pointed to units served
  from their revision prefixes. The publication holder is parked after
  its commit and before its release, where the lease is held and the
  revision already published; the removal holder at its delete of the
  retired revision's prefix. The node lock releases with the process, the
  lease holds for the draft's lifetime, then repair releases the dead
  draft and a removal finishes.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.AstraT1R2LifetimeTest.Park
  alias Arca.Schemas.StorageUnit
  alias Arca.Storage.UnitLocator
  alias Arca.StorageUnits

  @unit ["components", "catalysts", "local", "killed-fence", "1.0.0"]
  @wasm @unit ++ ["catalyst.wasm"]

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    base = Path.join(System.tmp_dir!(), "astra_t1_kill_#{System.unique_integer([:positive])}")

    previous =
      for key <- [:base_path, :seed_path, :storage_adapter],
          do: {key, Application.fetch_env(:arca, key)}

    on_exit(fn ->
      Park.clear()

      for {key, value} <- previous do
        case value do
          {:ok, present} -> Application.put_env(:arca, key, present)
          :error -> Application.delete_env(:arca, key)
        end
      end

      File.rm_rf!(base)
    end)

    File.mkdir_p!(Path.join(base, "seed"))
    Application.put_env(:arca, :base_path, Path.join(base, "data"))
    Application.put_env(:arca, :seed_path, Path.join(base, "seed"))
    Application.put_env(:arca, :storage_adapter, Park)
    {:ok, actor: Sanctum.Context.actor(Sanctum.TestContext.local())}
  end

  test "a killed publication holder releases its node lock and its committed revision is " <>
         "released by repair once the lease has outlived its lifetime",
       %{actor: actor} do
    {holder, monitor} = park_after_commit(actor, fn -> commit(actor) end)

    assert %StorageUnit{state: "committed", current_revision: revision, draft_writer_token: token} =
             row(actor)

    assert is_binary(token)
    # Published already: readers resolve the row and read the revision.
    assert {:ok, "V1"} = Arca.get(actor, @wasm)
    assert {:error, :stale_writer} = Arca.Overlay.repair_unit(actor, @unit)

    # An untrappable kill does not execute fenced/3's after block.
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :killed}, 10_000
    assert {:error, :stale_writer} = Arca.Overlay.repair_unit(actor, @unit)
    expire_draft!(actor)

    assert {:ok, :repaired} = after_lock_down(fn -> Arca.Overlay.repair_unit(actor, @unit) end)
    assert {:ok, "V1"} = Arca.get(actor, @wasm)

    assert %StorageUnit{state: "committed", current_revision: ^revision, draft_writer_token: nil} =
             row(actor)

    assert {:ok, :nothing_pending} = Arca.Overlay.repair_unit(actor, @unit)
    assert %{ready: true, source_revision: ^revision} = change(actor)
  end

  test "a killed removal holder releases its node lock and an expired removal can finish", %{
    actor: actor
  } do
    assert {:ok, _} = commit(actor)
    {holder, monitor} = park_holder(:delete_tree, fn -> Arca.Overlay.drop_unit(actor, @unit) end)
    assert %StorageUnit{state: "retiring", draft_writer_token: token} = row(actor)
    assert is_binary(token)

    # Readers see no unit from the retirement on, so the drop verb has
    # nothing to drop; a removal at the unit's path is the holder's.
    assert {:error, :not_found} = Arca.Overlay.drop_unit(actor, @unit)
    assert {:error, :stale_writer} = Arca.delete_tree(actor, @unit)

    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :killed}, 10_000
    assert {:error, :stale_writer} = Arca.delete_tree(actor, @unit)
    expire_draft!(actor)

    # The expired removal is taken and finished at the unit's path, where a
    # removal clears what a dead one left.
    assert :ok = after_lock_down(fn -> Arca.delete_tree(actor, @unit) end)
    assert %StorageUnit{state: "retired", draft_writer_token: nil} = row(actor)
    assert {:error, :not_found} = Arca.get(actor, @wasm)
    assert {:ok, _} = commit(actor)
    assert {:ok, "V1"} = Arca.get(actor, @wasm)
  end

  # The holder parked by a telemetry handler on its commit's announcement,
  # which runs in the holder's process after the pointer moved and before
  # the draft is released.
  defp park_after_commit(actor, action) do
    parent = self()
    handler = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(handler) end)
    {root, key} = UnitLocator.unit_key(@unit)

    :ok =
      :telemetry.attach(
        handler,
        Arca.StorageProjectionChanges.event(),
        fn _event, _measurements, metadata, _config ->
          if metadata.athanor_id == actor.athanor_id and metadata.root == root and
               not metadata.ready and self() != parent and
               match?({:ok, _committed}, StorageUnits.current(actor, root, key)) do
            :telemetry.detach(handler)
            send(parent, {:parked, self(), :commit})

            receive do
              :continue -> :ok
            end
          end
        end,
        nil
      )

    {holder, monitor} = spawn_monitor(action)
    stop_on_exit(holder)
    assert_receive {:parked, ^holder, :commit}, 10_000
    {holder, monitor}
  end

  defp park_holder(operation, action) do
    parent = self()

    {holder, monitor} =
      spawn_monitor(fn ->
        Park.arm(parent, operation)
        action.()
      end)

    stop_on_exit(holder)
    assert_receive {:parked, ^holder, ^operation}, 10_000
    {holder, monitor}
  end

  defp stop_on_exit(holder) do
    on_exit(fn ->
      cleanup_monitor = Process.monitor(holder)
      Process.exit(holder, :kill)

      receive do
        {:DOWN, ^cleanup_monitor, :process, ^holder, _} -> :ok
      after
        10_000 -> raise "holder did not stop"
      end
    end)
  end

  # Global's own monitor and this test's monitor need not deliver DOWN in
  # the same order. Only a refusal is retried; a completed repair is final.
  defp after_lock_down(action, remaining \\ 100) do
    case action.() do
      {:error, :stale_writer} when remaining > 0 ->
        Process.sleep(10)
        after_lock_down(action, remaining - 1)

      answer ->
        answer
    end
  end

  defp commit(actor) do
    Arca.Overlay.commit_unit(
      actor,
      @unit,
      {:files,
       [{["cyfr-manifest.json"], ~s({"type":"catalyst","v":1})}, {["catalyst.wasm"], "V1"}]},
      cap: :exempt
    )
  end

  defp row(actor) do
    {root, key} = UnitLocator.unit_key(@unit)

    Arca.Repo.one(
      from u in StorageUnit,
        where: u.athanor_id == ^actor.athanor_id and u.root == ^root and u.unit_key == ^key
    )
  end

  defp change(actor) do
    {root, key} = UnitLocator.unit_key(@unit)
    {:ok, token} = Arca.StorageProjectionChanges.snapshot(actor, root, units: [key])
    Enum.find(token.units, &(&1.unit_key == key))
  end

  defp expire_draft!(actor) do
    {root, key} = UnitLocator.unit_key(@unit)
    old = DateTime.add(DateTime.utc_now(), -2 * StorageUnits.draft_ttl_ms(), :millisecond)

    Arca.Repo.update_all(
      from(u in StorageUnit,
        where: u.athanor_id == ^actor.athanor_id and u.root == ^root and u.unit_key == ^key
      ),
      set: [updated_at: old]
    )
  end
end
