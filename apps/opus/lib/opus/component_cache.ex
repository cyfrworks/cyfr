# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ComponentCache do
  @moduledoc """
  Caches compiled `%Wasmex.Components.Component{}` resources by content
  digest.

  On cache hit: skips ~50ms JIT compilation. On miss: compiles via
  `Component.new/2`, caches the result. Compilation is a pure function of
  the bytes and the engine, so the key is the digest alone — every athanor
  running the same bundle shares one compiled resource, and a re-registered
  reference has a new digest, so nothing needs invalidating per athanor.

  Uses `Arca.Cache` (ETS-backed with TTL sweeper).
  """

  @ttl_ms :timer.minutes(15)

  @doc """
  Returns a compiled component, using the cache when possible.

  If the cache contains a component for `digest` built by the current
  engine, returns it immediately and `fetch` is not called. Otherwise
  `fetch` answers the component's bytes (`{:ok, bytes}`, or an error that
  is answered as it is), which are compiled using `store` and cached.
  """
  @spec get_or_compile(
          String.t(),
          (-> {:ok, binary()} | {:error, term()}),
          Wasmex.Components.Store.t()
        ) :: {:ok, Wasmex.Components.Component.t()} | {:error, term()}
  def get_or_compile(digest, fetch, store)
      when is_binary(digest) and digest != "" and is_function(fetch, 0) do
    # A compiled component is a NIF resource tied to the engine that built
    # it — validate the engine generation alongside the digest so an engine
    # restart can never serve stale resources to stores from the new one.
    generation = Opus.SharedEngine.generation()
    cache_key = Arca.Cache.Keys.compiled_component(digest)

    case Arca.Cache.get(cache_key) do
      {:ok, {^generation, component}} ->
        {:ok, component}

      _ ->
        with {:ok, wasm_bytes} <- fetch.(),
             {:ok, component} <- Wasmex.Components.Component.new(store, wasm_bytes) do
          Arca.Cache.put(cache_key, {generation, component}, @ttl_ms)
          {:ok, component}
        end
    end
  end
end
