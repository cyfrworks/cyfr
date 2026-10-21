# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.ComponentCache do
  @moduledoc """
  Caches compiled `%Wasmex.Components.Component{}` resources by content
  digest, in `Locus.Runtime.Cache`.

  On a hit the JIT compilation is skipped. On a miss the component's bytes
  are fetched, hashed and refused unless they are the digest's, refused
  when they use a feature the runtime does not admit (`admitted/1`), compiled
  (`Wasmex.Components.Component.new/2`) and cached. Compilation is a pure
  function of the bytes and the engine, so the key is the digest alone:
  every athanor running the same bundle shares one compiled resource, and
  a re-registered reference has a new digest, so nothing needs
  invalidating per athanor. A compiled component is a NIF resource of the
  engine that built it, so an entry also names the engine's generation
  (`Locus.Runtime.SharedEngine.generation/0`) and an engine restart serves nothing
  built by its predecessor.
  """

  @ttl_ms :timer.minutes(15)

  # The store a component compiles in: Wasmex declares no type for it.
  @typep store :: %Wasmex.Components.Store{}

  @doc """
  Returns a compiled component, using the cache when possible.

  If the cache contains a component for `digest` built by the current
  engine, returns it immediately and `fetch` is not called. Otherwise
  `fetch` answers the component's bytes (`{:ok, bytes}`, or an error that
  is answered as it is), which are compiled using `store` and cached only
  when they hash to `digest` and are admitted; bytes that are not are
  `{:error, {:artifact, message}}`.
  """
  @spec get_or_compile(
          String.t(),
          (-> {:ok, binary()} | {:error, term()}),
          store()
        ) :: {:ok, Wasmex.Components.Component.t()} | {:error, term()}
  def get_or_compile(digest, fetch, store)
      when is_binary(digest) and digest != "" and is_function(fetch, 0) do
    generation = Locus.Runtime.SharedEngine.generation()
    cache_key = {:compiled_component, digest}

    case Locus.Runtime.Cache.get(cache_key) do
      {:ok, {^generation, component}} ->
        {:ok, component}

      _ ->
        with {:ok, wasm_bytes} <- fetch.(),
             :ok <- verified(wasm_bytes, digest),
             :ok <- admitted(wasm_bytes),
             {:ok, component} <- Wasmex.Components.Component.new(store, wasm_bytes) do
          Locus.Runtime.Cache.put(cache_key, {generation, component}, @ttl_ms)
          {:ok, component}
        end
    end
  end

  @doc """
  `:ok` when the component uses none of the features the runtime refuses
  (`Prima.ComponentFeatures`), checked on the exact bytes about to be
  compiled; otherwise `{:error, {:artifact, sentence}}`, the refusal's own
  sentence, as admission answers it. Every compile asks it first, so the
  cache only ever holds a compile of bytes that passed.
  """
  @spec admitted(binary()) :: :ok | {:error, {:artifact, String.t()}}
  def admitted(bytes) when is_binary(bytes) do
    case Prima.ComponentFeatures.check(bytes) do
      :ok -> :ok
      {:error, refusal} -> {:error, {:artifact, Prima.Refusal.message(refusal)}}
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
