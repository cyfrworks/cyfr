# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Artifacts do
  @moduledoc """
  A component's artifact bytes, by the digest its registry row records:
  checked at admission (`Cyfr.Execution.Admission`) and answered to the
  attempt's runner (the `fetch_artifact` host call,
  `Cyfr.Execution.Host.Storage`).

  Bytes are content-addressed and immutable. They are read from the
  registry's blob store (`Compendium.Component.get_blob/2`), hashed, and
  cached for ten minutes only once their sha256 matched the digest, so a
  cached entry is verified by construction and is not hashed again. Each
  answer fires `[:cyfr, :opus, :fetch]` with the reference and whether the
  bytes were hashed.
  """

  @ttl_ms :timer.minutes(10)

  @doc """
  The bytes of the artifact with `digest`, read in `ctx` for the component
  `reference`. Answers `{:ok, bytes}`, or `{:error, reason}` with
  `:blob_not_found`, `{:integrity, sentence}` when the stored bytes do not
  hash to `digest`, or the store's own reason.
  """
  @spec fetch(Sanctum.Context.t(), String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch(%Sanctum.Context{} = ctx, digest, reference)
      when is_binary(digest) and is_binary(reference) do
    cache_key = Arca.Cache.Keys.wasm_bytes(digest)

    case Arca.Cache.get(cache_key) do
      {:ok, bytes} ->
        fetched(reference, false)
        {:ok, bytes}

      _miss ->
        with {:ok, bytes} <- Compendium.Component.get_blob(ctx, digest) do
          fetched(reference, true)

          with :ok <- verify(digest, Cyfr.Digest.sha256(bytes), reference) do
            Arca.Cache.put(cache_key, bytes, @ttl_ms)
            {:ok, bytes}
          end
        end
    end
  end

  defp fetched(reference, hashed?) do
    :telemetry.execute([:cyfr, :opus, :fetch], %{count: 1}, %{
      reference: reference,
      hashed: hashed?
    })
  end

  # `Cyfr.Digest` is the only producer of both digests, so they carry the
  # same sha256:-prefixed spelling and one comparison decides.
  defp verify(expected, expected, _reference), do: :ok

  defp verify(expected, actual, reference) do
    {:error,
     {:integrity,
      "Integrity check failed for #{reference}. " <>
        "Expected: #{expected}, Got: #{actual}. " <>
        "Component may have been modified. Re-register with `cyfr register`."}}
  end
end
