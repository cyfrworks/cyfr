# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Phase1g.CacheEvictionTest do
  # Eviction runs on Arca.Cache.Sweeper's timer, not the put/3 hot path.
  use ExUnit.Case, async: false

  test "the sweeper removes expired entries; fresh entries survive" do
    table = Arca.Cache.table_name()

    for i <- 1..5, do: Arca.Cache.put({:eviction_test, i}, "value_#{i}", 1)
    Arca.Cache.put({:eviction_test, :fresh}, "keep", 60_000)
    Process.sleep(10)

    # Expired rows stay physically present until a sweep — get/1 would
    # lazy-delete them, so probe ETS directly to prove the sweeper did the work.
    assert :ets.lookup(table, {:eviction_test, 1}) != []

    removed = Arca.Cache.Sweeper.sweep()
    assert removed >= 5

    assert :ets.lookup(table, {:eviction_test, 1}) == []
    assert {:ok, "keep"} = Arca.Cache.get({:eviction_test, :fresh})

    Arca.Cache.invalidate({:eviction_test, :fresh})
  end
end
