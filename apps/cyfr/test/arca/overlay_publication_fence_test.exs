# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.OverlayPublicationFenceTest.ParkDelete do
  @moduledoc false
  # Parks the armed remover's delete of a tree — a removal's delete of the
  # retired revision's prefix — once: the window between a unit's
  # retirement and its physical delete.
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

defmodule Arca.OverlayPublicationFenceTest do
  @moduledoc """
  The unit write protocol's fence: a commit keeps the unit's draft
  through its release, so no second commit lands under it, no removal
  deletes under it, a create during the window refuses as `:exists`, a
  writer whose lease another member took is told so at its release and
  serves nothing a reader keeps, and a writer that died between its
  commit and its release is released by repair once its draft has
  outlived its lifetime.

  The cases adopt the assessment probes of 2026-10-17 (Fable2's finish
  race, Opus's retire race and `if_absent` probes), re-pointed to units
  served from their revision prefixes: a publication is parked between
  its commit and its release by a telemetry handler on the commit's
  announcement, which runs in the writer's process; a removal at its
  delete of the retired revision's prefix. A contender the fence refuses
  is refused, and lands once the holder is done.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.OverlayPublicationFenceTest.ParkDelete
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
      ParkDelete.disarm()
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

  # The revisions with objects under the unit's staging area — the served
  # one among them.
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

  # A handler on the root's projection announcements that runs `fun` in
  # the process announcing a unit's commit — the writer's own, after its
  # pointer moved and before its draft is released — once.
  defp on_commit(actor, fun) do
    test_pid = self()
    handler = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(handler) end)
    {root, key} = UnitLocator.unit_key(@unit)

    :ok =
      :telemetry.attach(
        handler,
        Arca.StorageProjectionChanges.event(),
        fn _event, _measurements, metadata, _config ->
          if metadata.athanor_id == actor.athanor_id and metadata.root == root and
               not metadata.ready and self() != test_pid and
               match?({:ok, %{draft_writer_token: t}} when is_binary(t), pointer(actor)) do
            :telemetry.detach(handler)
            fun.()
          end
        end,
        nil
      )

    {root, key}
  end

  # A writer parked between its commit and its release, its revision
  # published and its draft held.
  defp park_after_commit(actor, v) do
    test_pid = self()

    on_commit(actor, fn ->
      send(test_pid, {:committed, self()})

      receive do
        :proceed -> :ok
      after
        30_000 -> :ok
      end
    end)

    task = Task.async(fn -> commit(actor, v) end)
    assert_receive {:committed, pid}, 10_000
    {task, pid}
  end

  describe "a commit holds the unit through its release" do
    test "a second writer is refused while the first holds the unit, and lands after it — " <>
           "a late release never moves what a newer commit published",
         %{actor: actor} do
      {a, a_pid} = park_after_commit(actor, 1)
      {:ok, %{current_revision: r1}} = pointer(actor)

      # The pointer names revision 1 and its writer still holds the unit:
      # nothing else lands under the release, and the revision is read
      # already, since a reader resolves the row.
      assert {:error, :stale_writer} = commit(actor, 2)
      assert {:error, :exists} = commit(actor, 2, if_absent: true)
      assert {:error, :stale_writer} = Arca.delete_tree(actor, @unit)
      assert {:ok, %{current_revision: ^r1}} = pointer(actor)
      assert %StorageUnit{state: "committed", draft_writer_token: "wrt_" <> _} = row(actor)
      assert {:ok, "V1"} = Arca.get(actor, @wasm)

      send(a_pid, :proceed)
      assert {:ok, _written} = Task.await(a, 30_000)

      assert {:ok, "V1"} = Arca.get(actor, @wasm)
      assert %StorageUnit{state: "committed", draft_writer_token: nil} = row(actor)
      assert staged(actor) == [r1]

      # The unit is free: the second writer lands whole, and the first
      # revision's prefix is the collector's.
      assert {:ok, _written} = commit(actor, 2)
      {:ok, %{current_revision: r2}} = pointer(actor)
      assert r2 != r1
      assert {:ok, "V2"} = Arca.get(actor, @wasm)
      assert Enum.sort([r1, r2]) == staged(actor)
      assert {:ok, :deleted} = Arca.Overlay.drop_unit(actor, @unit)
    end

    test "a writer stalled past the lifetime keeps the unit against every taker on this node; " <>
           "a lease another member takes refuses its release, and its revision is the collector's",
         %{actor: actor} do
      {a, a_pid} = park_after_commit(actor, 1)
      {:ok, %{current_revision: r1}} = pointer(actor)
      expire_drafts!()

      # On this node the stalled writer's lock keeps the unit however old
      # its token: a taker is refused at once and takes nothing.
      assert {:error, :stale_writer} = commit(actor, 2)
      assert {:error, :stale_writer} = Arca.delete_tree(actor, @unit)
      assert {:ok, %{current_revision: ^r1}} = pointer(actor)
      assert %StorageUnit{draft_writer_token: "wrt_" <> _ = held} = row(actor)
      assert held != "wrt_thief"

      # Another member takes the expired lease through the rows alone.
      {root, key} = UnitLocator.unit_key(@unit)

      assert {:ok, %StorageUnit{draft_writer_token: "wrt_thief"}} =
               StorageUnits.register_draft(actor, root, key, "wrt_thief")

      send(a_pid, :proceed)
      assert {:error, :stale_writer} = Task.await(a, 30_000)

      # The stalled writer is told, moved nothing, and the row is the
      # taker's; the revision it committed is still the pointer's, since
      # the taker committed nothing.
      assert %StorageUnit{
               state: "committed",
               current_revision: ^r1,
               draft_writer_token: "wrt_thief"
             } =
               row(actor)

      assert {:ok, "V1"} = Arca.get(actor, @wasm)
      assert staged(actor) == [r1]

      :ok = StorageUnits.abandon_draft(actor, row(actor), "wrt_thief")
      assert {:ok, _written} = commit(actor, 2)
      assert {:ok, "V2"} = Arca.get(actor, @wasm)
    end

    test "a create during the first commit's release refuses as :exists", %{actor: actor} do
      {a, a_pid} = park_after_commit(actor, 1)
      {:ok, %{current_revision: r1}} = pointer(actor)

      assert {:error, :exists} = commit(actor, 2, if_absent: true)

      send(a_pid, :proceed)
      assert {:ok, _written} = Task.await(a, 30_000)
      assert {:ok, %{current_revision: ^r1}} = pointer(actor)
      assert {:ok, "V1"} = Arca.get(actor, @wasm)
    end

    test "an edit inside the unit during its release is the change that marks the projection; " <>
           "the publication answers all the same",
         %{actor: actor} do
      {a, a_pid} = park_after_commit(actor, 1)
      {:ok, %{current_revision: r1}} = pointer(actor)

      # A plain edit does not wait for the release; it lands in the
      # committed revision, its generation overtakes the commit's, and its
      # writer marks it ready.
      assert :ok = Arca.put(actor, @unit ++ ["note.txt"], "an edit")

      send(a_pid, :proceed)
      assert {:ok, _written} = Task.await(a, 30_000)

      assert %{ready: true, tombstone: false, source_revision: ^r1} = change(actor)
      assert {:ok, "V1"} = Arca.get(actor, @wasm)
      assert {:ok, "an edit"} = Arca.get(actor, @unit ++ ["note.txt"])
      assert %StorageUnit{draft_writer_token: nil} = row(actor)
    end
  end

  describe "a removal holds the unit through its delete" do
    test "a republish is refused until the delete has returned, and what it then publishes " <>
           "is kept whole — bytes, row and prefix",
         %{actor: actor} do
      assert {:ok, _} = commit(actor, 1)
      {:ok, %{current_revision: r1}} = pointer(actor)
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
      # no unit; the delete names the retired revision's prefix alone.
      assert_receive {:deleting, a_pid, deleting}, 10_000
      assert deleting == UnitLocator.revision_prefix(@unit, r1)
      assert {:error, :stale_writer} = commit(actor, 2)
      assert {:error, :stale_writer} = commit(actor, 2, if_absent: true)
      assert {:error, :stale_writer} = Arca.delete_tree(actor, @unit)
      assert %StorageUnit{state: "retiring", draft_writer_token: "wrt_" <> _} = row(actor)
      assert {:error, :not_found} = pointer(actor)
      assert {:error, :not_found} = Arca.get(actor, @wasm)

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

      assert staged(actor) == [r2]
      assert %{ready: true, tombstone: false, source_revision: ^r2} = change(actor)
    end

    test "what a removal that died left behind is the collector's: the retired row keeps " <>
           "readers out, and a republish lands beside it",
         %{actor: actor} do
      assert {:ok, _} = commit(actor, 1)
      {root, key} = UnitLocator.unit_key(@unit)
      {:ok, %{current_revision: r1}} = pointer(actor)

      # A removal that retired the row and died before its delete: the
      # row is retired, the revision's prefix still there.
      {:retiring, _generation, token} = StorageUnits.stamped_retire(actor, root, key)
      :ok = StorageUnits.abandon_draft(actor, row(actor), token)
      assert %StorageUnit{state: "retired"} = row(actor)
      assert staged(actor) == [r1]

      # No reader sees it, and the unit is absent to every surface.
      assert {:error, :not_found} = Arca.get(actor, @wasm)
      assert Arca.Overlay.unit_status(actor, @unit) == {:ok, :absent}
      assert {:error, :not_found} = Arca.Overlay.drop_unit(actor, @unit)

      # The collector takes the prefix the pointer no longer names, after
      # the grace; a republish lands meanwhile, beside it.
      assert {:ok, _written} = commit(actor, 2)
      {:ok, %{current_revision: r2}} = pointer(actor)
      assert {:ok, "V2"} = Arca.get(actor, @wasm)
      assert Enum.sort([r1, r2]) == staged(actor)

      later = DateTime.add(DateTime.utc_now(), :timer.hours(48), :millisecond)
      assert {:ok, %{collected: 1}} = Arca.StorageGC.sweep(actor, now: later)
      assert staged(actor) == [r2]
      assert {:ok, "V2"} = Arca.get(actor, @wasm)
    end

    test "a removal is refused while a commit stages, and deletes once the commit has landed",
         %{actor: actor} do
      {a, a_pid} = park_after_commit(actor, 1)

      assert {:error, :stale_writer} = Arca.delete_tree(actor, @unit)

      send(a_pid, :proceed)
      assert {:ok, _written} = Task.await(a, 30_000)
      assert {:ok, "V1"} = Arca.get(actor, @wasm)

      assert :ok = Arca.delete_tree(actor, @unit)
      assert %StorageUnit{state: "retired"} = row(actor)
      assert {:error, :not_found} = Arca.get(actor, @wasm)
      assert staged(actor) == []
    end
  end

  describe "a writer that dies holding the unit" do
    # Killed outright at the announcement: an exit raised inside a
    # telemetry handler is caught and detached by telemetry.
    defp dies_after_commit(actor) do
      on_commit(actor, fn -> Process.exit(self(), :kill) end)
      {pid, ref} = spawn_monitor(fn -> commit(actor, 1) end)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 30_000
    end

    test "between its commit and its release: the revision is read already, the unit is held " <>
           "for the draft's lifetime, then repair releases it and marks it ready",
         %{actor: actor} do
      dies_after_commit(actor)

      {:ok, %{current_revision: r1}} = pointer(actor)
      assert {:ok, "V1"} = Arca.get(actor, @wasm)
      assert staged(actor) == [r1]
      assert %{ready: false, source_revision: ^r1} = change(actor)

      # Within the lifetime the dead writer's draft still holds the unit:
      # neither a repair nor a commit takes it.
      assert {:error, :stale_writer} = Arca.Overlay.repair_unit(actor, @unit)
      assert {:error, :stale_writer} = commit(actor, 2)
      assert %StorageUnit{state: "committed", draft_writer_token: "wrt_" <> _} = row(actor)

      expire_drafts!()
      assert {:ok, :repaired} = Arca.Overlay.repair_unit(actor, @unit)

      assert {:ok, "V1"} = Arca.get(actor, @wasm)

      assert %StorageUnit{state: "committed", current_revision: ^r1, draft_writer_token: nil} =
               row(actor)

      assert staged(actor) == [r1]
      assert %{ready: true, source_revision: ^r1} = change(actor)
      assert {:ok, :nothing_pending} = Arca.Overlay.repair_unit(actor, @unit)
    end

    test "a commit after the lifetime replaces the dead writer's unit whole, and the dead " <>
           "writer's revision is the collector's",
         %{actor: actor} do
      dies_after_commit(actor)
      {:ok, %{current_revision: r1}} = pointer(actor)

      expire_drafts!()
      assert {:ok, _written} = commit(actor, 2)
      {:ok, %{current_revision: r2}} = pointer(actor)
      assert {:ok, "V2"} = Arca.get(actor, @wasm)
      assert %StorageUnit{state: "committed", draft_writer_token: nil} = row(actor)
      assert Enum.sort([r1, r2]) == staged(actor)
    end
  end
end
