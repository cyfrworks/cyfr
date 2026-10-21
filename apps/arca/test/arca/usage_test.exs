# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.UsageTest do
  @moduledoc """
  The usage-cache discipline in one place: creates outside `data/` bump,
  deletes drop, reads load once and cache, invalidate/1 clears an athanor
  whole. Under `data/` a scope holds what it visibly holds: its settled
  objects, counted from the rows, never a pending or retired generation,
  and each settlement drops the counters. The
  two enforcement surfaces (the byte cap, the public scope quota) read
  through this module, so the discipline holds for both by construction.

  The counters are node-local, so a peer's copy is short by whatever this
  member wrote since the peer walked the tree, and the byte cap it feeds
  can admit past its ceiling for that long. The bound is stated here:
  `ttl_ms/0`, never extended by a bump, and dropped at once by the
  invalidation a cell-wide announcement lands on.
  """

  use ExUnit.Case, async: false

  # The usage walk reaches the storage cap, which the settings accessor
  # reads from the store, so the tests need a sandbox owner.
  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    base = Path.join(System.tmp_dir!(), "usage_#{System.unique_integer([:positive])}")

    prev_base = Application.fetch_env!(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)
    Arca.Cache.init()

    actor = Arca.Test.Actor.local()
    Arca.Usage.invalidate(actor)

    on_exit(fn ->
      Arca.Usage.invalidate(actor)
      Application.put_env(:arca, :base_path, prev_base)
      File.rm_rf!(base)
    end)

    {:ok, actor: actor}
  end

  test "outside data/, reads walk once and cache; creates bump; deletes drop", %{actor: actor} do
    :ok = Arca.put(actor, ["threads", "a.txt"], "aaaa")

    assert {:ok, 4} = Arca.Usage.athanor_bytes(actor)

    assert {:ok, %{files: 1, bytes: 4}} =
             Arca.Usage.scope_usage(actor, "threads")

    # A successful create bumps the cached counters in place — no walk.
    :ok = Arca.put(actor, ["threads", "b.txt"], "bb")
    assert {:ok, 6} = Arca.Usage.athanor_bytes(actor)

    assert {:ok, %{files: 2, bytes: 6}} =
             Arca.Usage.scope_usage(actor, "threads")

    # A delete drops the entries; the next read walks the truth afresh.
    :ok = Arca.delete(actor, ["threads", "b.txt"])
    assert {:ok, 4} = Arca.Usage.athanor_bytes(actor)

    assert {:ok, %{files: 1, bytes: 4}} =
             Arca.Usage.scope_usage(actor, "threads")
  end

  test "an overwrite over-counts — the safe direction — until invalidated", %{actor: actor} do
    :ok = Arca.put(actor, ["threads", "a.txt"], "aaaa")
    assert {:ok, 4} = Arca.Usage.athanor_bytes(actor)

    # Overwriting the same 4 bytes bumps again: 8 cached over 4 stored.
    :ok = Arca.put(actor, ["threads", "a.txt"], "aaaa")
    assert {:ok, 8} = Arca.Usage.athanor_bytes(actor)

    # invalidate/1 clears the whole athanor — total and scope pairs — and
    # the next read walks the truth.
    Arca.Usage.invalidate(actor)
    assert {:ok, 4} = Arca.Usage.athanor_bytes(actor)

    assert {:ok, %{files: 1, bytes: 4}} =
             Arca.Usage.scope_usage(actor, "threads")
  end

  test "a peer's copy is short by what this member wrote, bounded by a TTL no bump extends",
       %{actor: actor} do
    key = Arca.Cache.Keys.athanor_usage(actor)

    :ok = Arca.put(actor, ["threads", "a.txt"], "aaaa")
    assert {:ok, 4} = Arca.Usage.athanor_bytes(actor)
    peers_copy = 4

    # The bump is the writing member's own, so a peer's copy does not
    # move with it.
    :ok = Arca.put(actor, ["threads", "b.txt"], "bbbbbb")
    assert {:ok, 10} = Arca.Usage.athanor_bytes(actor)

    # A peer, standing in: its entry still reads the total it walked, so
    # the byte cap it feeds decides against 4 while 10 are stored. That is
    # an over-admission, not a stale number in a report.
    Arca.Cache.put(key, peers_copy, Arca.Usage.ttl_ms())
    assert {:ok, 4} = Arca.Usage.athanor_bytes(actor)

    # The bound: the entry expires one TTL after the walk that made it,
    # and a bump raises the total without touching that expiry. So the
    # walk that counts every member's writes is at most `ttl_ms/0` away,
    # and that is what holds when an announcement is lost.
    assert Arca.Usage.ttl_ms() == :timer.minutes(5)
    [{^key, 4, expires_at}] = :ets.lookup(Arca.Cache.table_name(), key)
    :ok = Arca.put(actor, ["threads", "c.txt"], "cc")
    assert [{^key, 6, ^expires_at}] = :ets.lookup(Arca.Cache.table_name(), key)

    # And the invalidation a cell-wide announcement lands on drops it at
    # once: the next read walks the tree and counts every member's write.
    Arca.Usage.invalidate(actor)
    assert {:ok, 12} = Arca.Usage.athanor_bytes(actor)
  end

  describe "guest objects under data/" do
    # The visible state, with the cached counters dropped first so each
    # answer is a cold load.
    defp cold(actor) do
      Arca.Usage.invalidate(actor)
      {:ok, bytes} = Arca.Usage.athanor_bytes(actor)
      Arca.Usage.invalidate(actor)
      {:ok, scope} = Arca.Usage.scope_usage(actor, "data")
      {bytes, scope}
    end

    test "a write, a replacement, a delete and a recreate are counted as visible from the rows",
         %{actor: actor} do
      :ok = Arca.put(actor, ["threads", "t.txt"], "ttt")

      :ok = Arca.put(actor, ["data", "a.txt"], String.duplicate("a", 60))
      assert {63, %{files: 1, bytes: 60}} = cold(actor)

      # A replacement counts its own bytes, never the generation it retired.
      :ok = Arca.put(actor, ["data", "a.txt"], String.duplicate("b", 50))
      assert {53, %{files: 1, bytes: 50}} = cold(actor)

      :ok = Arca.delete(actor, ["data", "a.txt"])
      assert {3, %{files: 0, bytes: 0}} = cold(actor)

      :ok = Arca.put(actor, ["data", "a.txt"], "cc")
      assert {5, %{files: 1, bytes: 2}} = cold(actor)

      # Three generations are kept for retention, and the quota counts one.
      assert {:ok, %{generations: 3, bytes: 112}} = Arca.ObjectRevisions.physical(actor)
    end

    test "a pending generation and a retired one change neither the total nor the scope",
         %{actor: actor} do
      :ok = Arca.put(actor, ["data", "a.txt"], "1234")
      before = cold(actor)

      # A mark whose store landed and that never settled.
      {:ok, {:ok, mark}} =
        Arca.Repo.transaction(fn ->
          Arca.ObjectRevisions.mark!(actor, ["data", "a.txt"], :put, %{
            bytes: 9,
            sources: []
          })
        end)

      :ok = Arca.ObjectRevisions.store(actor, mark, "pending!!")
      assert cold(actor) == before
      assert {:ok, "1234"} = Arca.get(actor, ["data", "a.txt"])

      # A tombstoned path's retained generations count nothing.
      :ok = Arca.delete(actor, ["data", "a.txt"])
      assert {0, %{files: 0, bytes: 0}} = cold(actor)
      assert {:ok, %{generations: 2, bytes: 13}} = Arca.ObjectRevisions.physical(actor)
    end

    test "a settlement drops the counters, so a cached total never misses a replacement",
         %{actor: actor} do
      :ok = Arca.put(actor, ["data", "a.txt"], String.duplicate("a", 10))
      assert {:ok, 10} = Arca.Usage.athanor_bytes(actor)
      assert {:ok, %{files: 1, bytes: 10}} = Arca.Usage.scope_usage(actor, "data")

      :ok = Arca.put(actor, ["data", "a.txt"], "a")
      assert :miss = Arca.Cache.get(Arca.Cache.Keys.athanor_usage(actor))
      assert :miss = Arca.Cache.get(Arca.Cache.Keys.scope_usage_bytes(actor, "data"))
      assert {:ok, 1} = Arca.Usage.athanor_bytes(actor)
      assert {:ok, %{files: 1, bytes: 1}} = Arca.Usage.scope_usage(actor, "data")
    end
  end

  test "an actor with no athanor names no tree, and that is a refusal, not zero",
       %{actor: actor} do
    # `{:ok, 0}` here would read an unresolved tenant as an empty athanor,
    # and the byte cap above would admit the write it was asked about.
    assert {:error, :no_athanor} = Arca.Usage.athanor_bytes(%{actor | athanor_id: nil})
    assert {:error, :no_athanor} = Arca.Usage.athanor_bytes(%{actor | athanor_id: ""})
  end
end
