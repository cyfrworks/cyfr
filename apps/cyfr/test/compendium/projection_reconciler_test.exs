# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ProjectionReconcilerTest.Adapter do
  @moduledoc false
  # Local's bytes behind a hook the test sets: `hook.(op, path)` runs in
  # the calling process before a read and may do anything a concurrent
  # writer would.
  use Arca.Storage.TestDouble

  @hook {__MODULE__, :hook}

  def hook(fun) when is_function(fun, 2), do: :persistent_term.put(@hook, fun)
  def clear, do: :persistent_term.erase(@hook)

  def get(actor, path) do
    case :persistent_term.get(@hook, nil) do
      nil -> :ok
      hook -> hook.(:get, path)
    end

    Arca.Adapters.Local.get(actor, path)
  end

  def put(actor, path, content) do
    case :persistent_term.get(@hook, nil) do
      nil ->
        Arca.Adapters.Local.put(actor, path, content)

      hook ->
        case hook.(:put, path) do
          {:error, _} = error -> error
          _pass -> Arca.Adapters.Local.put(actor, path, content)
        end
    end
  end
end

defmodule Compendium.ProjectionReconcilerTest do
  @moduledoc """
  The component registry and the agent index follow the seeded roots:
  a read after a successful write observes it — with no notification
  delivered, no reconciler running, or one that crashed — or answers
  `{:error, :projection_unavailable}`, never a stale row. A replacement
  the tree moved under is retried, three conflicts at most, and leaves
  the old rows standing. The process is only ever a hastener: its
  notification, its startup recovery and its tick each converge on their
  own.
  """

  use ExUnit.Case, async: false

  alias Arca.{StorageProjectionChanges, StorageProjectionRoots}
  alias Compendium.{AgentIndex, ProjectionReconciler, Registry}
  alias Compendium.ProjectionReconcilerTest.Adapter

  @valid_wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
                <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
                <<0x03, 0x02, 0x01, 0x00>> <>
                <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
                <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

  @moduletag :capture_log

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    base = Path.join(System.tmp_dir!(), "projection_#{System.unique_integer([:positive])}")
    prev_base = Application.fetch_env!(:arca, :base_path)
    prev_adapter = Application.get_env(:arca, :storage_adapter)
    Application.put_env(:arca, :base_path, Path.join(base, "data"))
    Application.put_env(:arca, :storage_adapter, Adapter)

    on_exit(fn ->
      Adapter.clear()

      if prev_adapter,
        do: Application.put_env(:arca, :storage_adapter, prev_adapter),
        else: Application.delete_env(:arca, :storage_adapter)

      Application.put_env(:arca, :base_path, prev_base)
      File.rm_rf!(base)
    end)

    ctx = Sanctum.TestContext.local()
    name = "proj-#{System.unique_integer([:positive])}"
    {:ok, ctx: ctx, actor: Sanctum.Context.actor(ctx), name: name}
  end

  defp unit(name), do: ["components", "reagents", "local", name, "1.0.0"]

  defp manifest(description),
    do: Jason.encode!(%{"type" => "reagent", "version" => "1.0.0", "description" => description})

  # A unit laid by plain writes, as the Files page or a guest lays one.
  defp lay!(actor, name, description) do
    :ok = Arca.put(actor, unit(name) ++ ["reagent.wasm"], @valid_wasm)
    :ok = Arca.put(actor, unit(name) ++ ["cyfr-manifest.json"], manifest(description))
  end

  defp stored(actor, name) do
    case Arca.ComponentStorage.get_component(actor, name, "1.0.0", "local") do
      {:ok, row} -> row.description
      {:error, :not_found} -> nil
    end
  end

  defp standing(actor, root) do
    {:ok, standing} = StorageProjectionRoots.epoch(actor, root)
    standing
  end

  defp caught_up?(actor, root \\ "components") do
    %{epoch: epoch, acknowledged_epoch: acknowledged} = standing(actor, root)
    epoch == acknowledged
  end

  # Bounded: a condition checked every 20 ms for at most two seconds.
  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end

  describe "a read after a write" do
    test "observes the write with no reconciler and no notification", %{
      ctx: ctx,
      actor: actor,
      name: name
    } do
      lay!(actor, name, "first")
      refute caught_up?(actor)

      assert {:ok, %{description: "first", source: "filesystem"}} =
               Registry.get(ctx, name, "1.0.0")

      assert caught_up?(actor)

      :ok = Arca.put(actor, unit(name) ++ ["cyfr-manifest.json"], manifest("second"))
      assert {:ok, %{description: "second"}} = Registry.get(ctx, name, "1.0.0")

      assert {:ok, %{components: [%{description: "second"}]}} =
               Registry.search(ctx, %{query: name})
    end

    test "of a deleted unit observes the row gone", %{ctx: ctx, actor: actor, name: name} do
      lay!(actor, name, "doomed")
      assert {:ok, _} = Registry.get(ctx, name, "1.0.0")

      :ok = Arca.delete_tree(actor, unit(name))
      assert {:error, :not_found} = Registry.get(ctx, name, "1.0.0")
      assert stored(actor, name) == nil
    end

    test "of a manifest that no longer validates keeps the row that stood", %{
      ctx: ctx,
      actor: actor,
      name: name
    } do
      lay!(actor, name, "valid")
      assert {:ok, %{description: "valid"}} = Registry.get(ctx, name, "1.0.0")

      # Its identity now disagrees with its directory: no row derives.
      broken = Jason.encode!(%{"type" => "reagent", "version" => "9.9.9"})
      :ok = Arca.put(actor, unit(name) ++ ["cyfr-manifest.json"], broken)

      assert {:ok, %{description: "valid"}} = Registry.get(ctx, name, "1.0.0")
      assert caught_up?(actor)
    end

    test "of the agent tree observes the role in the index", %{ctx: ctx, actor: actor} do
      :ok = Arca.put(actor, ["aqua", "aqua.md"], "---\ntitle: Soul\n---\n\nsoul\n")
      :ok = Arca.put(actor, ["aqua", "roles", "scout.md"], "---\ntitle: Scout\n---\n\nscout\n")

      assert {:ok, rows} = AgentIndex.list(ctx)
      assert "scout" in Enum.map(rows, & &1.name)
      assert caught_up?(actor, "aqua")

      :ok = Arca.delete(actor, ["aqua", "roles", "scout.md"])
      assert {:ok, rows} = AgentIndex.list(ctx)
      refute "scout" in Enum.map(rows, & &1.name)
    end
  end

  describe "a pending change" do
    # A publication whose move to the served location fails: committed,
    # its bytes not yet served.
    defp interrupted!(actor, name) do
      Adapter.hook(fn op, path ->
        if op == :put and List.starts_with?(path, unit(name)), do: {:error, :enospc}, else: :pass
      end)

      files = [{["reagent.wasm"], @valid_wasm}, {["cyfr-manifest.json"], manifest("promoted")}]

      assert {:error, {:finish_failed, :enospc}} =
               Arca.Overlay.commit_unit(actor, unit(name), {:files, files}, cap: :exempt)

      Adapter.clear()
    end

    test "younger than the settle answers unavailable, never the row before it", %{
      ctx: ctx,
      actor: actor,
      name: name
    } do
      interrupted!(actor, name)

      assert {:error, :projection_unavailable} = Registry.get(ctx, name, "1.0.0")
      assert {:error, :projection_unavailable} = Registry.search(ctx, %{})
      refute caught_up?(actor)

      # The agent index is another root's projection, and stands.
      assert {:ok, _} = AgentIndex.list(ctx)
    end

    test "older than the settle is given one repair, and then observed", %{
      ctx: ctx,
      actor: actor,
      name: name
    } do
      interrupted!(actor, name)

      assert :ok = ProjectionReconciler.await(ctx, "components", settle_after_ms: 0)
      assert caught_up?(actor)
      assert {:ok, %{description: "promoted"}} = Registry.get(ctx, name, "1.0.0")
    end
  end

  describe "generation conflicts" do
    test "three answer projection_unavailable and leave the old rows and the change pending", %{
      ctx: ctx,
      actor: actor,
      name: name
    } do
      lay!(actor, name, "old")
      assert {:ok, %{description: "old"}} = Registry.get(ctx, name, "1.0.0")
      :ok = Arca.put(actor, unit(name) ++ ["cyfr-manifest.json"], manifest("new"))

      # Every derivation reads the manifest, and each read lands a change
      # elsewhere under the root: every replacement meets an epoch it did
      # not snapshot.
      test = self()
      manifest_path = unit(name) ++ ["cyfr-manifest.json"]

      Adapter.hook(fn op, path ->
        if op == :get and path == manifest_path do
          send(test, :derived)
          key = "reagents/local/bystander/#{System.unique_integer([:positive])}"
          {:ok, pending} = StorageProjectionChanges.begin_edit(actor, "components", key)
          {:ok, _} = StorageProjectionChanges.finish_edit(actor, "components", key, pending)
        end

        :pass
      end)

      assert {:error, :projection_unavailable} = Registry.get(ctx, name, "1.0.0")
      assert_received :derived
      assert_received :derived
      assert_received :derived
      refute_received :derived

      assert stored(actor, name) == "old"
      refute caught_up?(actor)

      Adapter.clear()
      assert {:ok, %{description: "new"}} = Registry.get(ctx, name, "1.0.0")
      assert caught_up?(actor)
    end
  end

  describe "the process" do
    # Never restarted: a case about a reconciler that is gone keeps it gone.
    defp start!(opts) do
      name = :"projection_reconciler_#{System.unique_integer([:positive])}"
      opts = Keyword.merge([name: name, enabled: true], opts)

      pid =
        start_supervised!(
          Supervisor.child_spec({ProjectionReconciler, opts}, restart: :temporary)
        )

      {name, pid}
    end

    # Its mailbox drained and its recovery done, so nothing is left running
    # when the test's connection goes.
    defp settle(pid), do: :sys.get_state(pid)

    test "attaches exactly the catalog's :projection roster, and detaches when it stops" do
      {name, pid} = start!(interval_ms: :timer.hours(1))
      settle(pid)

      attached =
        for %{id: id, event_name: event} <- :telemetry.list_handlers([]),
            id == ProjectionReconciler.handler_id(name),
            do: event

      assert Enum.sort(attached) == Cyfr.Telemetry.Catalog.consumed_by(:projection)

      :ok = stop_supervised!(name)

      assert Enum.all?(
               :telemetry.list_handlers([]),
               &(&1.id != ProjectionReconciler.handler_id(name))
             )
    end

    test "not enabled, it starts, attaches nothing and ticks nothing", %{actor: actor, name: name} do
      {process, pid} = start!(enabled: false, interval_ms: 10)
      lay!(actor, name, "unwatched")
      Process.sleep(100)

      refute caught_up?(actor)
      assert Process.alive?(pid)

      refute Enum.any?(
               :telemetry.list_handlers([]),
               &(&1.id == ProjectionReconciler.handler_id(process))
             )
    end

    test "a notification reconciles the estate it names", %{actor: actor, name: name} do
      {_process, pid} = start!(interval_ms: :timer.hours(1))
      settle(pid)

      lay!(actor, name, "notified")
      assert eventually(fn -> caught_up?(actor) end)
      settle(pid)
      assert stored(actor, name) == "notified"
    end

    test "a lost notification is recovered by the tick", %{actor: actor, name: name} do
      {process, pid} = start!(interval_ms: 25)
      settle(pid)
      ProjectionReconciler.detach(process)

      lay!(actor, name, "recovered")
      assert eventually(fn -> caught_up?(actor) end)
      settle(pid)
      assert stored(actor, name) == "recovered"
    end

    test "one that starts recovers what was left pending, before any read", %{
      actor: actor,
      name: name
    } do
      lay!(actor, name, "left")
      refute caught_up?(actor)

      {_process, pid} = start!(interval_ms: :timer.hours(1))
      settle(pid)

      assert caught_up?(actor)
      assert stored(actor, name) == "left"
    end

    test "one that crashed costs the next read a reconciliation, nothing more", %{
      ctx: ctx,
      actor: actor,
      name: name
    } do
      {process, pid} = start!(interval_ms: :timer.hours(1))
      settle(pid)
      ProjectionReconciler.detach(process)
      Process.exit(pid, :kill)
      refute Process.alive?(pid)

      lay!(actor, name, "after the crash")
      assert {:ok, %{description: "after the crash"}} = Registry.get(ctx, name, "1.0.0")
      assert caught_up?(actor)
    end
  end
end
