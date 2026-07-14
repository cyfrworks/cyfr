# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.PathSafety do
  @moduledoc """
  Canonical path-safety denylist for storage paths.

  Single source of truth shared by `Arca.Storage.validate_path!/1`
  (raising, segment-list contract) and `Opus.StorageHandler.validate_path_safe/1`
  (tuple-returning, string contract). Before consolidation the two
  validators enforced different subsets (Arca: `..` + null bytes + encoded
  `..`; Opus: `..` + absolute paths) — neither a superset, so what "safe"
  meant could drift between the storage layer and the WASM policy boundary.

  The shared core is the union of both, plus backslash rejection:

    * literal `..` segments
    * multi-layer URI-encoded `..` (`%2e%2e`, `%252e...`)
    * null bytes
    * absolute paths (leading `/`)
    * backslashes (Windows separators that sidestep `/`-based checks)

  Everything here rejects-more than either previous validator; no legitimate
  relative storage path is affected.
  """

  @doc """
  Validate a list of path segments. Raises `ArgumentError` on the first
  unsafe segment. Returns `:ok`.
  """
  @spec validate_segments!([String.t()]) :: :ok
  def validate_segments!(segments) when is_list(segments) do
    Enum.each(segments, fn segment ->
      case check_segment(segment) do
        :ok -> :ok
        {:error, message} -> raise ArgumentError, message
      end
    end)

    :ok
  end

  @doc """
  Validate a relative, slash-separated path string.

  Returns `:ok` or `{:error, message}`.
  """
  @spec validate_relative_path(String.t()) :: :ok | {:error, String.t()}
  def validate_relative_path(path) when is_binary(path) do
    if String.starts_with?(path, "/") do
      {:error, "Absolute paths are not allowed."}
    else
      path
      |> String.split("/")
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce_while(:ok, fn segment, :ok ->
        case check_segment(segment) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp check_segment(segment) when is_binary(segment) do
    cond do
      segment == ".." ->
        {:error, "Path traversal rejected: segment \"..\" is not allowed"}

      String.contains?(segment, <<0>>) ->
        {:error, "Path traversal rejected: null bytes are not allowed"}

      String.contains?(segment, "\\") ->
        {:error, "Path traversal rejected: backslashes are not allowed"}

      String.starts_with?(segment, "/") ->
        {:error, "Path traversal rejected: absolute segments are not allowed"}

      fully_decode(segment) =~ ~r/(^|[\/\\])\.\.($|[\/\\])/ ->
        {:error, "Path traversal rejected: encoded \"..\" is not allowed"}

      true ->
        :ok
    end
  end

  defp check_segment(other) do
    {:error, "Path traversal rejected: non-string segment #{inspect(other)}"}
  end

  # Decode URI-encoded segments until output stabilizes, catching multi-layer encoding.
  defp fully_decode(segment) do
    decoded = URI.decode(segment)
    if decoded == segment, do: segment, else: fully_decode(decoded)
  rescue
    # Malformed percent-encoding — treat the raw value as final.
    ArgumentError -> segment
  end
end
