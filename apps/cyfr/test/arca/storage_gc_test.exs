# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.StorageGCTest.Adapter do
  @moduledoc false
  # Local's bytes behind a hook the test sets: `hook.(op, actor, path)` runs
  # in the calling process before the operation and may answer
  # `{:error, reason}` to fail it, or `exit/1` — a process that died at
  # exactly that operation.
  use Arca.Storage.TestDouble

  @hook {__MODULE__, :hook}

  def hook(fun) when is_function(fun, 3), do: :persistent_term.put(@hook, fun)
  def clear, do: :persistent_term.erase(@hook)

  defp through(op, actor, path, fun) do
    case :persistent_term.get(@hook, nil) do
      nil ->
        fun.()

      hook ->
        case hook.(op, actor, path) do
          {:error, _} = error -> error
          _pass -> fun.()
        end
    end
  end

  def put(actor, path, content),
    do:
      through(:put, actor, path, fn ->
        Arca.Adapters.Local.put(actor, path, content)
      end)

  def delete(actor, path),
    do:
      through(:delete, actor, path, fn ->
        Arca.Adapters.Local.delete(actor, path)
      end)

  def replace_tree(actor, path, files),
    do:
      through(:replace_tree, actor, path, fn ->
        Arca.Adapters.Local.replace_tree(actor, path, files)
      end)

  def list_recursive(actor, path),
    do:
      through(:list, actor, path, fn ->
        Arca.Adapters.Local.list_recursive(actor, path)
      end)

  def list_prefix(actor, path),
    do:
      through(:list, actor, path, fn ->
        Arca.Adapters.Local.list_prefix(actor, path)
      end)
end

defmodule Arca.StorageGCTest do
  @moduledoc """
  What the collector keeps and what it takes: the pointer, a live draft
  and a live holder's pin keep a staged revision, read again immediately
  before its deletion; everything else goes after the grace, marker last.
  Repair moves only the revision a row names, proven against the journal,
  and objects alone never make a pointer.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  # A move that fails is logged by the overlay, as it should be.
  @moduletag :capture_log

  alias Arca.Schemas.StorageUnit
  alias Arca.Storage.UnitLocator
  alias Arca.StorageGC
  alias Arca.StorageGCTest.Adapter
  alias Arca.StorageUnits

  @sentinel "cyfr-manifest.json"
  @day :timer.hours(24)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    base = Path.join(System.tmp_dir!(), "storage_gc_#{System.unique_integer([:positive])}")
    prev_base = Application.fetch_env!(:cyfr, :base_path)
    prev_seed = Application.fetch_env!(:cyfr, :seed_path)
    prev_adapter = Application.get_env(:cyfr, :storage_adapter)

    File.mkdir_p!(Path.join(base, "seed/components"))
    Application.put_env(:cyfr, :base_path, Path.join(base, "data"))
    Application.put_env(:cyfr, :seed_path, Path.join(base, "seed"))
    Application.put_env(:cyfr, :storage_adapter, Adapter)

    on_exit(fn ->
      if prev_adapter,
        do: Application.put_env(:cyfr, :storage_adapter, prev_adapter),
        else: Application.delete_env(:cyfr, :storage_adapter)

      Adapter.clear()
      Application.put_env(:cyfr, :base_path, prev_base)
      Application.put_env(:cyfr, :seed_path, prev_seed)
      File.rm_rf!(base)
    end)

    ctx = Sanctum.TestContext.local()
    name = "gc-#{System.unique_integer([:positive])}"

    {:ok,
     ctx: ctx,
     actor: Sanctum.Context.actor(ctx),
     unit: ["components", "catalysts", "local", name, "1.0.0"]}
  end

  # ---------------------------------------------------------------------------
  # Vocabulary
  # ---------------------------------------------------------------------------

  defp files(tag) do
    [
      {[@sentinel], ~s({"revision":"#{tag}"})},
      {["a.txt"], "a of #{tag}"},
      {["sub", "b.txt"], "b of #{tag}"}
    ]
  end

  defp whole(tag), do: Map.new(files(tag))

  defp commit(ctx, unit, tag),
    do:
      Arca.Overlay.commit_unit(Sanctum.Context.actor(ctx), unit, {:files, files(tag)},
        cap: :exempt
      )

  defp served(ctx, unit) do
    {:ok, read} = Arca.read_subtree(Sanctum.Context.actor(ctx), UnitLocator.served_path(unit))
    Map.new(read)
  end

  # The names of what is staged for a unit, by revision.
  defp staged(ctx, unit) do
    prefix = UnitLocator.staging_prefix(unit)
    {:ok, leaves} = Arca.list_recursive(Sanctum.Context.actor(ctx), prefix)

    leaves
    |> Enum.map(&Enum.drop(&1, length(prefix)))
    |> Enum.group_by(&hd/1, &Enum.join(tl(&1), "/"))
    |> Map.new(fn {revision, names} -> {revision, Enum.sort(names)} end)
  end

  defp pointer(actor, unit) do
    {root, key} = UnitLocator.unit_key(unit)
    StorageUnits.current(actor, root, key)
  end

  defp row(actor, unit) do
    {root, key} = UnitLocator.unit_key(unit)

    Arca.Repo.one(
      from(u in StorageUnit,
        where: u.athanor_id == ^actor.athanor_id and u.root == ^root and u.unit_key == ^key
      )
    )
  end

  defp served?(path, unit), do: List.starts_with?(path, unit)
  defp staged_object?(path), do: UnitLocator.staging?(path)

  # A whole revision's objects under a prefix no row names — what a writer
  # that lost, or anyone with a put, leaves behind.
  defp lay_prefix(ctx, unit, revision, tag, opts \\ []) do
    if Keyword.get(opts, :marker, true) do
      marker = Jason.encode!(%{"revision" => revision, "started_at" => iso(DateTime.utc_now())})
      :ok = Arca.put(Sanctum.Context.actor(ctx), UnitLocator.marker_path(unit, revision), marker)
    end

    for {rel, bytes} <- files(tag) do
      :ok =
        Arca.put(
          Sanctum.Context.actor(ctx),
          UnitLocator.staged_object(unit, revision, rel),
          bytes
        )
    end

    revision
  end

  defp iso(at), do: DateTime.to_iso8601(at)
  defp later(ms), do: DateTime.add(DateTime.utc_now(), ms, :millisecond)

  # A commit whose move to the served location fails: the row and the
  # journal stand, the revision stays staged.
  defp commit_unserved(ctx, unit, tag) do
    Adapter.hook(fn op, _ctx, path ->
      if op in [:put, :replace_tree] and served?(path, unit), do: {:error, :enospc}, else: :pass
    end)

    assert {:error, {:finish_failed, :enospc}} = commit(ctx, unit, tag)
    Adapter.clear()
  end

  # A writer that dies with its revision half staged: the draft held, the
  # marker and one object under the prefix.
  defp writer_dies_staging(ctx, unit, tag) do
    Adapter.hook(fn op, _ctx, path ->
      if op == :put and staged_object?(path) and List.last(path) == "b.txt",
        do: exit(:writer_died),
        else: :pass
    end)

    {pid, ref} = spawn_monitor(fn -> commit(ctx, unit, tag) end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :writer_died}, 30_000
    Adapter.clear()
  end

  defp candidate(unit, revision) do
    {root, key} = UnitLocator.unit_key(unit)

    %{
      root: root,
      unit_key: key,
      unit: unit,
      revision: revision,
      prefix: UnitLocator.revision_prefix(unit, revision),
      marker?: true
    }
  end

  # Every storage operation the hook reported, as `{op, athanor_id}`.
  defp storage_messages(acc \\ []) do
    receive do
      {:storage, op, athanor, _path} -> storage_messages([{op, athanor} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp start_build(ctx) do
    id = Cyfr.UUID7.build_id()
    :ok = Arca.BuildRecords.record_started(Sanctum.Context.actor(ctx), id, "c:local.gc:1.0.0")
    id
  end

  defp open_turn(ctx) do
    {:ok, thread} = Arca.ThreadStorage.create(Sanctum.Context.actor(ctx))

    {:ok, %{turn: turn}} =
      Arca.TurnStorage.accept_message(Sanctum.Context.actor(ctx), thread.id, %{
        message: %{author: ctx.user_id, content: "@aqua go"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    turn
  end

  # ---------------------------------------------------------------------------
  # Drafts
  # ---------------------------------------------------------------------------

  describe "a draft" do
    test "that is live keeps its prefix, however old the prefix", %{
      ctx: ctx,
      actor: actor,
      unit: unit
    } do
      writer_dies_staging(ctx, unit, "one")
      assert [{revision, [".in-progress" | _half]}] = Map.to_list(staged(ctx, unit))

      # Older than the grace, and the draft still inside its lifetime plus it.
      now = later(@day + :timer.minutes(5))

      assert {:ok, %{collected: 0, examined: 1}} = StorageGC.sweep(actor, now: now)
      assert {:kept, :live_draft} = StorageGC.collect(actor, candidate(unit, revision), now: now)
      assert Map.has_key?(staged(ctx, unit), revision)
      assert %StorageUnit{draft_writer_token: "wrt_" <> _} = row(actor, unit)
    end

    test "dead past its lifetime plus the grace is retired, then collected", %{
      ctx: ctx,
      actor: actor,
      unit: unit
    } do
      writer_dies_staging(ctx, unit, "one")

      assert {:ok, %{collected: 0}} = StorageGC.sweep(actor)
      assert map_size(staged(ctx, unit)) == 1

      assert {:ok, %{collected: 1, errors: []}} = StorageGC.sweep(actor, now: later(2 * @day))

      assert staged(ctx, unit) == %{}
      assert %StorageUnit{state: "retired", draft_writer_token: nil} = row(actor, unit)
      assert {:error, :not_found} = pointer(actor, unit)
    end

    test "retired by the collector can no longer commit the revision it staged", %{
      ctx: ctx,
      actor: actor,
      unit: unit
    } do
      {root, key} = UnitLocator.unit_key(unit)
      token = StorageUnits.new_writer_token()
      {:ok, draft} = StorageUnits.register_draft(actor, root, key, token)
      revision = lay_prefix(ctx, unit, StorageUnits.new_revision(), "slow")

      assert {:ok, %{collected: 1}} = StorageGC.sweep(actor, now: later(2 * @day))

      identity = %{
        new_revision: revision,
        content_identity: Cyfr.Digest.sha256("slow"),
        commit_identity: "usr_slow"
      }

      assert {:error, refused} = StorageUnits.commit(actor, draft, nil, token, identity)
      assert refused in [:stale_writer, :missing_unit]
      assert {:error, :not_found} = pointer(actor, unit)
    end
  end

  # ---------------------------------------------------------------------------
  # Between the snapshot and the delete
  # ---------------------------------------------------------------------------

  describe "a root that lands after the snapshot" do
    test "a commit: the prefix survives", %{ctx: ctx, actor: actor, unit: unit} do
      {root, key} = UnitLocator.unit_key(unit)
      token = StorageUnits.new_writer_token()
      {:ok, draft} = StorageUnits.register_draft(actor, root, key, token)
      revision = lay_prefix(ctx, unit, StorageUnits.new_revision(), "late")
      now = later(2 * @day)

      {:ok, roots} = StorageGC.roots(actor)

      assert {:ok, [%{revision: ^revision} = found]} =
               StorageGC.candidates(actor, roots, now: now)

      assert :committed =
               StorageUnits.commit(actor, draft, nil, token, %{
                 new_revision: revision,
                 content_identity: Cyfr.Digest.sha256("late"),
                 commit_identity: "usr_late"
               })

      assert {:kept, :committed} = StorageGC.collect(actor, found, now: now)
      assert Map.has_key?(staged(ctx, unit), revision)
      assert {:ok, %{current_revision: ^revision}} = pointer(actor, unit)
    end

    test "a reader's pin: the prefix survives until the holder is done", %{
      ctx: ctx,
      actor: actor,
      unit: unit
    } do
      commit_unserved(ctx, unit, "one")
      {:ok, %{current_revision: one}} = pointer(actor, unit)
      now = later(2 * @day)

      build = start_build(ctx)
      assert :ok = StorageGC.pin(actor, unit, one, {:build, build})
      assert {:ok, _} = commit(ctx, unit, "two")

      # A snapshot whose listing did not show the pin yet.
      {:ok, roots} = StorageGC.roots(actor)
      blind = %{roots | pins: MapSet.new()}
      assert {:ok, [%{revision: ^one} = found]} = StorageGC.candidates(actor, blind, now: now)
      assert {:kept, :pinned} = StorageGC.collect(actor, found, now: now)
      assert Map.has_key?(staged(ctx, unit), one)

      # A snapshot taken now roots it, and a sweep leaves it.
      assert {:ok, %{pins: pins}} = StorageGC.roots(actor)
      assert MapSet.size(pins) == 1
      assert {:ok, %{collected: 0}} = StorageGC.sweep(actor, now: now)

      :ok =
        Arca.BuildRecords.record_finished(Sanctum.Context.actor(ctx), build, "failed", "stopped")

      assert {:ok, %{collected: 1}} = StorageGC.sweep(actor, now: now)
      assert staged(ctx, unit) == %{}
      assert served(ctx, unit) == whole("two")
    end

    test "an open turn pins as a started build does, and a finished one does not", %{
      ctx: ctx,
      actor: actor,
      unit: unit
    } do
      commit_unserved(ctx, unit, "one")
      {:ok, %{current_revision: one}} = pointer(actor, unit)
      turn = open_turn(ctx)

      assert :ok = StorageGC.pin(actor, unit, one, {:turn, turn.id})
      assert {:ok, _} = commit(ctx, unit, "two")
      assert {:kept, :pinned} = StorageGC.collect(actor, candidate(unit, one), now: later(@day))

      {:ok, _} =
        Arca.TurnStorage.finish(Sanctum.Context.actor(ctx), turn.id, "cancelled", %{
          fence: turn.fence
        })

      assert :collected = StorageGC.collect(actor, candidate(unit, one), now: later(@day))
    end

    test "a pin on a revision the pointer has left is refused, and leaves nothing", %{
      ctx: ctx,
      actor: actor,
      unit: unit
    } do
      commit_unserved(ctx, unit, "one")
      {:ok, %{current_revision: one}} = pointer(actor, unit)
      assert {:ok, _} = commit(ctx, unit, "two")

      build = start_build(ctx)
      assert {:error, :stale_revision} = StorageGC.pin(actor, unit, one, {:build, build})
      assert {:error, :invalid_holder} = StorageGC.pin(actor, unit, one, {:build, "../x"})
      assert {:ok, %{pins: pins}} = StorageGC.roots(actor)
      assert MapSet.size(pins) == 0
      assert :collected = StorageGC.collect(actor, candidate(unit, one), now: later(@day))
    end
  end

  # ---------------------------------------------------------------------------
  # Orphans
  # ---------------------------------------------------------------------------

  describe "a complete prefix no row names" do
    test "is collected after the grace and never promoted", %{ctx: ctx, actor: actor, unit: unit} do
      assert {:ok, _} = commit(ctx, unit, "one")
      {:ok, %{current_revision: one}} = pointer(actor, unit)
      orphan = lay_prefix(ctx, unit, StorageUnits.new_revision(), "orphan")

      # Repair finds nothing of the row's to move, and leaves the orphan.
      assert {:ok, %{repaired: [], intact: 1, left: [], unrecoverable: []}} =
               StorageGC.repair(actor)

      assert {:ok, %{current_revision: ^one}} = pointer(actor, unit)
      assert served(ctx, unit) == whole("one")

      # Inside the grace it stays; after it, it goes. The pointer never moved.
      assert {:ok, %{collected: 0}} = StorageGC.sweep(actor)
      assert Map.has_key?(staged(ctx, unit), orphan)

      assert {:ok, %{collected: 1, repaired: 0}} = StorageGC.sweep(actor, now: later(2 * @day))
      assert staged(ctx, unit) == %{}
      assert {:ok, %{current_revision: ^one}} = pointer(actor, unit)
      assert served(ctx, unit) == whole("one")
    end

    test "with no unit row at all makes no row", %{ctx: ctx, actor: actor, unit: unit} do
      lay_prefix(ctx, unit, StorageUnits.new_revision(), "orphan", marker: false)

      assert {:ok, %{repaired: [], intact: 0, left: [], unrecoverable: []}} =
               StorageGC.repair(actor)

      assert row(actor, unit) == nil
      assert {:ok, %{collected: 1}} = StorageGC.sweep(actor, now: later(2 * @day))
      assert row(actor, unit) == nil
      assert Arca.Overlay.unit_status(Sanctum.Context.actor(ctx), unit) == {:ok, :absent}
    end

    test "that carries no date is given one, and collected a grace later", %{
      ctx: ctx,
      actor: actor,
      unit: unit
    } do
      lay_prefix(ctx, unit, "hand-laid", "orphan", marker: false)

      assert {:ok, %{collected: 0, unaged: 1}} = StorageGC.sweep(actor, now: later(2 * @day))
      assert ".in-progress" in staged(ctx, unit)["hand-laid"]

      assert {:ok, %{collected: 1, unaged: 0}} = StorageGC.sweep(actor, now: later(2 * @day))
      assert staged(ctx, unit) == %{}
    end

    test "a dry run counts and touches nothing", %{ctx: ctx, actor: actor, unit: unit} do
      orphan = lay_prefix(ctx, unit, StorageUnits.new_revision(), "orphan")

      assert {:ok, %{collected: 1}} = StorageGC.sweep(actor, now: later(2 * @day), dry_run: true)
      assert Map.has_key?(staged(ctx, unit), orphan)
    end

    test "one sweep collects at most its limit, oldest first", %{
      ctx: ctx,
      actor: actor,
      unit: unit
    } do
      first = lay_prefix(ctx, unit, StorageUnits.new_revision(), "first")
      Process.sleep(5)
      second = lay_prefix(ctx, unit, StorageUnits.new_revision(), "second")

      assert {:ok, %{collected: 1}} = StorageGC.sweep(actor, now: later(2 * @day), limit: 1)
      assert Map.keys(staged(ctx, unit)) == [second]
      refute first == second
    end
  end

  # ---------------------------------------------------------------------------
  # A crash
  # ---------------------------------------------------------------------------

  describe "a collector that dies" do
    test "between the objects and the marker leaves a dated prefix the next sweep takes", %{
      ctx: ctx,
      actor: actor,
      unit: unit
    } do
      orphan = lay_prefix(ctx, unit, StorageUnits.new_revision(), "orphan")
      now = later(2 * @day)

      Adapter.hook(fn op, _ctx, path ->
        if op == :delete and List.last(path) == UnitLocator.marker_name(),
          do: exit(:collector_died),
          else: :pass
      end)

      {pid, ref} = spawn_monitor(fn -> StorageGC.sweep(actor, now: now) end)
      assert_receive {:DOWN, ^ref, :process, ^pid, :collector_died}, 30_000
      Adapter.clear()

      assert staged(ctx, unit) == %{orphan => [".in-progress"]}

      assert {:ok, %{collected: 1}} = StorageGC.sweep(actor, now: now)
      assert staged(ctx, unit) == %{}
    end

    test "among the objects leaves the marker and the rest", %{
      ctx: ctx,
      actor: actor,
      unit: unit
    } do
      orphan = lay_prefix(ctx, unit, StorageUnits.new_revision(), "orphan")
      now = later(2 * @day)
      test_pid = self()

      Adapter.hook(fn op, _ctx, _path ->
        if op == :delete do
          send(test_pid, :deleting)
          if Process.get(:deleted_one), do: exit(:collector_died)
          Process.put(:deleted_one, true)
        end

        :pass
      end)

      {pid, ref} = spawn_monitor(fn -> StorageGC.sweep(actor, now: now) end)
      assert_receive {:DOWN, ^ref, :process, ^pid, :collector_died}, 30_000
      Adapter.clear()

      assert [".in-progress" | rest] = staged(ctx, unit)[orphan]
      assert length(rest) == 2

      assert {:ok, %{collected: 1}} = StorageGC.sweep(actor, now: now)
      assert staged(ctx, unit) == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Repair
  # ---------------------------------------------------------------------------

  describe "repair/2" do
    test "finishes the move of the revision the row names", %{ctx: ctx, actor: actor, unit: unit} do
      commit_unserved(ctx, unit, "one")
      {:ok, %{current_revision: one}} = pointer(actor, unit)
      assert Map.has_key?(staged(ctx, unit), one)

      assert {:ok, %{repaired: [^unit], left: [], unrecoverable: []}} = StorageGC.repair(actor)

      assert served(ctx, unit) == whole("one")
      assert staged(ctx, unit) == %{}
      assert {:ok, %{current_revision: ^one}} = pointer(actor, unit)
      assert {:ok, %{repaired: [], intact: 1}} = StorageGC.repair(actor)
    end

    test "reads the content identity the overlay recorded", %{
      ctx: ctx,
      actor: actor,
      unit: unit
    } do
      # A file unit and a directory unit: the one framing, both shapes.
      agent = ["aqua", "roles", "gc-#{System.unique_integer([:positive])}.md"]

      Adapter.hook(fn op, _ctx, path ->
        if op in [:put, :replace_tree] and (served?(path, unit) or served?(path, agent)),
          do: {:error, :enospc},
          else: :pass
      end)

      assert {:error, {:finish_failed, _}} = commit(ctx, unit, "one")

      assert {:error, {:finish_failed, _}} =
               Arca.Overlay.commit_unit(
                 Sanctum.Context.actor(ctx),
                 agent,
                 {:files, [{[], "# a role"}]},
                 cap: :exempt
               )

      Adapter.clear()

      assert {:ok, %{repaired: repaired, left: []}} = StorageGC.repair(actor)
      assert Enum.sort(repaired) == Enum.sort([unit, agent])
      assert {:ok, "# a role"} = Arca.get(Sanctum.Context.actor(ctx), agent)
    end

    test "never serves a staged revision that is not what was committed", %{
      ctx: ctx,
      actor: actor,
      unit: unit
    } do
      assert {:ok, _} = commit(ctx, unit, "one")
      commit_unserved(ctx, unit, "two")
      {:ok, %{current_revision: two}} = pointer(actor, unit)

      # What a removal that failed part-way leaves of a prefix.
      :ok =
        Arca.delete(Sanctum.Context.actor(ctx), UnitLocator.staged_object(unit, two, ["a.txt"]))

      assert {:ok, %{repaired: [], left: [{^unit, :staged_incomplete}]}} = StorageGC.repair(actor)
      assert served(ctx, unit) == whole("one")
      assert {:ok, %{current_revision: ^two}} = pointer(actor, unit)
    end

    test "invents no pointer and no objects for a row whose revision is gone", %{
      ctx: ctx,
      actor: actor,
      unit: unit
    } do
      assert {:ok, _} = commit(ctx, unit, "one")
      {:ok, %{current_revision: one}} = pointer(actor, unit)
      orphan = lay_prefix(ctx, unit, StorageUnits.new_revision(), "orphan")

      # The served objects go without the row: beneath the overlay.
      :ok = Arca.Adapters.Local.delete_tree(Sanctum.Context.actor(ctx), unit)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{repaired: [], unrecoverable: [^unit], orphan_commits: []}} =
                 StorageGC.repair(actor)
      end)

      assert {:ok, %{current_revision: ^one}} = pointer(actor, unit)
      assert served(ctx, unit) == %{}
      assert Map.keys(staged(ctx, unit)) == [orphan]
    end
  end

  describe "a sweep's own repair" do
    test "finishes a move that outlived the grace", %{ctx: ctx, actor: actor, unit: unit} do
      assert {:ok, _} = commit(ctx, unit, "one")
      commit_unserved(ctx, unit, "two")

      assert {:ok, %{repaired: 0, collected: 0}} = StorageGC.sweep(actor)
      assert served(ctx, unit) == whole("one")

      assert {:ok, %{repaired: 1, collected: 0, pending: []}} =
               StorageGC.sweep(actor, now: later(2 * @day))

      assert served(ctx, unit) == whole("two")
      assert staged(ctx, unit) == %{}
    end

    test "leaves a served location that was written to since", %{
      ctx: ctx,
      actor: actor,
      unit: unit
    } do
      assert {:ok, _} = commit(ctx, unit, "one")
      commit_unserved(ctx, unit, "two")
      :ok = Arca.put(Sanctum.Context.actor(ctx), unit ++ ["a.txt"], "an edit")

      assert {:ok, %{repaired: 0, pending: [{^unit, :served_diverged}]}} =
               StorageGC.sweep(actor, now: later(2 * @day))

      assert {:ok, "an edit"} = Arca.get(Sanctum.Context.actor(ctx), unit ++ ["a.txt"])

      # Asked for, the move is made.
      assert {:ok, %{repaired: [^unit]}} = StorageGC.repair(actor)
      assert served(ctx, unit) == whole("two")
    end
  end

  # ---------------------------------------------------------------------------
  # Tenancy
  # ---------------------------------------------------------------------------

  describe "tenancy" do
    test "an actor without an athanor is refused before any query or listing", %{unit: unit} do
      test_pid = self()

      Adapter.hook(fn op, _ctx, path ->
        send(test_pid, {:storage, op, path})
        :pass
      end)

      nobody = %Cyfr.Actor{athanor_id: nil, user_id: "usr_nobody"}

      # No connection to query with: a query would raise, not refuse.
      Ecto.Adapters.SQL.Sandbox.checkin(Arca.Repo)

      assert {:error, :no_athanor} = StorageGC.sweep(nobody)
      assert {:error, :no_athanor} = StorageGC.roots(nobody)
      assert {:error, :no_athanor} = StorageGC.repair(nobody)
      assert {:error, :no_athanor} = StorageGC.pin(nobody, unit, "rev_1", {:build, "build_1"})
      assert {:error, :no_athanor} = StorageGC.unpin(nobody, unit, "rev_1", {:build, "build_1"})
      assert {:error, :no_athanor} = StorageGC.collect(nobody, candidate(unit, "rev_1"))

      assert {:error, :no_athanor} =
               StorageGC.candidates(nobody, %{
                 current: MapSet.new(),
                 drafts: %{},
                 pins: MapSet.new()
               })

      assert {:error, :no_athanor} = StorageGC.sweep(%Cyfr.Actor{athanor_id: ""})
      refute_received {:storage, _op, _path}
    end

    test "one estate's sweep lists and collects inside that estate alone", %{
      ctx: ctx,
      actor: actor,
      unit: unit
    } do
      other_ctx = %{ctx | athanor_id: "ath_gc_other_#{System.unique_integer([:positive])}"}
      other = Sanctum.Context.actor(other_ctx)

      mine = lay_prefix(ctx, unit, StorageUnits.new_revision(), "mine")
      theirs = lay_prefix(other_ctx, unit, StorageUnits.new_revision(), "theirs")

      # The other estate's pointer names the revision this one staged.
      {root, key} = UnitLocator.unit_key(unit)
      token = StorageUnits.new_writer_token()
      {:ok, draft} = StorageUnits.register_draft(other, root, key, token)

      :committed =
        StorageUnits.commit(other, draft, nil, token, %{
          new_revision: mine,
          content_identity: Cyfr.Digest.sha256("theirs"),
          commit_identity: "usr_other"
        })

      test_pid = self()

      Adapter.hook(fn op, op_ctx, path ->
        send(test_pid, {:storage, op, op_ctx.athanor_id, path})
        :pass
      end)

      assert {:ok, %{collected: 1, examined: 1}} = StorageGC.sweep(actor, now: later(2 * @day))
      Adapter.clear()

      assert staged(ctx, unit) == %{}
      assert Map.keys(staged(other_ctx, unit)) == [theirs]

      touched = storage_messages()
      assert Enum.any?(touched, &match?({:list, _athanor}, &1))
      assert touched |> Enum.map(&elem(&1, 1)) |> Enum.uniq() == [actor.athanor_id]
    end
  end
end
