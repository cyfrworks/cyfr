# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ObjectRevisionsTest.UnknownStore do
  @moduledoc false
  # The Local adapter, with every generation store landing and then
  # answering that it cannot say whether it did: a store whose connection
  # failed after the request reached the backend.
  use Arca.Storage.TestDouble

  def put(actor, ["objects" | _] = key, content) do
    :ok = super(actor, key, content)
    {:error, :unknown}
  end

  def put(actor, path, content), do: super(actor, path, content)
end

defmodule Arca.ObjectRevisionsTest.UndeletableStore do
  @moduledoc false
  # The Local adapter, refusing to delete any generation object, so a
  # retention pass that cannot remove an object is observable.
  use Arca.Storage.TestDouble

  def delete(_actor, ["objects" | _]), do: {:error, :eacces}
  def delete(actor, path), do: super(actor, path)
end

defmodule Arca.ObjectRevisionsTest do
  @moduledoc """
  Guest objects under `data/` on the Local adapter, written by
  generation: a write marks a generation, stores its bytes at
  `objects/<generation>/<path>` and settles the path's row onto it, and
  every read, listing, download, count and copy through the `Arca` facade
  answers only a settled generation's bytes and the sources it settled
  with. A store delayed past a newer settlement or a delete lands at its
  own key and is never read; a delete fences every generation marked
  before it; an append and a copy carry the settled sources forward; the
  conditional writes answer on the settled generation; `objects/` is
  refused to every facade caller; and retention collects every retired
  generation while it keeps the pointer and a write still in flight.

  Each step of a writer is driven by hand through `mark!/4`, `store/3`
  and `settle!/3`, so every interleaving here is a fixed order, never a
  race. `object_revisions_s3_test.exs` runs the same cases against an
  S3-compatible store.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ObjectRevisions
  alias Arca.Schemas.{ObjectGeneration, ObjectRevision}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    base = Path.join(System.tmp_dir!(), "object_revisions_#{System.unique_integer([:positive])}")
    prev_base = Application.fetch_env!(:arca, :base_path)
    actor = Arca.Test.Actor.local()

    on_exit(fn ->
      Arca.Usage.invalidate(actor)
      Application.put_env(:arca, :base_path, prev_base)
      File.rm_rf!(base)
    end)

    Application.put_env(:arca, :base_path, base)
    Arca.Cache.init()
    Arca.Usage.invalidate(actor)

    {:ok, actor: actor}
  end

  # ---------------------------------------------------------------------------
  # Helpers: one writer's steps, and the state a reader sees
  # ---------------------------------------------------------------------------

  defp mark(actor, path, op, bytes, sources) do
    {:ok, {:ok, mark}} =
      Arca.Repo.transaction(fn ->
        ObjectRevisions.mark!(actor, path, op, %{bytes: bytes, sources: sources})
      end)

    mark
  end

  defp settle(actor, mark) do
    {:ok, outcome} =
      Arca.Repo.transaction(fn -> ObjectRevisions.settle!(actor, mark, []) end)

    outcome
  end

  defp row(actor, path),
    do: Arca.Repo.get_by(ObjectRevision, athanor_id: actor.athanor_id, path: Enum.join(path, "/"))

  defp generations(actor, path) do
    key = Enum.join(path, "/")

    Arca.Repo.all(
      from(g in ObjectGeneration,
        where: g.athanor_id == ^actor.athanor_id and g.path == ^key,
        order_by: [asc: g.generation],
        select: g.generation
      )
    )
  end

  defp stored(actor, generation, path),
    do: Arca.Storage.configured_adapter().get(actor, ["objects", "#{generation}" | path])

  defp cold_usage(actor, path) do
    Arca.Usage.invalidate(actor)
    Arca.usage(actor, path)
  end

  defp filed, do: Prima.Source.new(:filed)
  defp disclosed, do: Prima.Source.new(:vault_disclosed)

  # ---------------------------------------------------------------------------
  # Interleavings of mark, store and settle
  # ---------------------------------------------------------------------------

  test "a store delayed past a newer settlement lands at its own key and is never read",
       %{actor: actor} do
    path = ["data", "a.txt"]

    a = mark(actor, path, :put, 3, [filed()])
    b = mark(actor, path, :put, 3, [Prima.Source.outside("b.example")])
    assert b.generation > a.generation

    :ok = ObjectRevisions.store(actor, b, "bbb")
    assert settle(actor, b) == :settled

    # A's store arrives late; its settlement is superseded and writes nothing.
    :ok = ObjectRevisions.store(actor, a, "aaa")
    assert settle(actor, a) == :superseded

    assert {:ok, "bbb"} = Arca.get(actor, path)

    assert {:ok, "bbb", [%Prima.Source{class: :outside, name: "b.example"}]} =
             ObjectRevisions.read(actor, path)

    # A's bytes sit at A's own key, which the facade refuses.
    assert {:ok, "aaa"} = stored(actor, a.generation, path)
    assert {:error, :forbidden} = Arca.get(actor, ["objects", "#{a.generation}" | path])
  end

  test "a generation marked but not stored, then stored but not settled, reads the settled one",
       %{actor: actor} do
    path = ["data", "c2", "doc.txt"]
    :ok = Arca.put(actor, path, "v1")
    listing = Arca.list_typed(actor, ["data", "c2"])
    assert {:ok, %{files: 1, bytes: 2}} = cold_usage(actor, ["data", "c2"])

    # Metadata before bytes: the mark is committed, nothing is stored.
    v2 = mark(actor, path, :put, 11, [])
    assert {:ok, "v1"} = Arca.get(actor, path)
    assert {:ok, "v1", _} = ObjectRevisions.read(actor, path)

    # Bytes before metadata: stored at the generation's key, not settled.
    :ok = ObjectRevisions.store(actor, v2, "version two")
    assert {:ok, "v1"} = Arca.get(actor, path)
    assert {:ok, "v1", _} = ObjectRevisions.read(actor, path)
    assert Arca.list_typed(actor, ["data", "c2"]) == listing
    assert {:ok, %{files: 1, bytes: 2}} = cold_usage(actor, ["data", "c2"])

    assert settle(actor, v2) == :settled
    assert {:ok, "version two"} = Arca.get(actor, path)
    assert {:ok, %{files: 1, bytes: 11}} = cold_usage(actor, ["data", "c2"])
  end

  test "a store delayed past a delete leaves the path deleted", %{actor: actor} do
    path = ["data", "c3", "a.txt"]
    :ok = Arca.put(actor, path, "v1")
    :ok = Arca.put(actor, ["data", "c3", "keep.txt"], "k")

    a = mark(actor, path, :put, 4, [])
    :ok = Arca.delete(actor, path)
    :ok = ObjectRevisions.store(actor, a, "late")
    assert settle(actor, a) == :dead

    assert {:error, :not_found} = Arca.get(actor, path)
    assert {:error, :not_found} = ObjectRevisions.read(actor, path)
    refute Arca.exists?(actor, path)
    assert {:ok, [{"keep.txt", :file}]} = Arca.list_typed(actor, ["data", "c3"])
    assert {:ok, %{files: 0, bytes: 0}} = cold_usage(actor, path)
  end

  test "a writer that dies after its mark or after its store changes nothing a reader sees, " <>
         "and the next write settles above it",
       %{actor: actor} do
    path = ["data", "c4", "doc.txt"]
    fresh = ["data", "c4", "never.txt"]
    :ok = Arca.put(actor, path, "v1")
    listing = Arca.list_recursive(actor, ["data", "c4"])
    usage = cold_usage(actor, ["data", "c4"])

    # One writer marked and died; another marked, stored and died.
    marked_only = mark(actor, path, :put, 5, [])
    stored_only = mark(actor, path, :put, 6, [])
    :ok = ObjectRevisions.store(actor, stored_only, "orphan")
    fresh_mark = mark(actor, fresh, :put, 6, [])
    :ok = ObjectRevisions.store(actor, fresh_mark, "orphan")

    assert {:ok, "v1"} = Arca.get(actor, path)
    assert {:error, :not_found} = Arca.get(actor, fresh)
    refute Arca.exists?(actor, fresh)
    assert Arca.list_recursive(actor, ["data", "c4"]) == listing
    assert cold_usage(actor, ["data", "c4"]) == usage

    :ok = Arca.put(actor, path, "v2")
    assert {:ok, "v2"} = Arca.get(actor, path)
    settled = row(actor, path).settled_generation
    assert settled > marked_only.generation and settled > stored_only.generation
  end

  test "of two writers the older settlement writes nothing", %{actor: actor} do
    path = ["data", "c5.txt"]
    a = mark(actor, path, :put, 1, [filed()])
    b = mark(actor, path, :put, 1, [Prima.Source.outside("b.example")])
    :ok = ObjectRevisions.store(actor, a, "a")
    :ok = ObjectRevisions.store(actor, b, "b")

    assert settle(actor, b) == :settled
    after_newer = row(actor, path)
    assert after_newer.settled_generation == b.generation

    assert settle(actor, a) == :superseded
    assert row(actor, path) == after_newer

    assert {:ok, "b", [%Prima.Source{class: :outside, name: "b.example"}]} =
             ObjectRevisions.read(actor, path)
  end

  test "a write paused across a delete is dead, and a recreate settles above the fence",
       %{actor: actor} do
    path = ["data", "c6.txt"]
    :ok = Arca.put(actor, path, "first")
    g1 = row(actor, path).settled_generation

    a = mark(actor, path, :put, 6, [])
    assert a.generation > g1
    :ok = Arca.delete(actor, path)
    tombstone = row(actor, path)
    assert %ObjectRevision{deleted: true, settled_generation: nil} = tombstone
    assert tombstone.deleted_at_generation > a.generation

    :ok = ObjectRevisions.store(actor, a, "paused")
    assert settle(actor, a) == :dead
    assert {:error, :not_found} = Arca.get(actor, path)
    assert {:error, :not_found} = ObjectRevisions.read(actor, path)

    :ok = Arca.put(actor, path, "again")
    recreated = row(actor, path)
    assert recreated.deleted == false
    assert recreated.settled_generation > tombstone.deleted_at_generation
    assert {:ok, "again"} = Arca.get(actor, path)
  end

  # ---------------------------------------------------------------------------
  # Sources
  # ---------------------------------------------------------------------------

  test "a clean append over an uncertain restricted overwrite derives from the settled bytes",
       %{actor: actor} do
    path = ["data", "c7.txt"]
    :ok = Arca.put(actor, path, "clean", sources: [filed()])

    # A restricted overwrite whose store landed and that never settled.
    pending = mark(actor, path, :put, 10, [disclosed()])
    :ok = ObjectRevisions.store(actor, pending, "restricted")

    :ok = Arca.append(actor, path, "suffix", sources: [])

    assert {:ok, "cleansuffix", sources} = ObjectRevisions.read(actor, path)
    assert sources == [filed()]
    refute disclosed() in sources
    assert {:ok, "cleansuffix"} = Arca.get(actor, path)

    # The pending generation's bytes are not reachable through the facade.
    assert {:error, :forbidden} = Arca.get(actor, ["objects", "#{pending.generation}" | path])
    assert {:ok, "restricted"} = stored(actor, pending.generation, path)
  end

  test "a restricted settled prefix keeps its sources through a clean append and a clean copy",
       %{actor: actor} do
    path = ["data", "p", "s.txt"]
    :ok = Arca.put(actor, path, "secret", sources: [disclosed()])
    :ok = Arca.append(actor, path, "x", sources: [])

    assert {:ok, "secretx", sources} = ObjectRevisions.read(actor, path)
    assert disclosed() in sources

    assert {:ok, [["s.txt"]]} = Arca.copy_tree(actor, ["data", "p"], ["data", "q"], sources: [])
    assert {:ok, "secretx", copied} = ObjectRevisions.read(actor, ["data", "q", "s.txt"])
    assert disclosed() in copied
  end

  test "a write naming no sources records an unnamed outside source, and sources: [] none",
       %{actor: actor} do
    :ok = Arca.put(actor, ["data", "unnamed.txt"], "u")

    assert {:ok, "u", [%Prima.Source{class: :outside, name: nil}]} =
             ObjectRevisions.read(actor, ["data", "unnamed.txt"])

    :ok = Arca.put(actor, ["data", "none.txt"], "n", sources: [])
    assert {:ok, "n", []} = ObjectRevisions.read(actor, ["data", "none.txt"])
  end

  # ---------------------------------------------------------------------------
  # Consumers resolve settled generations only
  # ---------------------------------------------------------------------------

  test "a download sends the settled bytes while a newer generation is stored but unsettled",
       %{actor: actor} do
    path = ["data", "dl.txt"]
    :ok = Arca.put(actor, path, "settled")
    newer = mark(actor, path, :put, 5, [])
    :ok = ObjectRevisions.store(actor, newer, "newer")

    assert {:ok, conn} = Arca.serve_to_conn(Plug.Test.conn(:get, "/"), actor, path)
    assert {200, _headers, "settled"} = Plug.Test.sent_resp(conn)
  end

  describe "a create (put_if_none_match)" do
    setup do
      previous = Application.get_env(:arca, :storage_adapter)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:arca, :storage_adapter, previous),
          else: Application.delete_env(:arca, :storage_adapter)
      end)

      {:ok, previous_adapter: previous}
    end

    test "lands on an empty path, refuses over a settled object, and is unknown when its " <>
           "store may have landed",
         %{actor: actor, previous_adapter: previous} do
      path = ["data", "create.txt"]
      assert :ok = Arca.put_if_none_match(actor, path, "one")
      assert {:error, :exists} = Arca.put_if_none_match(actor, path, "two")
      assert {:ok, "one"} = Arca.get(actor, path)
      assert [_one] = generations(actor, path)

      unknown = ["data", "unknown.txt"]
      Application.put_env(:arca, :storage_adapter, Arca.ObjectRevisionsTest.UnknownStore)
      assert {:error, :unknown} = Arca.put_if_none_match(actor, unknown, "maybe")
      assert {:error, :not_found} = Arca.get(actor, unknown)
      refute Arca.exists?(actor, unknown)

      if previous,
        do: Application.put_env(:arca, :storage_adapter, previous),
        else: Application.delete_env(:arca, :storage_adapter)

      assert :ok = Arca.put_if_none_match(actor, unknown, "sure")
      assert {:ok, "sure"} = Arca.get(actor, unknown)
    end
  end

  test "a prefix delete tombstones every row under it and no other, and fences a store " <>
         "marked before it",
       %{actor: actor} do
    a = ["data", "dir", "a.txt"]
    b = ["data", "dir", "sub", "b.txt"]
    sibling = ["data", "dirx.txt"]
    :ok = Arca.put(actor, a, "a")
    :ok = Arca.put(actor, b, "b")
    :ok = Arca.put(actor, sibling, "x")

    before = mark(actor, a, :put, 4, [])
    :ok = Arca.delete_tree(actor, ["data", "dir"])
    :ok = ObjectRevisions.store(actor, before, "late")
    assert settle(actor, before) == :dead

    for path <- [a, b] do
      assert %ObjectRevision{deleted: true, settled_generation: nil} = row(actor, path)
      assert {:error, :not_found} = Arca.get(actor, path)
    end

    assert {:ok, []} = Arca.list_recursive(actor, ["data", "dir"])
    assert %ObjectRevision{deleted: false} = row(actor, sibling)
    assert {:ok, "x"} = Arca.get(actor, sibling)
  end

  test "a recursive listing and a subtree read answer settled generations only",
       %{actor: actor} do
    settled = ["data", "tree", "a.txt"]
    pending_only = ["data", "tree", "pending.txt"]
    :ok = Arca.put(actor, settled, "v1")

    v2 = mark(actor, settled, :put, 2, [])
    :ok = ObjectRevisions.store(actor, v2, "v2")
    only = mark(actor, pending_only, :put, 7, [])
    :ok = ObjectRevisions.store(actor, only, "pending")

    assert {:ok, [^settled]} = Arca.list_recursive(actor, ["data", "tree"])
    assert {:ok, [{["a.txt"], "v1"}]} = Arca.read_subtree(actor, ["data", "tree"])
  end

  test "a conditional replace answers on the settled generation it read", %{actor: actor} do
    path = ["data", "cas.txt"]
    :ok = Arca.put(actor, path, "old")

    assert {:ok, "old", {:generation, g} = pre} = Arca.get_for_update(actor, path)
    assert g == row(actor, path).settled_generation

    assert :ok = Arca.put_if_match(actor, path, "new", pre)
    assert {:ok, "new"} = Arca.get(actor, path)
    landed = generations(actor, path)

    assert {:error, :precondition_failed} = Arca.put_if_match(actor, path, "replay", pre)
    assert {:ok, "new"} = Arca.get(actor, path)
    assert generations(actor, path) == landed

    :ok = Arca.delete(actor, path)
    assert {:error, :missing} = Arca.put_if_match(actor, path, "gone", pre)
    assert {:error, :not_found} = Arca.get(actor, path)
    assert generations(actor, path) == landed
  end

  # ---------------------------------------------------------------------------
  # Retention
  # ---------------------------------------------------------------------------

  test "a host write marks, stores and settles, and retention keeps its pending generation " <>
         "until a newer write settles",
       %{actor: actor} do
    path = ["data", "host.txt"]
    :ok = Arca.put(actor, path, "v1")
    first = row(actor, path)
    assert first.settled_generation == first.generation
    assert generations(actor, path) == [first.generation]

    pending = mark(actor, path, :put, 7, [])
    :ok = ObjectRevisions.store(actor, pending, "pending")

    future = DateTime.add(DateTime.utc_now(), 86_400, :second)
    assert {:ok, 0} = ObjectRevisions.collect(actor, future, false)
    assert generations(actor, path) == [first.generation, pending.generation]
    assert {:ok, "pending"} = stored(actor, pending.generation, path)

    :ok = Arca.put(actor, path, "v3")
    newest = row(actor, path).settled_generation
    assert {:ok, 2} = ObjectRevisions.collect(actor, future, false)
    assert generations(actor, path) == [newest]
    assert {:error, :not_found} = stored(actor, pending.generation, path)
    assert {:error, :not_found} = stored(actor, first.generation, path)
    assert {:ok, "v3"} = Arca.get(actor, path)
  end

  test "retention collects superseded and tombstoned generations and keeps the pointer",
       %{actor: actor} do
    path = ["data", "ret.txt"]
    :ok = Arca.put(actor, path, "v1")
    :ok = Arca.put(actor, path, "v2v2")
    :ok = Arca.delete(actor, path)
    :ok = Arca.put(actor, path, "v3v3v3")
    [g1, g2, g4] = generations(actor, path)
    assert row(actor, path).settled_generation == g4
    assert {:ok, %{generations: 3, bytes: 12}} = ObjectRevisions.physical(actor)

    future = DateTime.add(DateTime.utc_now(), 86_400, :second)

    # A dry run counts and deletes nothing.
    assert {:ok, 2} = ObjectRevisions.collect(actor, future, true)
    assert {:ok, %{generations: 3, bytes: 12}} = ObjectRevisions.physical(actor)
    assert {:ok, "v1"} = stored(actor, g1, path)

    # The retention kind collects only what is older than its window.
    assert {:ok, 0} = Arca.Retention.ObjectGenerations.prune(actor, 1, false)
    assert {:ok, %{generations: 3, bytes: 12}} = ObjectRevisions.physical(actor)

    assert {:ok, 2} = ObjectRevisions.collect(actor, future, false)
    assert generations(actor, path) == [g4]
    assert {:ok, %{generations: 1, bytes: 6}} = ObjectRevisions.physical(actor)
    assert {:error, :not_found} = stored(actor, g1, path)
    assert {:error, :not_found} = stored(actor, g2, path)
    assert {:ok, "v3v3v3"} = Arca.get(actor, path)
  end

  test "a generation whose object cannot be deleted keeps its row for the next pass",
       %{actor: actor} do
    path = ["data", "stuck.txt"]
    :ok = Arca.put(actor, path, "v1")
    :ok = Arca.put(actor, path, "v2")
    [g1, g2] = generations(actor, path)
    previous = Application.get_env(:arca, :storage_adapter)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:arca, :storage_adapter, previous),
        else: Application.delete_env(:arca, :storage_adapter)
    end)

    Application.put_env(:arca, :storage_adapter, Arca.ObjectRevisionsTest.UndeletableStore)
    future = DateTime.add(DateTime.utc_now(), 86_400, :second)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, 0} = ObjectRevisions.collect(actor, future, false)
    end)

    assert generations(actor, path) == [g1, g2]
    assert {:ok, "v1"} = stored(actor, g1, path)
  end

  test "an object under objects/ no row names is collected once older than the cutoff",
       %{actor: actor} do
    aged = ["objects", "999", "data", "orphan.txt"]
    fresh = ["objects", "998", "data", "fresh.txt"]
    adapter = Arca.Storage.configured_adapter()
    :ok = adapter.put(actor, aged, "orphan")
    :ok = adapter.put(actor, fresh, "fresh")
    :ok = Arca.put(actor, ["data", "named.txt"], "named")
    [named] = generations(actor, ["data", "named.txt"])

    File.touch!(Arca.Adapters.Local.build_path(actor, aged), System.os_time(:second) - 2 * 86_400)
    cutoff = DateTime.add(DateTime.utc_now(), -3_600, :second)

    assert {:ok, 1} = ObjectRevisions.collect(actor, cutoff, true)
    assert {:ok, "orphan"} = adapter.get(actor, aged)

    assert {:ok, 1} = ObjectRevisions.collect(actor, cutoff, false)
    assert {:error, :not_found} = adapter.get(actor, aged)
    assert {:ok, "fresh"} = adapter.get(actor, fresh)
    assert {:ok, "named"} = stored(actor, named, ["data", "named.txt"])
  end

  # ---------------------------------------------------------------------------
  # The facade's own refusals
  # ---------------------------------------------------------------------------

  test "objects/ is refused to every facade caller", %{actor: actor} do
    :ok = Arca.put(actor, ["data", "hidden.txt"], "hidden")
    [g] = generations(actor, ["data", "hidden.txt"])
    key = ["objects", "#{g}", "data", "hidden.txt"]
    dir = ["objects", "#{g}"]

    assert {:error, :forbidden} = Arca.get(actor, key)
    assert {:error, :forbidden} = Arca.get_for_update(actor, key)
    assert {:error, :forbidden} = Arca.list_typed(actor, dir)
    assert {:error, :forbidden} = Arca.list_typed(actor, ["objects"])
    assert {:error, :forbidden} = Arca.list_recursive(actor, ["objects"])
    assert {:error, :forbidden} = Arca.read_subtree(actor, ["objects"])
    assert {:error, :forbidden} = Arca.usage(actor, ["objects"])
    assert {:error, :forbidden} = Arca.put(actor, key, "overwrite")
    assert {:error, :forbidden} = Arca.delete(actor, key)
    assert {:error, :forbidden} = Arca.delete_tree(actor, dir)
    assert {:error, :forbidden} = Arca.delete_tree(actor, ["objects"])
    refute Arca.exists?(actor, key)

    # Nothing the refusals named moved.
    assert {:ok, "hidden"} = stored(actor, g, ["data", "hidden.txt"])
  end

  test "a tree replacement at or under data/, or of the whole tree, is refused and writes nothing",
       %{actor: actor} do
    files = [{["a.txt"], "a"}]

    for path <- [["data", "t"], ["data"], []] do
      assert {:error, :atomic_replace_unsupported} =
               Arca.replace_tree(actor, path, files, cap: :exempt)
    end

    assert {:error, :not_found} = Arca.get(actor, ["data", "t", "a.txt"])
    assert {:ok, []} = Arca.list_recursive(actor, ["data"])
    assert {:ok, %{generations: 0, bytes: 0}} = ObjectRevisions.physical(actor)
  end

  test "a path is a file or a directory, and a deleted file's name can become a directory",
       %{actor: actor} do
    :ok = Arca.put(actor, ["data", "f"], "file")
    assert {:error, :enotdir} = Arca.put(actor, ["data", "f", "g"], "under")

    :ok = Arca.put(actor, ["data", "d", "a"], "inside")
    assert {:error, :eisdir} = Arca.put(actor, ["data", "d"], "over")
    assert {:ok, "file"} = Arca.get(actor, ["data", "f"])
    assert {:ok, "inside"} = Arca.get(actor, ["data", "d", "a"])

    :ok = Arca.put(actor, ["data", "a"], "was a file")
    [old] = generations(actor, ["data", "a"])
    :ok = Arca.delete(actor, ["data", "a"])

    assert :ok = Arca.put(actor, ["data", "a", "b"], "now a dir")
    assert {:ok, "now a dir"} = Arca.get(actor, ["data", "a", "b"])

    assert row(actor, ["data", "a", "b"]).settled_generation >
             row(actor, ["data", "a"]).generation

    # The retained file object and the new one under it do not collide.
    assert {:ok, "was a file"} = stored(actor, old, ["data", "a"])
    assert {:error, :not_found} = Arca.get(actor, ["data", "a"])
  end
end
