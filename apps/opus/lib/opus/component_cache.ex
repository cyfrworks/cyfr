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
    org_id = Keyword.get(opts, :org_id, "")
    project_id = Keyword.get(opts, :project_id, "default")
    cache_key = {:compiled_component, org_id, project_id, reference}

    case Arca.Cache.get(cache_key) do
      {:ok, {^digest, component}} ->
        {:ok, component}

      _ ->
        case Wasmex.Components.Component.new(store, wasm_bytes) do
          {:ok, component} ->
            Arca.Cache.put(cache_key, {digest, component}, @ttl_ms)
            {:ok, component}

          error ->
            error
        end
    end
  end
end