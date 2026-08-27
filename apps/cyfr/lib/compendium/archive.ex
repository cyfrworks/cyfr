# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Archive do
  @moduledoc """
  Pure compression/tar mechanics for component transit — bounded gzip
  inflation (the decompression-bomb guard the tincture ingress rides) and
  tarball creation (the OCI push's `src/` layer). Nothing here knows
  registries, manifests or Arca paths: callers own the limits and what
  the bytes mean.
  """

  @doc """
  Inflate gzip bytes, aborting with `{:error, :too_large}` once the
  output exceeds `max_bytes` — a streaming bound, so a malicious archive
  can never materialize an unbounded binary in memory. Any zlib failure
  answers `{:error, message}`.
  """
  @spec gunzip_bounded(binary(), pos_integer()) ::
          {:ok, binary()} | {:error, :too_large | String.t()}
  def gunzip_bounded(data, max_bytes) when is_binary(data) and is_integer(max_bytes) do
    z = :zlib.open()

    try do
      # 31 = 15 (max window) + 16 (gzip header/trailer).
      :zlib.inflateInit(z, 31)
      inflate_bounded(z, data, [], 0, max_bytes)
    rescue
      e -> {:error, Exception.message(e)}
    after
      :zlib.close(z)
    end
  end

  defp inflate_bounded(z, input, acc, total, max_bytes) do
    case :zlib.safeInflate(z, input) do
      {:continue, output} ->
        new_total = total + IO.iodata_length(output)

        if new_total > max_bytes do
          {:error, :too_large}
        else
          # Subsequent calls drain the internal buffer with [].
          inflate_bounded(z, [], [output | acc], new_total, max_bytes)
        end

      {:finished, output} ->
        new_total = total + IO.iodata_length(output)

        if new_total > max_bytes do
          {:error, :too_large}
        else
          {:ok, IO.iodata_to_binary(Enum.reverse([output | acc]))}
        end
    end
  end

  @doc """
  Create a gzipped tarball from `{charlist_name, binary_content}` entries.
  Answers `:none` when the tar cannot be produced — the caller's optional
  layer simply goes unshipped.

  arca:bypass-ok=D — `:erl_tar.create/3`'s :memory option is unreliable
  on OTP 28, so the tar round-trips through System.tmp_dir!. The bytes
  are produced and consumed entirely inside this function; no
  Arca-tracked content touches the local FS.
  """
  @spec create_tar_gz([{charlist(), binary()}]) :: {:ok, binary()} | :none
  def create_tar_gz(tar_entries) when is_list(tar_entries) do
    tmp = Path.join(System.tmp_dir!(), "cyfr_tar_#{:rand.uniform(1_000_000)}.tar")

    try do
      # arca:bypass-ok=D — tar written to the scratch path above.
      case :erl_tar.create(String.to_charlist(tmp), tar_entries) do
        :ok ->
          # arca:bypass-ok=D — read back the tar scratch file.
          case File.read(tmp) do
            {:ok, tar_binary} -> {:ok, :zlib.gzip(tar_binary)}
            {:error, _} -> :none
          end

        {:error, _} ->
          :none
      end
    after
      # arca:bypass-ok=D — remove the tar scratch file.
      File.rm(tmp)
    end
  end
end
