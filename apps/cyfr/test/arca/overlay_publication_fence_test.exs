# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.OverlayPublicationFenceTest.ParkServe do
  @moduledoc false
  # Parks the armed writer's move to the served location, once, so the
  # test can act inside the window between a unit's commit and its
  # finish. The park is before the adapter's own call: nothing of the
  # adapter is held while the writer waits.
  use Arca.Storage.TestDouble

  @gate {__MODULE__, :gate}
  def arm(test_pid, writer), do: :persistent_term.put(@gate, {test_pid, writer})
  def disarm, do: :persistent_term.erase(@gate)

  def replace_tree(actor, path, files) do
    case :persistent_term.get(@gate, nil) do
      {test_pid, writer} when writer == self() ->
        disarm()
        send(test_pid, {:serving, self()})

        receive do
          :proceed -> :ok
        after
          30_000 -> :ok
        end

      _ ->
        :ok
    end

    Arca.Adapters.Local.replace_tree(actor, path, files)
  end
end

defmodule Arca.OverlayPublicationFenceTest.ParkDelete do
  @moduledoc false
  # Parks the armed remover's tenant delete of the unit, once: the window
  # between a unit's retirement and its physical delete.
  use Arca.Storage.TestDouble

  @gate {__MODULE__, :gate}
  def arm(test_pid, writer), do: :persistent_term.put(@gate, {test_pid, writer})
  def disarm, do: :persistent_term.erase(@gate)

  def delete_tree(actor, path) do
    case :persistent_term.get(@gate, nil) do
      {test_pid, writer} when writer == self() ->
        disarm()
        send(test_pid, {:deleting, self(), path})

        receive do
          :proceed -> :ok
        after
          30_000 -> :ok
        end

      _ ->
        :ok
    end

    Arca.Adapters.Local.delete_tree(actor, path)
  end
end

defmodule Arca.OverlayPublicationFenceTest.DiesAtServe do
  @moduledoc false
  # The armed writer dies at its move to the served location: before it
  # (`:before`) — a death between the commit and the finish — or after
  # the adapter has made it (`:after`) — a death between the move and the
  # release of the draft.
  use Arca.Storage.TestDouble

  @gate {__MODULE__, :gate}
  def arm(writer, moment), do: :persistent_term.put(@gate, {writer, moment})
  def disarm, do: :persistent_term.erase(@gate)

  def replace_tree(actor, path, files) do
    case :persistent_term.get(@gate, nil) do
      {writer, :before} when writer == self() ->
        disarm()
        exit(:writer_died)

      {writer, :after} when writer == self() ->
        disarm()
        :ok = Arca.Adapters.Local.replace_tree(actor, path, files)
        exit(:writer_died)

      _ ->
        Arca.Adapters.Local.replace_tree(actor, path, files)
    end
  end
end

defmodule Arca.OverlayPublicationFenceTest do
  @moduledoc """
  The unit write protocol's fence: a commit keeps the unit's draft
  through its finish, so no second commit lands under a move, no removal
  deletes under one, a create during a finish refuses as `:exists`, a
  writer whose draft was taken after a stall serves nothing a reader
  keeps, and a writer that died between its commit and its finish is
  released by repair once its draft has outlived its lifetime.

  The first three cases adopt the assessment probes of 2026-10-17
  (Fable2's finish race, Opus's retire race and `if_absent` probes),
  adapted to the fence: a contender the fence refuses is refused, and
  lands once the holder is done.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.OverlayPublicationFenceTest.{DiesAtServe, ParkDelete, ParkServe}
  alias Arca.Schemas.StorageUnit
  alias Arca.Storage.UnitLocator
  alias Arca.StorageUnits

  @unit ["components", "catalysts", "local", "fenced", "1.0.0"]
  @wasm @unit ++ ["catalyst.wasm"]

  setup tags do
    # Shared: a unit's row is read and written by the tasks a test spawns.
    Cyfr.Test.Sandbox.setup!(tags)

    base = Path.join(System.tmp_dir!(), "overlay_fence_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "seed"))

    prev =
      for k <- [:base_path, :seed_path, :storage_adapter], do: {k, Application.get_env(:arca, k)}

    on_exit(fn ->
      ParkServe.disarm()
      ParkDelete.disarm()
      DiesAtServe.disarm()
      for {k, v} <- prev, do: Application.put_env(:arca, k, v)
      File.rm_rf!(base)
    end)

    Application.put_env(:arca, :base_path, Path.join(base, "data"))
    Application.put_env(:arca, :seed_path, Path.join(base, "seed"))

    {:ok, actor: Sanctum.Context.actor(Sanctum.TestContext.local())}
  end

  defp commit(actor, v, opts \\ []) do
    Arca.Overlay.commit_unit(
      actor,
      @unit,
      {:files,
       [{["cyfr-manifest.json"], ~s({"type":"catalyst","v":#{v}})}, {["catalyst.wasm"], "V#{v}"}]},
      [cap: :exempt] ++ opts
    )
  end

  defp pointer(actor) do
    {root, key} = UnitLocator.unit_key(@unit)
    StorageUnits.current(actor, root, key)
  end

  defp row(actor) do
    {root, key} = UnitLocator.unit_key(@unit)

    Arca.Repo.one(
      from(u in StorageUnit,
        where: u.athanor_id == ^actor.athanor_id and u.root == ^root and u.unit_key == ^key
      )
    )
  end

  # The revisions with objects under the unit's staging area.
  defp staged(actor) do
    prefix = UnitLocator.staging_prefix(@unit)
    {:ok, leaves} = Arca.list_recursive(actor, prefix)
    leaves |> Enum.map(&Enum.at(&1, length(prefix))) |> Enum.uniq() |> Enum.sort()
  end

  defp change(actor) do
    {root, key} = UnitLocator.unit_key(@unit)
    {:ok, token} = Arca.StorageProjectionChanges.snapshot(actor, root, units: [key])
    Enum.find(token.units, &(&1.unit_key == key))
  end

  # Every registered draft, aged past its lifetime: a writer that stalled
  # or died, without the wait.
  defp expire_drafts! do
    long_ago = DateTime.add(DateTime.utc_now(), -2 * StorageUnits.draft_ttl_ms(), :millisecond)
    Arca.Repo.update_all(StorageUnit, set: [updated_at: long_ago])
  end

  # A bounded wait on an observable condition.
  defp wait_until(fun, left \\ 100) do
    cond do
      fun.() -> :ok
      left == 0 -> flunk("the condition never held")
      true -> Process.sleep(50) && wait_until(fun, left - 1)
    end
  end

  # A writer parked at its move to the served location, its commit made.
  defp park_at_serve(actor, v) do
    Application.put_env(:arca, :storage_adapter, ParkServe)
    test_pid = self()

    task =
      Task.async(fn ->
        ParkServe.arm(test_pid, self())
        commit(actor, v)
      end)

    assert_receive {:serving, pid}, 10_000
    {task, pid}
  end

  describe "a commit holds the unit through its finish" do
    test "a second writer is refused while the first holds the unit, and lands after it — " <>
           "a late finish never serves older bytes over a newer commit",
         %{actor: actor} do
      {a, a_pid} = park_at_serve(actor, 1)
      {:ok, %{current_revision: r1}} = pointer(actor)

      # The pointer names revision 1 and its writer still holds the unit:
      # nothing else lands under the move.
      assert {:error, :stale_writer} = commit(actor, 2)
      assert {:error, :exists} = commit(actor, 2, if_absent: true)
      assert {:error, :stale_writer} = Arca.delete_tree(actor, @unit)
      assert {:ok, %{current_revision: ^r1}} = pointer(actor)
      assert %StorageUnit{state: "committed", draft_writer_token: "wrt_" <> _} = row(actor)

      send(a_pid, :proceed)
      assert {:ok, _written} = Task.await(a, 30_000)

      assert {:ok, "V1"} = Arca.get(actor, @wasm)
      assert %StorageUnit{state: "committed", draft_writer_token: nil} = row(actor)
      assert staged(actor) == []

      # The unit is free: the second writer lands whole.
      assert {:ok, _written} = commit(actor, 2)
      {:ok, %{current_revision: r2}} = pointer(actor)
      assert r2 != r1
      assert {:ok, "V2"} = Arca.get(actor, @wasm)
      assert staged(actor) == []
      assert {:ok, :deleted} = Arca.Overlay.drop_unit(actor, @unit)
    end

    test "a writer whose draft was taken after it stalled past the lifetime serves nothing " <>
           "a reader keeps, is told so, and leaves its staging for collection",
         %{actor: actor} do
      {a, a_pid} = park_at_serve(actor, 1)
      {:ok, %{current_revision: r1}} = pointer(actor)
      expire_drafts!()

      # The taker commits revision 2 while the stalled writer is parked
      # inside its own move; its own move waits on the unit's fence.
      b = Task.async(fn -> commit(actor, 2) end)
      wait_until(fn -> match?({:ok, %{current_revision: r}} when r != r1, pointer(actor)) end)
      {:ok, %{current_revision: r2}} = pointer(actor)

      send(a_pid, :proceed)
      assert {:error, :stale_writer} = Task.await(a, 30_000)
      assert {:ok, _written} = Task.await(b, 30_000)

      # The row and the served bytes are the taker's, and the stalled
      # writer's staged objects stay for the collector.
      assert {:ok, %{current_revision: ^r2}} = pointer(actor)
      assert {:ok, "V2"} = Arca.get(actor, @wasm)
      assert %StorageUnit{state: "committed", draft_writer_token: nil} = row(actor)
      assert staged(actor) == [r1]
    end

    test "a create during the first commit's finish refuses as :exists", %{actor: actor} do
      {a, a_pid} = park_at_serve(actor, 1)
      {:ok, %{current_revision: r1}} = pointer(actor)

      assert {:error, :exists} = commit(actor, 2, if_absent: true)

      send(a_pid, :proceed)
      assert {:ok, _written} = Task.await(a, 30_000)
      assert {:ok, %{current_revision: ^r1}} = pointer(actor)
      assert {:ok, "V1"} = Arca.get(actor, @wasm)
    end

    test "an edit inside the unit during its finish is the change that marks the projection; " <>
           "the publication answers all the same",
         %{actor: actor} do
      {a, a_pid} = park_at_serve(actor, 1)
      {:ok, %{current_revision: r1}} = pointer(actor)

      # A plain edit does not wait for the move; its generation overtakes
      # the commit's, and its writer marks it ready.
      assert :ok = Arca.put(actor, @unit ++ ["note.txt"], "an edit")

      send(a_pid, :proceed)
      assert {:ok, _written} = Task.await(a, 30_000)

      assert %{ready: true, tombstone: false, source_revision: ^r1} = change(actor)
      assert {:ok, "V1"} = Arca.get(actor, @wasm)
      assert %StorageUnit{draft_writer_token: nil} = row(actor)
    end
  end

  describe "a removal holds the unit through its delete" do
    test "a republish is refused until the delete has returned, and what it then publishes " <>
           "is kept whole — bytes, row and staging",
         %{actor: actor} do
      assert {:ok, _} = commit(actor, 1)
      assert {:ok, "V1"} = Arca.get(actor, @wasm)

      Application.put_env(:arca, :storage_adapter, ParkDelete)
      test_pid = self()

      a =
        Task.async(fn ->
          ParkDelete.arm(test_pid, self())
          Arca.Overlay.drop_unit(actor, @unit)
        end)

      # Nothing lands under the delete: no commit, no create, no second
      # removal. The row is retiring under the remover's token; readers see
      # no unit.
      assert_receive {:deleting, a_pid, @unit}, 10_000
      assert {:error, :stale_writer} = commit(actor, 2)
      assert {:error, :stale_writer} = commit(actor, 2, if_absent: true)
      assert {:error, :stale_writer} = Arca.delete_tree(actor, @unit)
      assert %StorageUnit{state: "retiring", draft_writer_token: "wrt_" <> _} = row(actor)
      assert {:error, :not_found} = pointer(actor)

      send(a_pid, :proceed)
      assert {:ok, :deleted} = Task.await(a, 30_000)

      assert %StorageUnit{state: "retired", draft_writer_token: nil} = row(actor)
      assert {:error, :not_found} = Arca.get(actor, @wasm)
      assert staged(actor) == []
      assert %{ready: true, tombstone: true} = change(actor)

      # The republish lands whole, and nothing of it is deleted by the
      # removal that preceded it.
      assert {:ok, _written} = commit(actor, 2)
      assert {:ok, %{current_revision: r2}} = pointer(actor)
      assert {:ok, "V2"} = Arca.get(actor, @wasm)

      assert %StorageUnit{state: "committed", current_revision: ^r2, draft_writer_token: nil} =
               row(actor)

      assert staged(actor) == []
      assert %{ready: true, tombstone: false, source_revision: ^r2} = change(actor)
    end

    test "what a removal that died left behind is cleared under the lease too: a republish " <>
           "waits for the second removal, and keeps what it then publishes",
         %{actor: actor} do
      assert {:ok, _} = commit(actor, 1)
      {root, key} = UnitLocator.unit_key(@unit)

      # A removal that retired the row and died before its delete: the
      # row is retired, the bytes still there.
      {:retiring, _generation, token} = StorageUnits.stamped_retire(actor, root, key)
      :ok = StorageUnits.abandon_draft(actor, row(actor), token)
      assert %StorageUnit{state: "retired"} = row(actor)
      assert {:ok, "V1"} = Arca.get(actor, @wasm)
      assert Arca.Overlay.unit_status(actor, @unit) == {:ok, :own}

      Application.put_env(:arca, :storage_adapter, ParkDelete)
      test_pid = self()

      a =
        Task.async(fn ->
          ParkDelete.arm(test_pid, self())
          Arca.Overlay.drop_unit(actor, @unit)
        end)

      assert_receive {:deleting, a_pid, @unit}, 10_000
      assert {:error, :stale_writer} = commit(actor, 2)
      assert %StorageUnit{state: "retiring", draft_writer_token: "wrt_" <> _} = row(actor)

      send(a_pid, :proceed)
      assert {:ok, :deleted} = Task.await(a, 30_000)
      assert %StorageUnit{state: "retired", draft_writer_token: nil} = row(actor)
      assert {:error, :not_found} = Arca.get(actor, @wasm)

      assert {:ok, _written} = commit(actor, 2)
      assert {:ok, "V2"} = Arca.get(actor, @wasm)
      assert staged(actor) == []
    end

    test "a removal is refused while a commit stages, and deletes once the commit has landed",
         %{actor: actor} do
      {a, a_pid} = park_at_serve(actor, 1)

      assert {:error, :stale_writer} = Arca.delete_tree(actor, @unit)

      send(a_pid, :proceed)
      assert {:ok, _written} = Task.await(a, 30_000)
      assert {:ok, "V1"} = Arca.get(actor, @wasm)

      assert :ok = Arca.delete_tree(actor, @unit)
      assert %StorageUnit{state: "retired"} = row(actor)
      assert {:error, :not_found} = Arca.get(actor, @wasm)
    end
  end

  describe "a writer that dies holding the unit" do
    defp dies_at_serve(actor, moment) do
      Application.put_env(:arca, :storage_adapter, DiesAtServe)

      {pid, ref} =
        spawn_monitor(fn ->
          DiesAtServe.arm(self(), moment)
          commit(actor, 1)
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :writer_died}, 30_000
    end

    test "between its commit and its finish: the unit is held for the draft's lifetime, " <>
           "then repair serves what it committed and releases it",
         %{actor: actor} do
      dies_at_serve(actor, :before)

      {:ok, %{current_revision: r1}} = pointer(actor)
      assert {:error, :not_found} = Arca.get(actor, @wasm)
      assert staged(actor) == [r1]

      # Within the lifetime the dead writer's draft still holds the unit:
      # neither a repair nor a commit takes it.
      assert {:error, :stale_writer} = Arca.Overlay.repair_unit(actor, @unit)
      assert {:error, :stale_writer} = commit(actor, 2)
      assert {:error, :not_found} = Arca.get(actor, @wasm)
      assert %StorageUnit{state: "committed", draft_writer_token: "wrt_" <> _} = row(actor)

      expire_drafts!()
      assert {:ok, :repaired} = Arca.Overlay.repair_unit(actor, @unit)

      assert {:ok, "V1"} = Arca.get(actor, @wasm)

      assert %StorageUnit{state: "committed", current_revision: ^r1, draft_writer_token: nil} =
               row(actor)

      assert staged(actor) == []
      assert %{ready: true, source_revision: ^r1} = change(actor)
      assert {:ok, :nothing_pending} = Arca.Overlay.repair_unit(actor, @unit)
    end

    test "after its move and before its release: repair serves the revision again and " <>
           "releases it; a commit after the lifetime replaces it whole",
         %{actor: actor} do
      dies_at_serve(actor, :after)

      {:ok, %{current_revision: r1}} = pointer(actor)
      assert {:ok, "V1"} = Arca.get(actor, @wasm)
      assert staged(actor) == [r1]

      assert {:error, :stale_writer} = Arca.Overlay.repair_unit(actor, @unit)
      assert %StorageUnit{state: "committed", draft_writer_token: "wrt_" <> _} = row(actor)
      expire_drafts!()
      assert {:ok, :repaired} = Arca.Overlay.repair_unit(actor, @unit)
      assert {:ok, "V1"} = Arca.get(actor, @wasm)
      assert %StorageUnit{draft_writer_token: nil} = row(actor)
      assert staged(actor) == []

      # The same death, and the next writer rather than repair: it takes
      # the expired draft and replaces the unit whole.
      dies_at_serve(actor, :after)
      {:ok, %{current_revision: r2}} = pointer(actor)
      assert r2 != r1
      expire_drafts!()
      assert {:ok, _written} = commit(actor, 3)
      assert {:ok, "V3"} = Arca.get(actor, @wasm)
      assert %StorageUnit{state: "committed", draft_writer_token: nil} = row(actor)
      # The dead writer's staged revision is the collector's, not the commit's.
      assert r2 in staged(actor)
    end
  end
end
