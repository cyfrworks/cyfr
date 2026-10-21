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

  # Exists is the storage contract's total boolean probe. Real S3 answers
  # false on a refused/timed-out HEAD too; GET/list/delete may still work.
  def exists?(actor, path) do
    case through(:exists, actor, path, fn -> Arca.Adapters.Local.exists?(actor, path) end) do
      {:error, _reason} -> false
      answer -> answer
    end
  end

  def last_modified(actor, path),
    do:
      through(:last_modified, actor, path, fn ->
        Arca.Adapters.Local.last_modified(actor, path)
      end)

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
  What the collector keeps and what it takes: the pointer and a live
  draft keep a staged revision, read again immediately before its
  deletion; everything else goes after the grace, marker last. Every age
  is judged on the cell's clock unless a case names the instant.
  Repair proves the revision a row names against the journal and gives
  back a dead writer's draft; it writes no object, and objects alone
  never make a pointer.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  # What the audit leaves and a refused delete or release is logged, as it
  # should be.
  @moduletag :capture_log

  alias Arca.Schemas.StorageUnit
  alias Arca.Storage.UnitLocator
  alias Arca.StorageGC
  alias Arca.StorageGCTest.Adapter
  alias Arca.StorageUnits

  @sentinel "cyfr-manifest.json"
  @day :timer.hours(24)

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    base = Path.join(System.tmp_dir!(), "storage_gc_#{System.unique_integer([:positive])}")
    prev_base = Application.fetch_env!(:arca, :base_path)
    prev_seed = Application.fetch_env!(:arca, :seed_path)
    prev_adapter = Application.get_env(:arca, :storage_adapter)

    File.mkdir_p!(Path.join(base, "seed/components"))
    Application.put_env(:arca, :base_path, Path.join(base, "data"))
    Application.put_env(:arca, :seed_path, Path.join(base, "seed"))
    Application.put_env(:arca, :storage_adapter, Adapter)

    on_exit(fn ->
      if prev_adapter,
        do: Application.put_env(:arca, :storage_adapter, prev_adapter),
        else: Application.delete_env(:arca, :storage_adapter)

      Adapter.clear()
      Application.put_env(:arca, :base_path, prev_base)
      Application.put_env(:arca, :seed_path, prev_seed)
      File.rm_rf!(base)
    end)

    actor = Arca.Test.Actor.local()
    name = "gc-#{System.unique_integer([:positive])}"

    {:ok, actor: actor, unit: ["components", "catalysts", "local", name, "1.0.0"]}
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

  defp commit(actor, unit, tag),
    do: Arca.Overlay.commit_unit(actor, unit, {:files, files(tag)}, cap: :exempt)

  # What a reader reads at the unit's own paths, which the facade resolves
  # to the committed revision's prefix.
  defp served(actor, unit) do
    {:ok, read} = Arca.read_subtree(actor, unit)
    Map.new(read)
  end

  # The names of what is staged for a unit, by revision.
  defp staged(actor, unit) do
    prefix = UnitLocator.staging_prefix(unit)
    {:ok, leaves} = Arca.list_recursive(actor, prefix)

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

  defp staged_object?(path), do: UnitLocator.staging?(path)

  # What one revision's prefix holds, its marker left out.
  defp revision_bytes(actor, unit, revision) do
    {:ok, pairs} = Arca.read_subtree(actor, UnitLocator.revision_prefix(unit, revision))
    pairs |> Enum.reject(fn {rel, _bytes} -> rel == [UnitLocator.marker_name()] end) |> Map.new()
  end

  # The revision's prefix as begun `ms` ago: its marker dated back.
  defp begun_ago!(actor, unit, revision, ms) do
    marker = Jason.encode!(%{"revision" => revision, "started_at" => iso(later(-ms))})
    :ok = Arca.Adapters.Local.put(actor, UnitLocator.marker_path(unit, revision), marker)
  end

  # A whole revision's objects under a prefix no row names — what a writer
  # that lost, or one that died, leaves behind. Laid in the internal-write
  # scope, the only one that writes under a staging area.
  defp lay_prefix(actor, unit, revision, tag, opts \\ []) do
    Arca.Overlay.with_internal_writes(fn ->
      if Keyword.get(opts, :marker, true) do
        marker =
          Jason.encode!(%{"revision" => revision, "started_at" => iso(DateTime.utc_now())})

        :ok = Arca.put(actor, UnitLocator.marker_path(unit, revision), marker)
      end

      for {rel, bytes} <- files(tag) do
        :ok = Arca.put(actor, UnitLocator.staged_object(unit, revision, rel), bytes)
      end
    end)

    revision
  end

  defp iso(at), do: DateTime.to_iso8601(at)
  defp later(ms), do: DateTime.add(DateTime.utc_now(), ms, :millisecond)

  # A commit whose writer died between the commit and its release: the row
  # and the journal stand, the revision is read already, the dead writer's
  # draft is held until it has outlived its lifetime (`expire!/2`).
  defp commit_unreleased(actor, unit, tag),
    do: dies_unreleased(actor, unit, fn -> commit(actor, unit, tag) end)

  # A writer of `unit` that dies at the commit's announcement — after the
  # pointer moved, before the draft is given back. Killed outright there:
  # an exit raised inside a telemetry handler is caught by telemetry.
  defp dies_unreleased(actor, unit, commit) do
    {root, key} = UnitLocator.unit_key(unit)
    handler = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(handler) end)
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        Arca.StorageProjectionChanges.event(),
        fn _event, _measurements, metadata, _config ->
          if metadata.athanor_id == actor.athanor_id and metadata.root == root and
               not metadata.ready and self() != test_pid and
               match?(
                 {:ok, %{draft_writer_token: token}} when is_binary(token),
                 StorageUnits.current(actor, root, key)
               ) do
            :telemetry.detach(handler)
            Process.exit(self(), :kill)
          end
        end,
        nil
      )

    {pid, ref} = spawn_monitor(commit)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 30_000
  end

  # The unit's draft, aged past its lifetime.
  defp expire!(actor, unit) do
    {root, key} = UnitLocator.unit_key(unit)
    long_ago = DateTime.add(DateTime.utc_now(), -2 * StorageUnits.draft_ttl_ms(), :millisecond)

    Arca.Repo.update_all(
      from(u in StorageUnit,
        where: u.athanor_id == ^actor.athanor_id and u.root == ^root and u.unit_key == ^key
      ),
      set: [updated_at: long_ago]
    )
  end

  # A writer that dies with its revision half staged: the draft held, the
  # marker and one object under the prefix.
  defp writer_dies_staging(actor, unit, tag) do
    Adapter.hook(fn op, _actor, path ->
      if op == :put and staged_object?(path) and List.last(path) == "b.txt",
        do: exit(:writer_died),
        else: :pass
    end)

    {pid, ref} = spawn_monitor(fn -> commit(actor, unit, tag) end)
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

  # ---------------------------------------------------------------------------
  # Drafts
  # ---------------------------------------------------------------------------

  describe "a draft" do
    test "that is live keeps its prefix, however old the prefix", %{actor: actor, unit: unit} do
      writer_dies_staging(actor, unit, "one")
      assert [{revision, [".in-progress" | _half]}] = Map.to_list(staged(actor, unit))

      # Older than the grace, and the draft still inside its lifetime plus it.
      now = later(@day + :timer.minutes(5))

      assert {:ok, %{collected: 0, examined: 1}} = StorageGC.sweep(actor, now: now)
      assert {:kept, :live_draft} = StorageGC.collect(actor, candidate(unit, revision), now: now)
      assert Map.has_key?(staged(actor, unit), revision)
      assert %StorageUnit{draft_writer_token: "wrt_" <> _} = row(actor, unit)
    end

    test "dead past its lifetime plus the grace is retired, then collected", %{
      actor: actor,
      unit: unit
    } do
      writer_dies_staging(actor, unit, "one")

      assert {:ok, %{collected: 0}} = StorageGC.sweep(actor)
      assert map_size(staged(actor, unit)) == 1

      assert {:ok, %{collected: 1, errors: []}} = StorageGC.sweep(actor, now: later(2 * @day))

      assert staged(actor, unit) == %{}
      assert %StorageUnit{state: "retired", draft_writer_token: nil} = row(actor, unit)
      assert {:error, :not_found} = pointer(actor, unit)
    end

    test "is judged on the cell's clock it was registered on, which only a clock twenty minutes ahead would read as dead",
         %{actor: actor, unit: unit} do
      writer_dies_staging(actor, unit, "one")
      assert [{revision, [".in-progress" | _half]}] = Map.to_list(staged(actor, unit))

      # Registered just now on the cell's clock, the draft is live to a
      # collector reading that clock, however short the grace.
      assert {:kept, :live_draft} =
               StorageGC.collect(actor, candidate(unit, revision), grace_ms: 0)

      assert %StorageUnit{draft_writer_token: "wrt_" <> _} = row(actor, unit)

      # Judged on a clock twenty minutes ahead of the cell's — a member's
      # own, drifted — the same draft is dead past its lifetime and taken
      # from its writer: the skew the cell's clock keeps out.
      skewed = DateTime.add(Arca.ServerMetaStorage.now!(), 20, :minute)

      assert :collected =
               StorageGC.collect(actor, candidate(unit, revision), now: skewed, grace_ms: 0)

      assert %StorageUnit{state: "retired", draft_writer_token: nil} = row(actor, unit)
    end

    test "retired by the collector can no longer commit the revision it staged", %{
      actor: actor,
      unit: unit
    } do
      {root, key} = UnitLocator.unit_key(unit)
      token = StorageUnits.new_writer_token()
      {:ok, draft} = StorageUnits.register_draft(actor, root, key, token)
      revision = lay_prefix(actor, unit, StorageUnits.new_revision(), "slow")

      assert {:ok, %{collected: 1}} = StorageGC.sweep(actor, now: later(2 * @day))

      identity = %{
        new_revision: revision,
        content_identity: Prima.Digest.sha256("slow"),
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
    test "a commit: the prefix survives", %{actor: actor, unit: unit} do
      {root, key} = UnitLocator.unit_key(unit)
      token = StorageUnits.new_writer_token()
      {:ok, draft} = StorageUnits.register_draft(actor, root, key, token)
      revision = lay_prefix(actor, unit, StorageUnits.new_revision(), "late")
      now = later(2 * @day)

      {:ok, roots} = StorageGC.roots(actor)

      assert {:ok, [%{revision: ^revision} = found]} =
               StorageGC.candidates(actor, roots, now: now)

      assert :committed =
               StorageUnits.commit(actor, draft, nil, token, %{
                 new_revision: revision,
                 content_identity: Prima.Digest.sha256("late"),
                 commit_identity: "usr_late"
               })

      assert {:kept, :committed} = StorageGC.collect(actor, found, now: now)
      assert Map.has_key?(staged(actor, unit), revision)
      assert {:ok, %{current_revision: ^revision}} = pointer(actor, unit)
    end

    test "a candidate committed and replaced after its snapshot keeps the replacement grace", %{
      actor: actor,
      unit: unit
    } do
      {root, key} = UnitLocator.unit_key(unit)
      token = StorageUnits.new_writer_token()
      {:ok, draft} = StorageUnits.register_draft(actor, root, key, token)
      one = lay_prefix(actor, unit, StorageUnits.new_revision(), "one")
      begun_ago!(actor, unit, one, 3 * @day)

      # The writer was paused long enough that its staged prefix qualified
      # before it resumed. Advancing a fixture's dates avoids a two-day sleep.
      Arca.Repo.update_all(
        from(u in StorageUnit,
          where: u.athanor_id == ^actor.athanor_id and u.id == ^draft.id
        ),
        set: [updated_at: later(-3 * @day)]
      )

      {:ok, roots} = StorageGC.roots(actor)
      assert {:ok, [%{revision: ^one} = candidate]} = StorageGC.candidates(actor, roots)

      # Both commits happen after the snapshot and before its final check.
      # A reader could resolve `one` between these commits.
      assert :committed =
               StorageUnits.commit(actor, draft, nil, token, %{
                 new_revision: one,
                 content_identity: Prima.Digest.sha256("one"),
                 commit_identity: actor.user_id
               })

      assert :ok = StorageUnits.release_served(actor, draft, token, one)
      assert {:ok, _} = commit(actor, unit, "two")
      assert served(actor, unit) == whole("two")

      StorageGC.collect(actor, candidate)
      assert revision_bytes(actor, unit, one) == whole("one")
    end
  end

  # ---------------------------------------------------------------------------
  # Orphans
  # ---------------------------------------------------------------------------

  describe "a complete prefix no row names" do
    test "is collected after the grace and never promoted", %{actor: actor, unit: unit} do
      assert {:ok, _} = commit(actor, unit, "one")
      {:ok, %{current_revision: one}} = pointer(actor, unit)
      orphan = lay_prefix(actor, unit, StorageUnits.new_revision(), "orphan")

      # Repair finds nothing of the row's to give back, and leaves the orphan.
      assert {:ok, :nothing_pending} = Arca.Overlay.repair_unit(actor, unit)

      assert {:ok, %{current_revision: ^one}} = pointer(actor, unit)
      assert served(actor, unit) == whole("one")

      # Inside the grace it stays; after it, it goes. The pointer never
      # moved, and its own prefix is never a candidate.
      assert {:ok, %{collected: 0}} = StorageGC.sweep(actor)
      assert Map.has_key?(staged(actor, unit), orphan)

      assert {:ok, %{collected: 1}} = StorageGC.sweep(actor, now: later(2 * @day))
      assert Map.keys(staged(actor, unit)) == [one]
      assert {:ok, %{current_revision: ^one}} = pointer(actor, unit)
      assert served(actor, unit) == whole("one")
    end

    test "with no unit row at all makes no row", %{actor: actor, unit: unit} do
      lay_prefix(actor, unit, StorageUnits.new_revision(), "orphan", marker: false)

      assert {:error, :not_found} = Arca.Overlay.repair_unit(actor, unit)
      assert row(actor, unit) == nil
      assert {:ok, %{collected: 1}} = StorageGC.sweep(actor, now: later(2 * @day))
      assert row(actor, unit) == nil
      assert Arca.Overlay.unit_status(actor, unit) == {:ok, :absent}
    end

    test "that carries no date is dated on the sweep's clock, and collected a grace after it", %{
      actor: actor,
      unit: unit
    } do
      lay_prefix(actor, unit, "hand-laid", "orphan", marker: false)

      # The sweep's clock two days from the host's: the date it writes is
      # that clock's, never the host's.
      dated = later(2 * @day)
      assert {:ok, %{collected: 0, unaged: 1}} = StorageGC.sweep(actor, now: dated)
      assert ".in-progress" in staged(actor, unit)["hand-laid"]

      inside = DateTime.add(dated, @day - :timer.minutes(1), :millisecond)
      assert {:ok, %{collected: 0, unaged: 0}} = StorageGC.sweep(actor, now: inside)
      assert Map.has_key?(staged(actor, unit), "hand-laid")

      past = DateTime.add(dated, @day + :timer.minutes(1), :millisecond)
      assert {:ok, %{collected: 1, unaged: 0}} = StorageGC.sweep(actor, now: past)
      assert staged(actor, unit) == %{}
    end

    test "a dry run counts and touches nothing", %{actor: actor, unit: unit} do
      orphan = lay_prefix(actor, unit, StorageUnits.new_revision(), "orphan")

      assert {:ok, %{collected: 1}} = StorageGC.sweep(actor, now: later(2 * @day), dry_run: true)
      assert Map.has_key?(staged(actor, unit), orphan)
    end

    test "one sweep collects at most its limit, oldest first", %{actor: actor, unit: unit} do
      first = lay_prefix(actor, unit, StorageUnits.new_revision(), "first")
      Process.sleep(5)
      second = lay_prefix(actor, unit, StorageUnits.new_revision(), "second")

      assert {:ok, %{collected: 1}} = StorageGC.sweep(actor, now: later(2 * @day), limit: 1)
      assert Map.keys(staged(actor, unit)) == [second]
      refute first == second
    end
  end

  # ---------------------------------------------------------------------------
  # A crash
  # ---------------------------------------------------------------------------

  describe "a collector that dies" do
    test "between the objects and the marker leaves a dated prefix the next sweep takes", %{
      actor: actor,
      unit: unit
    } do
      orphan = lay_prefix(actor, unit, StorageUnits.new_revision(), "orphan")
      now = later(2 * @day)

      Adapter.hook(fn op, _actor, path ->
        if op == :delete and List.last(path) == UnitLocator.marker_name(),
          do: exit(:collector_died),
          else: :pass
      end)

      {pid, ref} = spawn_monitor(fn -> StorageGC.sweep(actor, now: now) end)
      assert_receive {:DOWN, ^ref, :process, ^pid, :collector_died}, 30_000
      Adapter.clear()

      assert staged(actor, unit) == %{orphan => [".in-progress"]}

      assert {:ok, %{collected: 1}} = StorageGC.sweep(actor, now: now)
      assert staged(actor, unit) == %{}
    end

    test "among the objects leaves the marker and the rest", %{actor: actor, unit: unit} do
      orphan = lay_prefix(actor, unit, StorageUnits.new_revision(), "orphan")
      now = later(2 * @day)
      test_pid = self()

      Adapter.hook(fn op, _actor, _path ->
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

      assert [".in-progress" | rest] = staged(actor, unit)[orphan]
      assert length(rest) == 2

      assert {:ok, %{collected: 1}} = StorageGC.sweep(actor, now: now)
      assert staged(actor, unit) == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Repair
  # ---------------------------------------------------------------------------

  describe "Arca.Overlay.repair_unit/2 beside the collector" do
    test "releases the draft of a writer that died after its commit, once it has outlived its lifetime",
         %{actor: actor, unit: unit} do
      commit_unreleased(actor, unit, "one")
      {:ok, %{current_revision: one}} = pointer(actor, unit)

      # Published already: the pointer, the prefix, the read; the draft held.
      assert served(actor, unit) == whole("one")
      assert Map.keys(staged(actor, unit)) == [one]
      assert %StorageUnit{draft_writer_token: "wrt_" <> _} = row(actor, unit)

      # Inside the lifetime the draft is its holder's.
      assert {:error, :stale_writer} = Arca.Overlay.repair_unit(actor, unit)

      expire!(actor, unit)
      assert {:ok, :repaired} = Arca.Overlay.repair_unit(actor, unit)

      # Nothing moved: the revision is where it was, the pointer too.
      assert served(actor, unit) == whole("one")
      assert Map.keys(staged(actor, unit)) == [one]
      assert {:ok, %{current_revision: ^one, draft_writer_token: nil}} = pointer(actor, unit)
      assert {:ok, :nothing_pending} = Arca.Overlay.repair_unit(actor, unit)
    end

    test "gives back a dead writer's draft for both unit shapes", %{
      actor: actor,
      unit: unit
    } do
      # A file unit and a directory unit: the one framing, both shapes.
      agent = ["aqua", "roles", "gc-#{System.unique_integer([:positive])}.md"]
      commit_unreleased(actor, unit, "one")

      dies_unreleased(actor, agent, fn ->
        Arca.Overlay.commit_unit(actor, agent, {:files, [{[], "# a role"}]}, cap: :exempt)
      end)

      expire!(actor, unit)
      expire!(actor, agent)

      for repaired <- [unit, agent],
          do: assert({:ok, :repaired} = Arca.Overlay.repair_unit(actor, repaired))

      assert {:ok, "# a role"} = Arca.get(actor, agent)
      assert served(actor, unit) == whole("one")

      for intact <- [unit, agent],
          do: assert({:ok, :nothing_pending} = Arca.Overlay.repair_unit(actor, intact))
    end

    test "reports a committed revision whose completion object is gone, and keeps the row", %{
      actor: actor,
      unit: unit
    } do
      assert {:ok, _} = commit(actor, unit, "one")
      assert {:ok, _} = commit(actor, unit, "two")
      {:ok, %{current_revision: two}} = pointer(actor, unit)

      # Damage beneath the overlay: the sentinel of the pointer's prefix goes.
      :ok = Arca.Adapters.Local.delete(actor, UnitLocator.staged_object(unit, two, [@sentinel]))

      assert {:error, :staged_incomplete} = Arca.Overlay.repair_unit(actor, unit)

      # Nothing is moved or invented: the pointer stands, the unit reads
      # what its prefix holds, and the previous revision is never served
      # over it — it is the collector's.
      assert {:ok, %{current_revision: ^two}} = pointer(actor, unit)
      assert served(actor, unit) == Map.delete(whole("two"), [@sentinel])
      assert {:ok, %{collected: 1}} = StorageGC.sweep(actor, now: later(2 * @day))
      assert Map.keys(staged(actor, unit)) == [two]
    end

    test "gives back nothing for a revision edited in place since its commit, and leaves the edit",
         %{
           actor: actor,
           unit: unit
         } do
      assert {:ok, _} = commit(actor, unit, "one")
      {:ok, %{current_revision: one}} = pointer(actor, unit)
      :ok = Arca.put(actor, unit ++ ["a.txt"], "an edit")
      :ok = Arca.put(actor, unit ++ ["new.txt"], "new")

      # The edit lands in the pointer's prefix and reads at the unit's
      # paths; nothing stands at the unit's own path.
      assert {:ok, "an edit"} = Arca.get(actor, unit ++ ["a.txt"])
      assert {:ok, "an edit"} = Arca.get(actor, UnitLocator.staged_object(unit, one, ["a.txt"]))
      assert {:ok, []} = Arca.Adapters.Local.list_recursive(actor, unit)

      # Nothing of a writer's is pending, so nothing changes.
      assert {:ok, :nothing_pending} = Arca.Overlay.repair_unit(actor, unit)
      assert {:ok, "an edit"} = Arca.get(actor, unit ++ ["a.txt"])
      assert {:ok, "new"} = Arca.get(actor, unit ++ ["new.txt"])
    end

    test "invents no pointer and no objects for a row whose revision is gone", %{
      actor: actor,
      unit: unit
    } do
      assert {:ok, _} = commit(actor, unit, "one")
      {:ok, %{current_revision: one}} = pointer(actor, unit)
      orphan = lay_prefix(actor, unit, StorageUnits.new_revision(), "orphan")

      # The pointer's prefix goes without the row: beneath the overlay.
      :ok = Arca.Adapters.Local.delete_tree(actor, UnitLocator.revision_prefix(unit, one))

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :staged_incomplete} = Arca.Overlay.repair_unit(actor, unit)
      end)

      assert {:ok, %{current_revision: ^one}} = pointer(actor, unit)
      assert served(actor, unit) == %{}
      assert Map.keys(staged(actor, unit)) == [orphan]
    end

    test "a completion probe that cannot answer is the repair's answer, never a revision found incomplete",
         %{actor: actor, unit: unit} do
      assert {:ok, _} = commit(actor, unit, "one")
      {:ok, %{current_revision: one}} = pointer(actor, unit)
      probe = UnitLocator.revision_prefix(unit, one) ++ [@sentinel]
      parent = self()

      Adapter.hook(fn op, _actor, path ->
        if op == :last_modified and path == probe do
          send(parent, :probe_failed)
          {:error, :probe_unavailable}
        else
          :pass
        end
      end)

      assert {:error, :probe_unavailable} = Arca.Overlay.repair_unit(actor, unit)
      assert_receive :probe_failed
      Adapter.clear()

      assert {:ok, :nothing_pending} = Arca.Overlay.repair_unit(actor, unit)
      assert {:ok, %{current_revision: ^one, draft_writer_token: nil}} = pointer(actor, unit)
    end
  end

  describe "the root's projection" do
    defp change(actor, unit) do
      {root, key} = UnitLocator.unit_key(unit)
      {:ok, token} = Arca.StorageProjectionChanges.snapshot(actor, root, units: [key])
      Enum.find(token.units, &(&1.unit_key == key))
    end

    test "a repair with the revision unchanged raises the unit's generation, then marks it ready",
         %{actor: actor, unit: unit} do
      commit_unreleased(actor, unit, "one")
      {:ok, %{current_revision: one}} = pointer(actor, unit)
      committed = change(actor, unit)
      assert %{ready: false, source_revision: ^one, pending: true} = committed

      expire!(actor, unit)
      assert {:ok, :repaired} = Arca.Overlay.repair_unit(actor, unit)

      repaired = change(actor, unit)
      assert %{ready: true, source_revision: ^one, tombstone: false} = repaired
      assert repaired.generation > committed.generation

      {root, _key} = UnitLocator.unit_key(unit)
      assert {:ok, %{epoch: epoch}} = Arca.StorageProjectionRoots.epoch(actor, root)
      assert epoch == repaired.generation
    end

    test "collection changes no projection", %{actor: actor, unit: unit} do
      assert {:ok, _} = commit(actor, unit, "one")
      {root, _key} = UnitLocator.unit_key(unit)
      {:ok, before} = Arca.StorageProjectionRoots.epoch(actor, root)

      lay_prefix(actor, unit, StorageUnits.new_revision(), "dead", marker: false)
      assert {:ok, %{collected: 1}} = StorageGC.sweep(actor, now: later(2 * @day))

      assert {:ok, ^before} = Arca.StorageProjectionRoots.epoch(actor, root)
    end
  end

  describe "the previous revision" do
    test "is collected a grace after the commit that left it, and the current never", %{
      actor: actor,
      unit: unit
    } do
      assert {:ok, _} = commit(actor, unit, "one")
      {:ok, %{current_revision: one}} = pointer(actor, unit)
      # Begun long before the grace, as most revisions a commit replaces were.
      begun_ago!(actor, unit, one, 3 * @day)

      assert {:ok, _} = commit(actor, unit, "two")
      {:ok, %{current_revision: two}} = pointer(actor, unit)

      # Inside the grace since the commit that left it, the revision stands
      # whole for a reader that resolved the row before that commit.
      assert {:ok, %{collected: 0}} = StorageGC.sweep(actor)
      assert Enum.sort(Map.keys(staged(actor, unit))) == Enum.sort([one, two])
      assert revision_bytes(actor, unit, one) == whole("one")

      # Past the grace since that commit it goes, and the pointer's prefix
      # never does, however old.
      assert {:ok, %{collected: 1}} = StorageGC.sweep(actor, now: later(2 * @day))
      assert Map.keys(staged(actor, unit)) == [two]
      assert served(actor, unit) == whole("two")

      begun_ago!(actor, unit, two, 30 * @day)
      assert {:ok, %{collected: 0, examined: 1}} = StorageGC.sweep(actor, now: later(30 * @day))
      assert Map.keys(staged(actor, unit)) == [two]
      assert served(actor, unit) == whole("two")
    end

    test "a sweep releases a dead draft without marking its committed generation ready",
         %{actor: actor, unit: unit} do
      assert {:ok, _} = commit(actor, unit, "one")
      {:ok, %{current_revision: one}} = pointer(actor, unit)
      commit_unreleased(actor, unit, "two")
      {:ok, %{current_revision: two}} = pointer(actor, unit)

      # The pointer's prefix is read already; the one before it is the
      # collector's once the grace has passed, the held draft notwithstanding.
      assert served(actor, unit) == whole("two")
      assert {:ok, %{collected: 0}} = StorageGC.sweep(actor)
      assert Enum.sort(Map.keys(staged(actor, unit))) == Enum.sort([one, two])

      expire!(actor, unit)
      assert {:ok, report} = StorageGC.sweep(actor, now: later(2 * @day))
      assert %{collected: 1} = report
      refute Map.has_key?(report, :repaired)
      assert Map.keys(staged(actor, unit)) == [two]
      assert served(actor, unit) == whole("two")

      # The sweep gave the dead draft back and marked nothing: nothing is
      # pending for repair, and its commit's generation stays pending
      # until the settle marks it where it stands.
      assert %StorageUnit{draft_writer_token: nil} = row(actor, unit)
      assert {:ok, :nothing_pending} = Arca.Overlay.repair_unit(actor, unit)
      assert %{ready: false, source_revision: ^two} = change(actor, unit)
      {root, _key} = UnitLocator.unit_key(unit)

      assert {:ok, 1} =
               Arca.StorageProjectionChanges.settle_stale(actor, root, settle_after_ms: 0)

      assert %{ready: true, source_revision: ^two} = change(actor, unit)
    end
  end

  # ---------------------------------------------------------------------------
  # Tenancy
  # ---------------------------------------------------------------------------

  describe "tenancy" do
    test "an actor without an athanor is refused before any query or listing", %{unit: unit} do
      test_pid = self()

      Adapter.hook(fn op, _actor, path ->
        send(test_pid, {:storage, op, path})
        :pass
      end)

      nobody = %Prima.Actor{athanor_id: nil, user_id: "usr_nobody"}

      # No connection to query with: a query would raise, not refuse.
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, :manual)

      assert {:error, :no_athanor} = StorageGC.sweep(nobody)
      assert {:error, :no_athanor} = StorageGC.roots(nobody)
      assert {:error, :no_athanor} = StorageGC.collect(nobody, candidate(unit, "rev_1"))

      assert {:error, :no_athanor} =
               StorageGC.candidates(nobody, %{current: MapSet.new(), drafts: %{}})

      assert {:error, :no_athanor} = StorageGC.sweep(%Prima.Actor{athanor_id: ""})
      refute_received {:storage, _op, _path}
    end

    test "one athanor's sweep lists and collects inside that athanor alone", %{
      actor: actor,
      unit: unit
    } do
      other = %{actor | athanor_id: "ath_gc_other_#{System.unique_integer([:positive])}"}

      mine = lay_prefix(actor, unit, StorageUnits.new_revision(), "mine")
      theirs = lay_prefix(other, unit, StorageUnits.new_revision(), "theirs")

      # The other athanor's pointer names the revision this one staged.
      {root, key} = UnitLocator.unit_key(unit)
      token = StorageUnits.new_writer_token()
      {:ok, draft} = StorageUnits.register_draft(other, root, key, token)

      :committed =
        StorageUnits.commit(other, draft, nil, token, %{
          new_revision: mine,
          content_identity: Prima.Digest.sha256("theirs"),
          commit_identity: "usr_other"
        })

      test_pid = self()

      Adapter.hook(fn op, op_actor, path ->
        send(test_pid, {:storage, op, op_actor.athanor_id, path})
        :pass
      end)

      assert {:ok, %{collected: 1, examined: 1}} = StorageGC.sweep(actor, now: later(2 * @day))
      Adapter.clear()

      assert staged(actor, unit) == %{}
      assert Map.keys(staged(other, unit)) == [theirs]

      touched = storage_messages()
      assert Enum.any?(touched, &match?({:list, _athanor}, &1))
      assert touched |> Enum.map(&elem(&1, 1)) |> Enum.uniq() == [actor.athanor_id]
    end
  end
end
