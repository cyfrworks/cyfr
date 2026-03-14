defmodule Arca.CacheTest do
  use ExUnit.Case, async: false

  alias Arca.Cache

  setup do
    Cache.init()

    on_exit(fn ->
      # Clean up test keys
      Cache.invalidate({:test, "key1"})
      Cache.invalidate({:test, "key2"})
    end)

    :ok
  end

  describe "init/0" do
    test "creates ETS table" do
      assert :ets.whereis(:arca_cache) != :undefined
    end

    test "is idempotent" do
      assert :ok = Cache.init()
      assert :ok = Cache.init()
    end
  end

  describe "get/1 and put/2" do
    test "returns :miss for absent key" do
      assert :miss = Cache.get({:test, "nonexistent"})
    end

    test "stores and retrieves a value" do
      :ok = Cache.put({:test, "key1"}, %{data: "hello"})
      assert {:ok, %{data: "hello"}} = Cache.get({:test, "key1"})
    end

    test "returns :miss for expired key" do
      :ok = Cache.put({:test, "key1"}, "value", 1)
      Process.sleep(5)
      assert :miss = Cache.get({:test, "key1"})
    end

    test "overwrites existing value" do
      :ok = Cache.put({:test, "key1"}, "first")
      :ok = Cache.put({:test, "key1"}, "second")
      assert {:ok, "second"} = Cache.get({:test, "key1"})
    end
  end

  describe "put/3 with custom TTL" do
    test "respects custom TTL" do
      :ok = Cache.put({:test, "key1"}, "value", 100_000)
      assert {:ok, "value"} = Cache.get({:test, "key1"})
    end
  end

  describe "match/1" do
    test "returns matching entries by key pattern" do
      :ok = Cache.put({:session, "user_1", "sess_a"}, %{name: "a"}, 60_000)
      :ok = Cache.put({:session, "user_1", "sess_b"}, %{name: "b"}, 60_000)
      :ok = Cache.put({:session, "user_2", "sess_c"}, %{name: "c"}, 60_000)

      results = Cache.match({:session, "user_1", :_})
      assert length(results) == 2

      names = Enum.map(results, fn {_key, val} -> val.name end) |> Enum.sort()
      assert names == ["a", "b"]
    end

    test "excludes expired entries" do
      :ok = Cache.put({:session, "user_3", "fresh"}, "yes", 60_000)
      :ok = Cache.put({:session, "user_3", "stale"}, "no", 1)
      Process.sleep(5)

      results = Cache.match({:session, "user_3", :_})
      assert length(results) == 1
      assert [{_, "yes"}] = results
    end

    test "returns empty list when no matches" do
      assert Cache.match({:no_such_type, :_}) == []
    end
  end

  describe "delete_match/1" do
    test "deletes all entries matching pattern" do
      :ok = Cache.put({:session, "s1"}, "data1", 60_000)
      :ok = Cache.put({:session, "s2"}, "data2", 60_000)
      :ok = Cache.put({:other, "o1"}, "keep", 60_000)

      :ok = Cache.delete_match({:session, :_})

      assert :miss = Cache.get({:session, "s1"})
      assert :miss = Cache.get({:session, "s2"})
      assert {:ok, "keep"} = Cache.get({:other, "o1"})
    end

    test "succeeds when no entries match" do
      assert :ok = Cache.delete_match({:nonexistent, :_})
    end
  end

  describe "invalidate/1" do
    test "removes cached value" do
      :ok = Cache.put({:test, "key1"}, "value")
      assert {:ok, "value"} = Cache.get({:test, "key1"})

      :ok = Cache.invalidate({:test, "key1"})
      assert :miss = Cache.get({:test, "key1"})
    end

    test "succeeds for absent key" do
      assert :ok = Cache.invalidate({:test, "nonexistent"})
    end
  end
end
