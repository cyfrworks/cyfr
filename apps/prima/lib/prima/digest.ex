# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Digest do
  @moduledoc """
  The one content-digest implementation and the one spelling of its result.

  Every producer (registration validation, OCI blob upload/pull, the
  executor's integrity gate) uses this, so a digest computed anywhere
  compares byte-equal to a digest computed anywhere else — the integrity
  gate never has to guess which format a row carries.
  """

  @doc """
  SHA-256 of the bytes, formatted `sha256:<lowercase hex>`.
  """
  @spec sha256(binary()) :: String.t()
  def sha256(bytes) when is_binary(bytes) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  end

  @doc """
  SHA-256 of the bytes as bare lowercase hex — no `sha256:` prefix.

  The keyed-lookup spelling: a secret hashed into a cache key or an index
  column, or a protocol that demands the bare form (AWS SigV4, id
  derivation). Content digests use `sha256/1`; this exists so the bare
  form has one author too.
  """
  @spec sha256_hex(binary()) :: String.t()
  def sha256_hex(bytes) when is_binary(bytes) do
    Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  end

  @doc """
  SHA-256 over a chunk sequence, formatted `sha256:<lowercase hex>`.

  Same result as `sha256(IO.iodata_to_binary(chunks))` without materializing
  the concatenation — for producers that hash many files or interleave
  name/content pairs.
  """
  @spec sha256_stream(Enumerable.t()) :: String.t()
  def sha256_stream(chunks) do
    chunks
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> then(&("sha256:" <> Base.encode16(&1, case: :lower)))
  end

  @doc """
  The digest of a set of files and their total size in bytes: SHA-256 over
  each `{relative_path, bytes}` in path order, each framed as the path, a
  NUL, the byte count in decimal, a NUL, then the bytes, so two different
  sets never frame to the same stream. A tincture's digest is this, from
  whichever producer computes it.
  """
  @spec file_set(Enumerable.t()) :: {String.t(), non_neg_integer()}
  def file_set(files) do
    sorted = Enum.sort_by(files, &elem(&1, 0))

    chunks =
      Enum.flat_map(sorted, fn {path, bytes} ->
        [path, <<0>>, Integer.to_string(byte_size(bytes)), <<0>>, bytes]
      end)

    {sha256_stream(chunks), Enum.reduce(sorted, 0, &(byte_size(elem(&1, 1)) + &2))}
  end
end
