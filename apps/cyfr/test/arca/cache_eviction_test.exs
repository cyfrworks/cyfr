# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CacheEvictionTest do
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

  test "binary values are bounded in bytes, oldest-expiring evicted first" do
    original = Application.get_env(:cyfr, :cache_max_binary_bytes)
    Application.put_env(:cyfr, :cache_max_binary_bytes, 1_000)

    on_exit(fn ->
      if original,
        do: Application.put_env(:cyfr, :cache_max_binary_bytes, original),
        else: Application.delete_env(:cyfr, :cache_max_binary_bytes)

      for tag <- [:old, :mid, :new], do: Arca.Cache.invalidate({:bytes_test, tag})
    end)

    # Clear the shared cache so unrelated entries cannot affect eviction order.
    table = Arca.Cache.table_name()

    for {key, value, _expires_at} <- :ets.tab2list(table), is_binary(value) do
      :ets.delete(table, key)
    end

    blob = String.duplicate("b", 600)
    # Distinct TTLs order eviction: the entry cap sorts by expiry, so under
    # a 1000-byte budget the two nearest-to-expiry blobs go first.
    Arca.Cache.put({:bytes_test, :old}, blob, 10_000)
    Arca.Cache.put({:bytes_test, :mid}, blob, 20_000)
    Arca.Cache.put({:bytes_test, :new}, blob, 30_000)

    Arca.Cache.Sweeper.sweep()

    assert Arca.Cache.get({:bytes_test, :old}) == :miss
    assert Arca.Cache.get({:bytes_test, :mid}) == :miss
    assert {:ok, _} = Arca.Cache.get({:bytes_test, :new})
  end

  test "compiled components get their own entry cap — byte_size cannot see NIF memory" do
    original = Application.get_env(:cyfr, :cache_max_compiled_components)
    Application.put_env(:cyfr, :cache_max_compiled_components, 2)

    on_exit(fn ->
      if original,
        do: Application.put_env(:cyfr, :cache_max_compiled_components, original),
        else: Application.delete_env(:cyfr, :cache_max_compiled_components)

      for i <- 1..4,
          do: Arca.Cache.invalidate(Arca.Cache.Keys.compiled_component("sha256:ref#{i}"))
    end)

    # Clear the shared cache's compiled entries first. The cap is enforced
    # over every compiled entry in the table at once, so one left behind by
    # earlier work raises the excess and evicts an entry this test keeps.
    table = Arca.Cache.table_name()

    for {{:compiled_component, _digest} = key, _value, _expires_at} <- :ets.tab2list(table) do
      :ets.delete(table, key)
    end

    for i <- 1..4 do
      Arca.Cache.put(
        Arca.Cache.Keys.compiled_component("sha256:ref#{i}"),
        {:fake_resource, i},
        :timer.minutes(i)
      )
    end

    Arca.Cache.Sweeper.sweep()

    assert Arca.Cache.get(Arca.Cache.Keys.compiled_component("sha256:ref1")) == :miss
    assert Arca.Cache.get(Arca.Cache.Keys.compiled_component("sha256:ref2")) == :miss
    assert {:ok, _} = Arca.Cache.get(Arca.Cache.Keys.compiled_component("sha256:ref3"))
    assert {:ok, _} = Arca.Cache.get(Arca.Cache.Keys.compiled_component("sha256:ref4"))
  end
end
