# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.Artifacts do
  @moduledoc """
  A component's artifact bytes, by the digest its registry row records:
  checked at admission (`Crucible.Admission`) and answered to the
  attempt's runner (the `fetch_artifact` host call,
  `Crucible.Host.Storage`).

  Bytes are content-addressed and immutable. They are read from the
  registry's blob store (`Compendium.get_blob/2`), hashed, and
  cached for ten minutes only once their sha256 matched the digest, so a
  cached entry is verified by construction and is not hashed again. Each
  answer fires `[:cyfr, :opus, :fetch]` with the reference and whether the
  bytes were hashed.
  """

  require Logger

  @ttl_ms :timer.minutes(10)

  @doc """
  The bytes of the artifact with `digest`, read in `ctx` for the component
  `reference`. Answers `{:ok, bytes}`, or `{:error, reason}` with
  `:blob_not_found`, `{:corrupt, {:artifact, digest}}` when the stored
  bytes do not hash to `digest`, or the store's own reason.
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
        with {:ok, bytes} <- blob(ctx, digest, reference) do
          fetched(reference, true)

          with :ok <- verify(digest, Prima.Digest.sha256(bytes), reference) do
            Arca.Cache.put(cache_key, bytes, @ttl_ms)
            {:ok, bytes}
          end
        end
    end
  end

  # The registry verifies what it reads against the digest it was asked
  # for; bytes that do not match are an integrity refusal, never a store
  # that could not answer.
  defp blob(ctx, digest, reference) do
    case Compendium.get_blob(ctx, digest) do
      {:error, :digest_mismatch} ->
        Logger.error("[Crucible.Artifacts] the bytes of #{reference} do not match #{digest}")
        {:error, {:corrupt, {:artifact, digest}}}

      other ->
        other
    end
  end

  defp fetched(reference, hashed?) do
    :telemetry.execute([:cyfr, :opus, :fetch], %{count: 1}, %{
      reference: reference,
      hashed: hashed?
    })
  end

  # `Prima.Digest` is the only producer of both digests, so they carry the
  # same sha256:-prefixed spelling and one comparison decides.
  defp verify(expected, expected, _reference), do: :ok

  defp verify(expected, actual, reference) do
    Logger.error(
      "[Crucible.Artifacts] the bytes of #{reference} hash to #{actual}, not the " <>
        "recorded #{expected}; the component may have been modified"
    )

    {:error, {:corrupt, {:artifact, expected}}}
  end
end
