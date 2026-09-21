# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.UsageTest do
  @moduledoc """
  The usage-cache discipline in one place: creates bump, deletes drop,
  reads walk once and cache, invalidate/1 clears an athanor whole. The
  two enforcement surfaces (the byte cap, the public scope quota) read
  through this module, so the discipline holds for both by construction.

  The counters are node-local, so a peer's copy is short by whatever this
  member wrote since the peer walked the tree, and the byte cap it feeds
  can admit past its ceiling for that long. The bound is stated here:
  `ttl_ms/0`, never extended by a bump, and dropped at once by the
  invalidation a cell-wide announcement lands on.
  """

  use ExUnit.Case, async: false

  setup do
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

  test "reads walk once and cache; creates bump; deletes drop", %{actor: actor} do
    :ok = Arca.put(actor, ["data", "a.txt"], "aaaa")

    assert {:ok, 4} = Arca.Usage.athanor_bytes(actor)

    assert {:ok, %{files: 1, bytes: 4}} =
             Arca.Usage.scope_usage(actor, "data")

    # A successful create bumps the cached counters in place — no walk.
    :ok = Arca.put(actor, ["data", "b.txt"], "bb")
    assert {:ok, 6} = Arca.Usage.athanor_bytes(actor)

    assert {:ok, %{files: 2, bytes: 6}} =
             Arca.Usage.scope_usage(actor, "data")

    # A delete drops the entries; the next read walks the truth afresh.
    :ok = Arca.delete(actor, ["data", "b.txt"])
    assert {:ok, 4} = Arca.Usage.athanor_bytes(actor)

    assert {:ok, %{files: 1, bytes: 4}} =
             Arca.Usage.scope_usage(actor, "data")
  end

  test "an overwrite over-counts — the safe direction — until invalidated", %{actor: actor} do
    :ok = Arca.put(actor, ["data", "a.txt"], "aaaa")
    assert {:ok, 4} = Arca.Usage.athanor_bytes(actor)

    # Overwriting the same 4 bytes bumps again: 8 cached over 4 stored.
    :ok = Arca.put(actor, ["data", "a.txt"], "aaaa")
    assert {:ok, 8} = Arca.Usage.athanor_bytes(actor)

    # invalidate/1 clears the whole athanor — total and scope pairs — and
    # the next read walks the truth.
    Arca.Usage.invalidate(actor)
    assert {:ok, 4} = Arca.Usage.athanor_bytes(actor)

    assert {:ok, %{files: 1, bytes: 4}} =
             Arca.Usage.scope_usage(actor, "data")
  end

  test "a peer's copy is short by what this member wrote, bounded by a TTL no bump extends",
       %{actor: actor} do
    key = Arca.Cache.Keys.athanor_usage(actor)

    :ok = Arca.put(actor, ["data", "a.txt"], "aaaa")
    assert {:ok, 4} = Arca.Usage.athanor_bytes(actor)
    peers_copy = 4

    # The bump is the writing member's own, so a peer's copy does not
    # move with it.
    :ok = Arca.put(actor, ["data", "b.txt"], "bbbbbb")
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
    :ok = Arca.put(actor, ["data", "c.txt"], "cc")
    assert [{^key, 6, ^expires_at}] = :ets.lookup(Arca.Cache.table_name(), key)

    # And the invalidation a cell-wide announcement lands on drops it at
    # once: the next read walks the tree and counts every member's write.
    Arca.Usage.invalidate(actor)
    assert {:ok, 12} = Arca.Usage.athanor_bytes(actor)
  end

  test "an actor with no athanor names no tree, and that is a refusal, not zero",
       %{actor: actor} do
    # `{:ok, 0}` here would read an unresolved tenant as an empty estate,
    # and the byte cap above would admit the write it was asked about.
    assert {:error, :no_athanor} = Arca.Usage.athanor_bytes(%{actor | athanor_id: nil})
    assert {:error, :no_athanor} = Arca.Usage.athanor_bytes(%{actor | athanor_id: ""})
  end
end
