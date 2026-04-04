defmodule Arca.TinctureData.QueryCacheTest do
  use ExUnit.Case, async: false

  alias Arca.TinctureData.QueryCache
  alias Sanctum.Context

  @ctx Context.build(org_id: "", project_id: "default", authenticated: false)

  setup do
    # Ensure cache table exists
    Arca.Cache.init()
    # Clean up after each test
    on_exit(fn -> QueryCache.invalidate_tincture(@ctx, "local", "test-tincture") end)
    :ok
  end

  describe "get/put lifecycle" do
    test "returns :miss for uncached query" do
      assert :miss = QueryCache.get(@ctx, "local", "test-tincture", "q1", "abc123")
    end

    test "put then get returns cached value" do
      result = %{columns: ["id"], rows: [[1], [2]]}
      :ok = QueryCache.put(@ctx, "local", "test-tincture", "q1", "abc123", result, 60_000)
      assert {:ok, ^result} = QueryCache.get(@ctx, "local", "test-tincture", "q1", "abc123")
    end

    test "different params hash returns :miss" do
      result = %{data: "cached"}
      :ok = QueryCache.put(@ctx, "local", "test-tincture", "q1", "hash1", result, 60_000)
      assert :miss = QueryCache.get(@ctx, "local", "test-tincture", "q1", "hash2")
    end
  end

  describe "scope isolation" do
    test "different org_id cannot read each other's cache" do
      ctx_a = Context.build(org_id: "org-a", project_id: "default", authenticated: false)
      ctx_b = Context.build(org_id: "org-b", project_id: "default", authenticated: false)

      result = %{data: "org-a data"}
      :ok = QueryCache.put(ctx_a, "local", "test-tincture", "q1", "h", result, 60_000)

      assert {:ok, ^result} = QueryCache.get(ctx_a, "local", "test-tincture", "q1", "h")
      assert :miss = QueryCache.get(ctx_b, "local", "test-tincture", "q1", "h")

      # Clean up
      QueryCache.invalidate_tincture(ctx_a, "local", "test-tincture")
    end
  end

  describe "invalidate_tincture/3" do
    test "clears all queries for a tincture" do
      :ok = QueryCache.put(@ctx, "local", "test-tincture", "q1", "h1", :data1, 60_000)
      :ok = QueryCache.put(@ctx, "local", "test-tincture", "q2", "h2", :data2, 60_000)

      :ok = QueryCache.invalidate_tincture(@ctx, "local", "test-tincture")

      assert :miss = QueryCache.get(@ctx, "local", "test-tincture", "q1", "h1")
      assert :miss = QueryCache.get(@ctx, "local", "test-tincture", "q2", "h2")
    end

    test "does not affect other tinctures" do
      :ok = QueryCache.put(@ctx, "local", "test-tincture", "q1", "h1", :data1, 60_000)
      :ok = QueryCache.put(@ctx, "local", "other-tincture", "q1", "h1", :data2, 60_000)

      :ok = QueryCache.invalidate_tincture(@ctx, "local", "test-tincture")

      assert :miss = QueryCache.get(@ctx, "local", "test-tincture", "q1", "h1")
      assert {:ok, :data2} = QueryCache.get(@ctx, "local", "other-tincture", "q1", "h1")

      # Clean up
      QueryCache.invalidate_tincture(@ctx, "local", "other-tincture")
    end
  end

  describe "params_hash/1" do
    test "produces deterministic hash" do
      params = %{"date" => "2024-01-01", "symbol" => "AAPL"}
      h1 = QueryCache.params_hash(params)
      h2 = QueryCache.params_hash(params)
      assert h1 == h2
    end

    test "different params produce different hashes" do
      h1 = QueryCache.params_hash(%{"a" => 1})
      h2 = QueryCache.params_hash(%{"a" => 2})
      assert h1 != h2
    end
  end
end
