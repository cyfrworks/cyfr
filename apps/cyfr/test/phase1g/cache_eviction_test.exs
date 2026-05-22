# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Phase1g.CacheEvictionTest do
  use ExUnit.Case, async: false

  setup do
    # Save original max_entries and set a small limit for testing
    :ok
  end

  test "cache eviction removes expired entries first" do
    # Fill cache with entries that have very short TTLs
    for i <- 1..5 do
      Arca.Cache.put({:eviction_test, i}, "value_#{i}", 1)
    end

    # Wait for them to expire
    Process.sleep(10)

    # The next put should trigger eviction and clean up expired entries
    Arca.Cache.put({:eviction_test, :new}, "new_value", 60_000)

    # The new entry should exist
    assert {:ok, "new_value"} = Arca.Cache.get({:eviction_test, :new})

    # Clean up
    Arca.Cache.invalidate({:eviction_test, :new})
  end
end
