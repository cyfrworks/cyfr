# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ComponentCache do
  @moduledoc """
  Caches compiled `%Wasmex.Components.Component{}` resources keyed by
  component reference, validated by content digest.

  On cache hit with matching digest: skips ~50ms JIT compilation.
  On miss or digest mismatch: compiles via `Component.new/2`, caches result.

  Uses `Arca.Cache` (ETS-backed with TTL sweeper).
  """

  @ttl_ms :timer.minutes(15)

  @doc """
  Returns a compiled component, using the cache when possible.

  If the cache contains a component for `reference` with a matching `digest`,
  returns it immediately. Otherwise compiles `wasm_bytes` using `store` and
  caches the result.
  """
  @spec get_or_compile(String.t(), String.t(), binary(), Wasmex.Components.Store.t(), keyword()) ::
          {:ok, Wasmex.Components.Component.t()} | {:error, term()}
  def get_or_compile(reference, digest, wasm_bytes, store, opts \\ []) do
    case Keyword.get(opts, :athanor_id) do
      athanor_id when is_binary(athanor_id) and athanor_id != "" ->
        # The key shape is shared with the registry's invalidation and the
        # sweeper's cap through Arca.Cache.Keys.
        cached_compile(Arca.Cache.Keys.compiled_component(athanor_id, reference), digest, wasm_bytes, store)

      _ ->
        # No athanor, no cache: the compiled resource has no tenant to be
        # keyed under, so it is compiled for this call alone.
        Wasmex.Components.Component.new(store, wasm_bytes)
    end
  end

  defp cached_compile(cache_key, digest, wasm_bytes, store) do
    # A compiled component is a NIF resource tied to the engine that built
    # it — validate the engine generation alongside the digest so an engine
    # restart can never serve stale resources to stores from the new one.
    generation = Opus.SharedEngine.generation()

    case Arca.Cache.get(cache_key) do
      {:ok, {^digest, ^generation, component}} ->
        {:ok, component}

      _ ->
        case Wasmex.Components.Component.new(store, wasm_bytes) do
          {:ok, component} ->
            Arca.Cache.put(cache_key, {digest, generation, component}, @ttl_ms)
            {:ok, component}

          error ->
            error
        end
    end
  end
end
