# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ComponentCacheTest do
  @moduledoc """
  The engine's cache is its own and grants nothing: an entry expires, a
  pattern finds only live entries, and an invalidated one is gone. A
  compiled component is keyed by its digest and run only if its bytes
  hash to it: bytes that do not are refused before compilation, and
  bytes that do not compile are cached under nothing. (A hit that skips
  the fetch is exercised by the integration suite, which runs real
  components.)
  """

  use ExUnit.Case, async: true

  alias Opus.{Cache, ComponentCache}

  @wasm File.read!(Path.join(__DIR__, "../support/test_wasm/math.wasm"))

  defp store do
    limits = %Wasmex.StoreLimits{memory_size: 64 * 1024 * 1024, instances: 10, tables: 100, memories: 10}
    {:ok, store} = Wasmex.Components.Store.new(limits, Opus.SharedEngine.get())
    store
  end

  describe "Opus.Cache" do
    test "an entry is kept until it expires, found by pattern, and forgotten when invalidated" do
      key = {:cache_test, System.unique_integer([:positive]), :a}
      assert Cache.get(key) == :miss

      :ok = Cache.put(key, :value, 60_000)
      assert Cache.get(key) == {:ok, :value}
      assert Cache.match({:cache_test, elem(key, 1), :_}) == [{key, :value}]

      :ok = Cache.invalidate(key)
      assert Cache.get(key) == :miss
      assert Cache.match({:cache_test, elem(key, 1), :_}) == []

      :ok = Cache.put(key, :value, 0)
      Process.sleep(1)
      assert Cache.get(key) == :miss
      assert Cache.match({:cache_test, elem(key, 1), :_}) == []
    end
  end

  describe "get_or_compile/3" do
    test "bytes that hash to the digest are compiled, and ones that do not compile are cached under nothing" do
      # A core module, not a component: it verifies and then fails to compile.
      digest = Cyfr.Digest.sha256(@wasm)
      test = self()

      fetch = fn ->
        send(test, :fetched)
        {:ok, @wasm}
      end

      assert {:error, message} = ComponentCache.get_or_compile(digest, fetch, store())
      assert message =~ "WebAssembly"
      assert_received :fetched
      assert Cache.get({:compiled_component, digest}) == :miss

      assert {:error, _} = ComponentCache.get_or_compile(digest, fetch, store())
      assert_received :fetched
    end

    test "bytes that do not hash to the digest are refused before compilation and never cached" do
      digest = Cyfr.Digest.sha256("the component this attempt was assigned")

      assert {:error, {:artifact, message}} =
               ComponentCache.get_or_compile(digest, fn -> {:ok, @wasm} end, store())

      assert message =~ "do not match its digest"
      assert Cache.get({:compiled_component, digest}) == :miss

      assert {:error, {:artifact, _}} =
               ComponentCache.get_or_compile(digest, fn -> {:ok, :not_bytes} end, store())
    end

    test "a fetch that refuses is answered as it is" do
      digest = Cyfr.Digest.sha256("unfetchable")

      assert {:error, {:artifact, "no"}} =
               ComponentCache.get_or_compile(digest, fn -> {:error, {:artifact, "no"}} end, store())
    end
  end
end
