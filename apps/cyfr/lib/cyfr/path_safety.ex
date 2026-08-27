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

    * literal `..` and `.` segments (and their URI-encoded spellings,
      multi-layer included — `%2e%2e`, `%252e...`)
    * empty segments (`""` is not a name; on the segment-list contract it
      is refused rather than silently collapsed, because the two storage
      adapters disagreed on what it meant)
    * null bytes
    * absolute paths (leading `/`)
    * backslashes (Windows separators that sidestep `/`-based checks)
    * over-long names and trees: a segment past 240 bytes (POSIX
      NAME_MAX is 255; the margin covers the Local adapter's `.tmp.<n>`
      rename suffix), more than 32 segments, or a joined path past
      1024 bytes — one ceiling for both adapters, so a path S3 would
      store cannot be one Local `:enametoolong`s on

  Everything here rejects-more than either previous validator; no legitimate
  relative storage path is affected.

  No unicode normalization happens here — this module validates, it never
  transforms, and the layer stores exactly the bytes it is given. The one
  ingress of user-chosen names (`Prism.Attachments.safe_filename/1`)
  NFC-normalizes before the bytes get here.
  """

  @max_segment_bytes 240
  @max_depth 32
  @max_path_bytes 1024

  @doc """
  Validate a list of path segments. Raises `ArgumentError` on the first
  unsafe segment. Returns `:ok`.
  """
  @spec validate_segments!([String.t()]) :: :ok
  def validate_segments!(segments) when is_list(segments) do
    case validate_segments(segments) do
      :ok -> :ok
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc """
  Validate a list of path segments. Returns `:ok` or `{:error, message}` —
  the same denylist as `validate_segments!/1`, for callers whose contract
  answers rather than raises (`Arca.exists?/2`).
  """
  @spec validate_segments([String.t()]) :: :ok | {:error, String.t()}
  def validate_segments(segments) when is_list(segments) do
    with :ok <- check_shape(segments) do
      Enum.reduce_while(segments, :ok, fn segment, :ok ->
        case check_segment(segment) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
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
      |> validate_segments()
    end
  end

  # The length/depth ceilings, checked once per path rather than per
  # segment. Non-binary members don't count bytes here — check_segment/1
  # refuses them with its own message.
  defp check_shape(segments) do
    total =
      Enum.reduce(segments, 0, fn
        segment, acc when is_binary(segment) -> acc + byte_size(segment)
        _segment, acc -> acc
      end) + max(length(segments) - 1, 0)

    cond do
      length(segments) > @max_depth ->
        {:error, "Path rejected: more than #{@max_depth} segments"}

      total > @max_path_bytes ->
        {:error, "Path rejected: longer than #{@max_path_bytes} bytes"}

      true ->
        :ok
    end
  end

  defp check_segment(segment) when is_binary(segment) do
    decoded = fully_decode(segment)

    cond do
      segment == "" ->
        {:error, "Path rejected: empty segments are not allowed"}

      segment in [".", ".."] ->
        {:error, "Path traversal rejected: segment #{inspect(segment)} is not allowed"}

      String.contains?(segment, <<0>>) ->
        {:error, "Path traversal rejected: null bytes are not allowed"}

      String.contains?(segment, "\\") ->
        {:error, "Path traversal rejected: backslashes are not allowed"}

      String.starts_with?(segment, "/") ->
        {:error, "Path traversal rejected: absolute segments are not allowed"}

      decoded in [".", ".."] or decoded =~ ~r/(^|[\/\\])\.\.($|[\/\\])/ ->
        {:error, "Path traversal rejected: encoded dot segments are not allowed"}

      byte_size(segment) > @max_segment_bytes ->
        {:error, "Path rejected: segment longer than #{@max_segment_bytes} bytes"}

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
