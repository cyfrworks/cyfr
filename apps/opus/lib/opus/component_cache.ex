# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ComponentCache do
  @moduledoc """
  Caches compiled `%Wasmex.Components.Component{}` resources by content
  digest, in `Opus.Cache`.

  On a hit the JIT compilation is skipped. On a miss the component's bytes
  are fetched, hashed and refused unless they are the digest's, compiled
  (`Wasmex.Components.Component.new/2`) and cached. Compilation is a pure
  function of the bytes and the engine, so the key is the digest alone:
  every athanor running the same bundle shares one compiled resource, and
  a re-registered reference has a new digest, so nothing needs
  invalidating per athanor. A compiled component is a NIF resource of the
  engine that built it, so an entry also names the engine's generation
  (`Opus.SharedEngine.generation/0`) and an engine restart serves nothing
  built by its predecessor.
  """

  @ttl_ms :timer.minutes(15)

  @doc """
  Returns a compiled component, using the cache when possible.

  If the cache contains a component for `digest` built by the current
  engine, returns it immediately and `fetch` is not called. Otherwise
  `fetch` answers the component's bytes (`{:ok, bytes}`, or an error that
  is answered as it is), which are compiled using `store` and cached only
  when they hash to `digest`; bytes that do not are
  `{:error, {:artifact, message}}`.
  """
  @spec get_or_compile(
          String.t(),
          (-> {:ok, binary()} | {:error, term()}),
          Wasmex.Components.Store.t()
        ) :: {:ok, Wasmex.Components.Component.t()} | {:error, term()}
  def get_or_compile(digest, fetch, store)
      when is_binary(digest) and digest != "" and is_function(fetch, 0) do
    generation = Opus.SharedEngine.generation()
    cache_key = {:compiled_component, digest}

    case Opus.Cache.get(cache_key) do
      {:ok, {^generation, component}} ->
        {:ok, component}

      _ ->
        with {:ok, wasm_bytes} <- fetch.(),
             :ok <- verified(wasm_bytes, digest),
             {:ok, component} <- Wasmex.Components.Component.new(store, wasm_bytes) do
          Opus.Cache.put(cache_key, {generation, component}, @ttl_ms)
          {:ok, component}
        end
    end
  end

  defp verified(bytes, digest) when is_binary(bytes) do
    if Prima.Digest.sha256(bytes) == digest,
      do: :ok,
      else:
        {:error, {:artifact, "Execution error: the component's bytes do not match its digest"}}
  end

  defp verified(_bytes, _digest),
    do: {:error, {:artifact, "Execution error: the component's bytes could not be read"}}
end
