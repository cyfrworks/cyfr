# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ObjectRevisionsS3Test.UnknownStore do
  @moduledoc false
  # The S3 adapter for the calls a create makes, with every generation
  # store landing and then answering that it cannot say whether it did: a
  # store whose connection failed after the request reached the bucket.
  use Arca.Storage.TestDouble

  def get(actor, path), do: Arca.Adapters.S3.get(actor, path)

  def put(actor, ["objects" | _] = key, content) do
    :ok = Arca.Adapters.S3.put(actor, key, content)
    {:error, :unknown}
  end

  def put(actor, path, content), do: Arca.Adapters.S3.put(actor, path, content)
end

defmodule Arca.ObjectRevisionsS3Test do
  @moduledoc """
  Guest objects under `data/` against a real S3-compatible store: the S3
  leg of `object_revisions_test.exs`. Every generation's bytes are an
  object of its own, `objects/<generation>/<path>`, and every read,
  listing, download, count and copy through the `Arca` facade answers
  only a settled generation, however the steps of its writers interleave
  with one another and with a delete. The quota counts what is visible,
  read cold from the rows; retention collects retired generations and
  keeps the pointer and a write in flight.

  Excluded from ordinary runs (`:s3_integration`). Each test works in an
  athanor of its own, so no two tests name one key, and the suite's keys
  live under a run prefix of its own (`Arca.Test.S3Env.run_prefix/1`),
  deleted on exit.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{ExecutionAttempts, ObjectRevisions}
  alias Arca.Schemas.{ObjectGeneration, ObjectRevision}
  alias Arca.Test.S3Env

  @moduletag :s3_integration

  setup_all do
    prefix = S3Env.run_prefix("objectrevisions")
    previous = S3Env.configure!(prefix: prefix)
    :ok = S3Env.create_bucket!()
    on_exit(fn -> S3Env.restore(previous) end)
    S3Env.guard!(prefix)

    :ok
  end

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    previous = Application.get_env(:arca, :storage_adapter)
    athanor_id = "ath_ors3_#{System.unique_integer([:positive])}"
    actor = Arca.Test.Actor.local(athanor_id: athanor_id)

    on_exit(fn ->
      Arca.Usage.invalidate(actor)
      restore_adapter(previous)
    end)

    Application.put_env(:arca, :storage_adapter, Arca.Adapters.S3)
    Arca.Cache.init()
    Arca.Test.Actor.athanor!(athanor_id)
    Arca.Usage.invalidate(actor)

    {:ok, actor: actor, previous_adapter: previous}
  end

  defp restore_adapter(nil), do: Application.delete_env(:arca, :storage_adapter)
  defp restore_adapter(previous), do: Application.put_env(:arca, :storage_adapter, previous)

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
    do: Arca.Adapters.S3.get(actor, ["objects", "#{generation}" | path])

  defp cold_usage(actor, path) do
    Arca.Usage.invalidate(actor)
    Arca.usage(actor, path)
  end

  defp cold_scope(actor) do
    Arca.Usage.invalidate(actor)
    {:ok, scope} = Arca.Usage.scope_usage(actor, "data")
    Arca.Usage.invalidate(actor)
    {:ok, usage} = Arca.usage(actor, ["data"])
    assert scope == usage
    scope
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

    :ok = ObjectRevisions.store(actor, b, "bbb")
    assert settle(actor, b) == :settled
    :ok = ObjectRevisions.store(actor, a, "aaa")
    assert settle(actor, a) == :superseded

    assert {:ok, "bbb"} = Arca.get(actor, path)

    assert {:ok, "bbb", [%Prima.Source{class: :outside, name: "b.example"}]} =
             ObjectRevisions.read(actor, path)

    assert {:ok, "aaa"} = stored(actor, a.generation, path)
    assert {:error, :forbidden} = Arca.get(actor, ["objects", "#{a.generation}" | path])
  end

  test "a generation marked but not stored, then stored but not settled, reads the settled one",
       %{actor: actor} do
    path = ["data", "c2", "doc.txt"]
    :ok = Arca.put(actor, path, "v1")
    listing = Arca.list_typed(actor, ["data", "c2"])

    v2 = mark(actor, path, :put, 11, [])
    assert {:ok, "v1"} = Arca.get(actor, path)

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
    refute Arca.exists?(actor, path)
    assert {:ok, [{"keep.txt", :file}]} = Arca.list_typed(actor, ["data", "c3"])
    assert {:ok, %{files: 0, bytes: 0}} = cold_usage(actor, path)
  end

  test "of two writers the older settlement writes nothing", %{actor: actor} do
    path = ["data", "c5.txt"]
    a = mark(actor, path, :put, 1, [filed()])
    b = mark(actor, path, :put, 1, [Prima.Source.outside("b.example")])
    :ok = ObjectRevisions.store(actor, a, "a")
    :ok = ObjectRevisions.store(actor, b, "b")

    assert settle(actor, b) == :settled
    after_newer = row(actor, path)
    assert settle(actor, a) == :superseded
    assert row(actor, path) == after_newer

    assert {:ok, "b", [%Prima.Source{class: :outside, name: "b.example"}]} =
             ObjectRevisions.read(actor, path)
  end

  test "a write paused across a delete is dead, and a recreate settles above the fence",
       %{actor: actor} do
    path = ["data", "c6.txt"]
    :ok = Arca.put(actor, path, "first")

    a = mark(actor, path, :put, 6, [])
    :ok = Arca.delete(actor, path)
    tombstone = row(actor, path)
    assert %ObjectRevision{deleted: true, settled_generation: nil} = tombstone

    :ok = ObjectRevisions.store(actor, a, "paused")
    assert settle(actor, a) == :dead
    assert {:error, :not_found} = Arca.get(actor, path)

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
    pending = mark(actor, path, :put, 10, [disclosed()])
    :ok = ObjectRevisions.store(actor, pending, "restricted")

    :ok = Arca.append(actor, path, "suffix", sources: [])

    assert {:ok, "cleansuffix", [_filed] = sources} = ObjectRevisions.read(actor, path)
    assert sources == [filed()]
    assert {:ok, "cleansuffix"} = Arca.get(actor, path)
    assert {:error, :forbidden} = Arca.get(actor, ["objects", "#{pending.generation}" | path])
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

  # ---------------------------------------------------------------------------
  # Consumers resolve settled generations only
  # ---------------------------------------------------------------------------

  test "a download sends the settled object's body while a newer generation is unsettled",
       %{actor: actor} do
    path = ["data", "dl.txt"]
    :ok = Arca.put(actor, path, "settled")
    newer = mark(actor, path, :put, 5, [])
    :ok = ObjectRevisions.store(actor, newer, "newer")

    assert {:ok, conn} = Arca.serve_to_conn(Plug.Test.conn(:get, "/"), actor, path)
    assert {200, _headers, "settled"} = Plug.Test.sent_resp(conn)
  end

  test "a create lands on an empty path, refuses over a settled object, and is unknown when " <>
         "its store may have landed",
       %{actor: actor} do
    path = ["data", "create.txt"]
    assert :ok = Arca.put_if_none_match(actor, path, "one")
    assert {:error, :exists} = Arca.put_if_none_match(actor, path, "two")
    assert {:ok, "one"} = Arca.get(actor, path)
    assert [_one] = generations(actor, path)

    unknown = ["data", "unknown.txt"]
    Application.put_env(:arca, :storage_adapter, Arca.ObjectRevisionsS3Test.UnknownStore)
    assert {:error, :unknown} = Arca.put_if_none_match(actor, unknown, "maybe", cap: :exempt)
    assert {:error, :not_found} = Arca.get(actor, unknown)
    refute Arca.exists?(actor, unknown)

    Application.put_env(:arca, :storage_adapter, Arca.Adapters.S3)
    assert :ok = Arca.put_if_none_match(actor, unknown, "sure")
    assert {:ok, "sure"} = Arca.get(actor, unknown)
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
    assert {:ok, "x"} = Arca.get(actor, sibling)
  end

  test "a recursive listing and a subtree read answer settled generations only",
       %{actor: actor} do
    settled = ["data", "tree", "a.txt"]
    :ok = Arca.put(actor, settled, "v1")

    v2 = mark(actor, settled, :put, 2, [])
    :ok = ObjectRevisions.store(actor, v2, "v2")
    only = mark(actor, ["data", "tree", "pending.txt"], :put, 7, [])
    :ok = ObjectRevisions.store(actor, only, "pending")

    assert {:ok, [^settled]} = Arca.list_recursive(actor, ["data", "tree"])
    assert {:ok, [{["a.txt"], "v1"}]} = Arca.read_subtree(actor, ["data", "tree"])
  end

  test "a conditional replace answers on the settled generation it read", %{actor: actor} do
    path = ["data", "cas.txt"]
    :ok = Arca.put(actor, path, "old")

    assert {:ok, "old", {:generation, _g} = pre} = Arca.get_for_update(actor, path)
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
  # Usage and retention
  # ---------------------------------------------------------------------------

  test "the quota read cold counts the visible files and bytes, never a pending or retired " <>
         "generation",
       %{actor: actor} do
    path = ["data", "q.txt"]
    :ok = Arca.put(actor, path, String.duplicate("a", 60))
    assert %{files: 1, bytes: 60} = cold_scope(actor)

    :ok = Arca.put(actor, path, String.duplicate("b", 50))
    assert %{files: 1, bytes: 50} = cold_scope(actor)

    pending = mark(actor, path, :put, 9, [])
    :ok = ObjectRevisions.store(actor, pending, "pending!!")
    assert %{files: 1, bytes: 50} = cold_scope(actor)

    :ok = Arca.delete(actor, path)
    assert %{files: 0, bytes: 0} = cold_scope(actor)

    :ok = Arca.put(actor, path, "cc")
    assert %{files: 1, bytes: 2} = cold_scope(actor)
    assert {:ok, %{generations: 4, bytes: 121}} = ObjectRevisions.physical(actor)
  end

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
    assert {:ok, %{generations: 3, bytes: 12}} = ObjectRevisions.physical(actor)

    future = DateTime.add(DateTime.utc_now(), 86_400, :second)
    assert {:ok, 2} = ObjectRevisions.collect(actor, future, true)
    assert {:ok, %{generations: 3, bytes: 12}} = ObjectRevisions.physical(actor)

    assert {:ok, 2} = ObjectRevisions.collect(actor, future, false)
    assert generations(actor, path) == [g4]
    assert {:ok, %{generations: 1, bytes: 6}} = ObjectRevisions.physical(actor)
    assert {:error, :not_found} = stored(actor, g1, path)
    assert {:error, :not_found} = stored(actor, g2, path)
    assert {:ok, "v3v3v3"} = Arca.get(actor, path)
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
    assert {:error, :forbidden} = Arca.list_typed(actor, ["objects"])
    assert {:error, :forbidden} = Arca.list_recursive(actor, ["objects"])
    assert {:error, :forbidden} = Arca.read_subtree(actor, ["objects"])
    assert {:error, :forbidden} = Arca.usage(actor, ["objects"])
    assert {:error, :forbidden} = Arca.put(actor, key, "overwrite")
    assert {:error, :forbidden} = Arca.delete(actor, key)
    assert {:error, :forbidden} = Arca.delete_tree(actor, dir)
    refute Arca.exists?(actor, key)

    assert {:ok, "hidden"} = stored(actor, g, ["data", "hidden.txt"])
  end

  test "a path is a file or a directory, and a deleted file's name can become a directory",
       %{actor: actor} do
    :ok = Arca.put(actor, ["data", "f"], "file")
    assert {:error, :enotdir} = Arca.put(actor, ["data", "f", "g"], "under")

    :ok = Arca.put(actor, ["data", "d", "a"], "inside")
    assert {:error, :eisdir} = Arca.put(actor, ["data", "d"], "over")

    :ok = Arca.put(actor, ["data", "a"], "was a file")
    [old] = generations(actor, ["data", "a"])
    :ok = Arca.delete(actor, ["data", "a"])

    assert :ok = Arca.put(actor, ["data", "a", "b"], "now a dir")
    assert {:ok, "now a dir"} = Arca.get(actor, ["data", "a", "b"])
    assert {:ok, "was a file"} = stored(actor, old, ["data", "a"])
    assert {:error, :not_found} = Arca.get(actor, ["data", "a"])
  end

  # ---------------------------------------------------------------------------
  # Tree shape at settlement, names, limits, abandoned marks and copies
  # ---------------------------------------------------------------------------

  test "of a file and a path under it marked together, the second to settle refuses and the first stays readable",
       %{actor: actor} do
    for {first, second, refusal} <- [{:child, :parent, :eisdir}, {:parent, :child, :enotdir}] do
      parent = ["data", "shape-#{first}"]
      paths = %{parent: parent, child: parent ++ ["c"]}
      p = mark(actor, paths.parent, :put, 6, [])
      c = mark(actor, paths.child, :put, 5, [])
      marks = %{parent: p, child: c}
      :ok = ObjectRevisions.store(actor, p, "parent")
      :ok = ObjectRevisions.store(actor, c, "child")

      assert settle(actor, marks[first]) == :settled
      assert settle(actor, marks[second]) == refusal

      assert {:ok, _bytes} = Arca.get(actor, paths[first])
      assert {:error, :not_found} = Arca.get(actor, paths[second])
    end
  end

  test "a name with a combining mark lists, counts and deletes what lies under it, and is no file over it",
       %{actor: actor} do
    dir = ["data", "é"]
    :ok = Arca.put(actor, dir ++ ["child"], "child", sources: [])

    assert {:ok, [{"child", :file}]} = Arca.list_typed(actor, dir)
    assert {:ok, [["data", "é", "child"]]} = Arca.list_recursive(actor, dir)
    assert {:ok, %{files: 1, bytes: 5}} = cold_usage(actor, dir)
    assert {:error, :eisdir} = Arca.put(actor, dir, "parent", sources: [])

    assert :ok = Arca.delete_tree(actor, dir)
    assert {:error, :not_found} = Arca.get(actor, dir ++ ["child"])
  end

  # An S3 key is at most 1024 bytes with the tenant's prefix in it, so a
  # path near the logical byte ceiling is Local's case; the depth ceiling
  # and a generation gaining a digit are both adapters'.
  test "a path at the logical depth limit stays writable, and a generation gaining a digit lengthens only its key",
       %{actor: actor} do
    deep = ["data" | Enum.map(1..31, &Integer.to_string/1)]
    assert :ok = Prima.PathSafety.validate_segments!(deep)
    assert :ok = Arca.put(actor, deep, "deep", sources: [])
    assert {:ok, "deep"} = Arca.get(actor, deep)

    near =
      ["data"] ++ List.duplicate(String.duplicate("a", 200), 4) ++ [String.duplicate("c", 40)]

    for n <- 1..10, do: assert(:ok = Arca.put(actor, near, Integer.to_string(n), sources: []))
    assert {:ok, "10"} = Arca.get(actor, near)
    assert Enum.max(generations(actor, near)) >= 10

    assert_raise ArgumentError, fn -> Arca.put(actor, deep ++ ["x"], "x", sources: []) end
    assert row(actor, deep ++ ["x"]) == nil
  end

  test "a mark abandoned past its settling window is collected, though it is its path's last",
       %{actor: actor} do
    path = ["data", "abandoned.txt"]
    m = mark(actor, path, :put, 15, [])
    :ok = ObjectRevisions.store(actor, m, "never published")
    old = DateTime.add(DateTime.utc_now(), -40, :day)

    {1, _} =
      Arca.Repo.update_all(
        from(g in ObjectGeneration,
          where:
            g.athanor_id == ^actor.athanor_id and g.path == ^m.key and
              g.generation == ^m.generation
        ),
        set: [marked_at: old]
      )

    {:ok, :expired} =
      Arca.Repo.transaction(fn -> ObjectRevisions.settle!(actor, m, [], fresh: true) end)

    assert {:ok, 1} =
             ObjectRevisions.collect(actor, DateTime.add(DateTime.utc_now(), -30, :day), false)

    assert {:error, :not_found} = stored(actor, m.generation, path)
    assert generations(actor, path) == []

    # One marked now stays while its writer may still settle it.
    fresh = mark(actor, path, :put, 5, [])
    :ok = ObjectRevisions.store(actor, fresh, "fresh")

    assert {:ok, 0} =
             ObjectRevisions.collect(
               actor,
               DateTime.add(DateTime.utc_now(), 86_400, :second),
               false
             )

    assert {:ok, "fresh"} = stored(actor, fresh.generation, path)
  end

  test "a copy naming no sources joins an unnamed outside source, and sources: [] joins none",
       %{actor: actor} do
    :ok = Arca.put(actor, ["data", "src", "f"], "clean", sources: [])

    assert {:ok, [["f"]]} =
             Arca.copy_tree(actor, ["data", "src"], ["data", "dst"],
               transform: fn _relative, _content -> "outside material" end
             )

    assert {:ok, "outside material", [%Prima.Source{class: :outside, name: nil}]} =
             ObjectRevisions.read(actor, ["data", "dst", "f"])

    assert {:ok, [["f"]]} = Arca.copy_tree(actor, ["data", "src"], ["data", "own"], sources: [])
    assert {:ok, "clean", []} = ObjectRevisions.read(actor, ["data", "own", "f"])
  end

  # ---------------------------------------------------------------------------
  # Through real admissions and holds (`Arca.ExecutionAttempts.while_held/6`)
  # ---------------------------------------------------------------------------

  # An admitted execution whose attempt `runner` claims at fence 1, whose
  # run has read `sources`.
  defp writer!(actor, sources \\ []) do
    n = System.unique_integer([:positive])

    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_ors3_#{n}",
          reference: "catalyst:local.files:0.1.0",
          user_id: actor.user_id,
          athanor_id: actor.athanor_id,
          component_type: "catalyst",
          input: "{}",
          origin: :programmatic
        },
        Arca.Test.Actor.standing(actor.athanor_id)
      )

    runner = "runner_#{n}"
    :ok = ExecutionAttempts.claim(actor, attempt.attempt, 1, runner, Arca.Test.Actor.stored())
    :ok = Arca.Execution.join_sources(actor, execution.id, sources)
    %{actor: actor, execution: execution, attempt: attempt.attempt, runner: runner}
  end

  defp held(w, write),
    do:
      ExecutionAttempts.while_held(
        w.actor,
        w.attempt,
        1,
        w.runner,
        write,
        Arca.Test.Actor.stored()
      )

  # A put whose store call stores at its mark's key, telling `around` each
  # step as it reaches it.
  defp put(w, path, bytes, around \\ fn _step -> :ok end) do
    %{
      op: :put,
      path: path,
      bytes: byte_size(bytes),
      io: fn mark ->
        around.(:marked)
        result = Arca.put(w.actor, path, bytes, mark: mark)
        around.(:stored)
        result
      end
    }
  end

  defp append(w, path, bytes),
    do: %{
      op: :append,
      path: path,
      bytes: byte_size(bytes),
      io: fn mark -> Arca.append(w.actor, path, bytes, mark: mark) end
    }

  # A step that holds the writer until the test says go.
  defp pause_at(test, wanted) do
    fn step ->
      if step == wanted do
        send(test, {:paused, wanted, self()})

        receive do
          :go -> :ok
        end
      end

      :ok
    end
  end

  defp read(w, path), do: held(w, %{op: :read, path: path})

  defp cancel!(w) do
    {:ok, _} =
      Arca.Execution.record_end(
        w.actor,
        w.execution.id,
        "cancelled",
        %{completed_at: DateTime.utc_now(), duration_ms: 1},
        w.attempt,
        Arca.Test.Actor.stored()
      )

    :ok
  end

  # The run's execution row gone, as retention's purge takes it: payloads
  # released first, its attempts and write intents with it.
  defp purge!(w) do
    {:ok, []} = Arca.ExecutionPayloads.release(w.actor, [w.execution.id])
    {:ok, 1} = Arca.Execution.delete_ids([w.execution.id], athanor_id: w.actor.athanor_id)
    assert {:error, :not_found} = Arca.Execution.sources(w.actor, w.execution.id)
  end

  # The decision every send of the run is held to (`Opus.Ledger.check/4`):
  # whether its ledger as it stands may reach the host under `flows`.
  defp sends?(w, flows) do
    {:ok, %{sources: ledger, launch_classes: launch}} =
      Arca.Execution.flow_state(w.actor, w.execution.id)

    Prima.Flow.uncovered(ledger, {:domain, "api.example.test"},
      flows: flows,
      launch_classes: launch
    ) == []
  end

  defp every_class,
    do: for(class <- Prima.Source.classes(), do: %{from: class, to: "api.example.test"})

  describe "through admitted attempts" do
    test "a store held until a newer write settles lands at its own key, and the read serves the newer write with its sources",
         %{actor: actor} do
      path = ["data", "att-a.txt"]
      stale = writer!(actor, [filed()])
      newer = writer!(actor, [Prima.Source.outside("b.test")])
      test = self()

      task = Task.async(fn -> held(stale, put(stale, path, "stale", pause_at(test, :marked))) end)
      assert_receive {:paused, :marked, store}, 5_000

      assert {:ok, {:confirmed, :ok}} = held(newer, put(newer, path, "newer"))
      send(store, :go)
      assert {:ok, {:confirmed, :ok}} = Task.await(task)

      reader = writer!(actor)
      assert {:ok, {:read, {:ok, "newer"}}} = read(reader, path)

      assert {:ok, "newer", [%Prima.Source{class: :outside, name: "b.test"}]} =
               ObjectRevisions.read(actor, path)

      [stale_intent] = ExecutionAttempts.write_intents(actor, stale.attempt)
      assert {:ok, "stale"} = stored(actor, stale_intent.generation, path)
    end

    test "metadata before bytes and bytes before metadata: a reader sees the settled object until the hold settles",
         %{actor: actor} do
      path = ["data", "att-b.txt"]
      :ok = Arca.put(actor, path, "before", sources: [])
      w = writer!(actor)
      test = self()

      around = fn step ->
        send(test, {:paused, step, self()})

        receive do
          :go -> :ok
        end
      end

      task = Task.async(fn -> held(w, put(w, path, "after", around)) end)
      assert_receive {:paused, :marked, store}, 5_000
      assert {:ok, "before"} = Arca.get(actor, path)
      send(store, :go)
      assert_receive {:paused, :stored, ^store}, 5_000
      assert {:ok, "before"} = Arca.get(actor, path)
      assert {:ok, %{files: 1, bytes: 6}} = cold_usage(actor, path)
      send(store, :go)
      assert {:ok, {:confirmed, :ok}} = Task.await(task)
      assert {:ok, "after"} = Arca.get(actor, path)
    end

    test "the deletion fence: a write held across another attempt's delete is dead with both holds live, and a recreate settles",
         %{actor: actor} do
      path = ["data", "att-c.txt"]
      :ok = Arca.put(actor, path, "g1", sources: [])
      a = writer!(actor)
      b = writer!(actor)
      test = self()

      task = Task.async(fn -> held(a, put(a, path, "late", pause_at(test, :marked))) end)
      assert_receive {:paused, :marked, store}, 5_000

      assert {:ok, {:confirmed, :ok}} =
               held(b, %{op: :delete, path: path, io: fn _mark -> :ok end})

      send(store, :go)
      assert {:ok, {:failed, {:error, :dead}}} = Task.await(task)
      assert {:error, :not_found} = Arca.get(actor, path)

      assert {:ok, {:confirmed, :ok}} = held(b, put(b, path, "recreated"))
      assert {:ok, "recreated"} = Arca.get(actor, path)
      assert %{deleted: false} = row(actor, path)
    end

    test "a writer whose hold ends after its mark or after its store is uncertain, and nothing of it is read",
         %{actor: actor} do
      for step <- [:marked, :stored] do
        path = ["data", "att-d-#{step}.txt"]
        :ok = Arca.put(actor, path, "kept", sources: [])
        w = writer!(actor)
        end_hold = fn reached -> if reached == step, do: cancel!(w), else: :ok end

        assert {:ok, {:uncertain, :hold_lost}} = held(w, put(w, path, "lost", end_hold))
        assert {:ok, "kept"} = Arca.get(actor, path)
      end
    end

    test "two, then five, simultaneous facade appends all land, each once and whole",
         %{actor: actor} do
      for writers <- [2, 5] do
        path = ["data", "att-race-#{writers}.jsonl"]
        lines = for n <- 1..writers, do: String.duplicate("writer-#{n};", 40) <> "\n"

        answers =
          lines
          |> Task.async_stream(&Arca.append(actor, path, &1, cap: :exempt),
            max_concurrency: writers,
            ordered: false,
            timeout: 60_000
          )
          |> Enum.map(fn {:ok, answer} -> answer end)

        assert answers == List.duplicate(:ok, writers)
        {:ok, content} = Arca.get(actor, path)

        assert content |> String.split("\n", trim: true) |> Enum.map(&(&1 <> "\n")) |> Enum.sort() ==
                 Enum.sort(lines)
      end
    end

    test "an uncertain restricted overwrite, a clean append and the writer purged: the clean object and its suffix are read and may be sent anywhere",
         %{actor: actor} do
      path = ["data", "att-f.txt"]
      clean = writer!(actor)
      assert {:ok, {:confirmed, :ok}} = held(clean, put(clean, path, "clean;"))

      restricted = writer!(actor, [disclosed()])

      uncertain = %{
        op: :put,
        path: path,
        bytes: 10,
        io: fn mark ->
          :ok = Arca.put(actor, path, "restricted", mark: mark)
          {:error, :unknown}
        end
      }

      assert {:ok, {:uncertain, :unknown_outcome}} = held(restricted, uncertain)
      assert {:ok, {:confirmed, :ok}} = held(clean, append(clean, path, "suffix"))
      purge!(restricted)

      sender = writer!(actor)
      assert {:ok, {:read, {:ok, "clean;suffix"}}} = read(sender, path)
      {:ok, ledger} = Arca.Execution.sources(actor, sender.execution.id)
      refute disclosed() in ledger
      assert sends?(sender, every_class())
    end

    test "a run that reads what an earlier run wrote carries what that run read, refused where no flow lets it out, also once the writer is purged",
         %{actor: actor} do
      path = ["data", "att-g.txt"]
      flows = [%{from: :files_by_grant, to: "api.example.test"}]
      w = writer!(actor, [filed()])
      assert {:ok, {:confirmed, :ok}} = held(w, put(w, path, "from a filed note"))

      first = writer!(actor)
      assert {:ok, {:read, {:ok, _bytes}}} = read(first, path)
      refute sends?(first, flows)

      purge!(w)
      later = writer!(actor)
      assert {:ok, {:read, {:ok, _bytes}}} = read(later, path)
      assert filed() in elem(Arca.Execution.sources(actor, later.execution.id), 1)
      refute sends?(later, flows)
      assert sends?(later, [%{from: :filed, to: "api.example.test"} | flows])
    end

    # The stated limit: S3 caps a key at 1,024 bytes with the tenant's
    # prefix and `objects/<generation>/` in it, so a logical path near the
    # 1,024-byte logical ceiling has a key S3 refuses.
    test "a key S3 refuses after the mark fails the intent, publishes nothing, and leaves a generation retention collects",
         %{actor: actor} do
      path =
        ["data"] ++ List.duplicate(String.duplicate("a", 240), 4) ++ [String.duplicate("b", 55)]

      assert byte_size(Enum.join(path, "/")) == 1024
      w = writer!(actor)

      assert {:ok, {:failed, {:error, {:s3_error, 400}}}} = held(w, put(w, path, "valid"))

      assert [%{state: "failed", reason: "s3_error"}] =
               ExecutionAttempts.write_intents(actor, w.attempt)

      assert {:error, :not_found} = Arca.get(actor, path)
      assert [_generation] = generations(actor, path)

      {1, _} =
        Arca.Repo.update_all(
          from(g in ObjectGeneration, where: g.athanor_id == ^actor.athanor_id),
          set: [marked_at: DateTime.add(DateTime.utc_now(), -40, :day)]
        )

      assert {:ok, 1} =
               ObjectRevisions.collect(actor, DateTime.add(DateTime.utc_now(), -30, :day), false)

      assert generations(actor, path) == []
    end

    test "a restricted settled prefix keeps its sources through an attempt's clean append and a clean copy",
         %{actor: actor} do
      path = ["data", "att-h", "p.txt"]
      :ok = Arca.put(actor, path, "secret;", sources: [disclosed()])
      w = writer!(actor)
      assert {:ok, {:confirmed, :ok}} = held(w, append(w, path, "clean"))

      assert {:ok, [["p.txt"]]} =
               Arca.copy_tree(actor, ["data", "att-h"], ["data", "att-h-copy"], sources: [])

      for read_path <- [path, ["data", "att-h-copy", "p.txt"]] do
        reader = writer!(actor)
        assert {:ok, {:read, {:ok, "secret;clean"}}} = read(reader, read_path)
        refute sends?(reader, [%{from: :files_by_grant, to: "api.example.test"}])
      end
    end
  end
end
