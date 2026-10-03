# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.TinctureUrl do
  @moduledoc """
  The shape of a tincture's URLs, written once here and composed, never
  spelled out again.

    * `/t/:athanor/:publisher/:name` — the tincture's public URL. Two
      sides agree on it: the console and the controller build the href a
      browser follows, the registry stores it on an entry, and the
      assistant's visibility tool tells a person where their tincture is.
      `:athanor` is the athanor's route segment: `@<namespace>` names a
      person's athanor, a bare slug a group's.
    * `/_s/:credential/*path` — a private tincture version's served file,
      under its asset credential (`Sanctum.TinctureAuth`). The credential
      names the person, the version and the window, so the path names
      nothing else; `path` is the file's path inside the version.

  `tests/fixtures/component_refs.json` pins the served-file grammar.
  """

  @asset_prefix "_s"

  # An asset credential is opaque and URL-safe: base64url segments joined
  # by dots. It never begins with a dot, so it can never read as `.` or
  # `..`, and it is bounded, so a path segment cannot carry a document.
  @credential ~r/\A[A-Za-z0-9_-][A-Za-z0-9_.-]{15,1023}\z/

  @doc """
  The canonical tincture path.

  Refuses an empty athanor segment in the head rather than building
  `/t//publisher/name`, which would route to a different thing.
  """
  @spec path(String.t(), String.t(), String.t()) :: String.t()
  def path(athanor_segment, publisher, name)
      when is_binary(athanor_segment) and athanor_segment != "" do
    "/t/#{athanor_segment}/#{publisher}/#{name}"
  end

  @doc "The first path segment of every served file under an asset credential."
  @spec asset_prefix() :: String.t()
  def asset_prefix, do: @asset_prefix

  @doc "Whether `credential` has the asset credential's grammar."
  @spec credential?(term()) :: boolean()
  def credential?(credential), do: is_binary(credential) and Regex.match?(@credential, credential)

  @doc """
  The path of the file `segments` (its path inside the version) under
  `credential`, each segment percent-encoded. Raises on a credential or a
  segment the grammar refuses, since a caller builds this from a
  credential it minted and a path it read.
  """
  @spec asset_path(String.t(), [String.t()]) :: String.t()
  def asset_path(credential, segments) when is_list(segments) do
    unless credential?(credential),
      do: raise(ArgumentError, "an asset credential is opaque, URL-safe and bounded")

    unless segments != [] and Enum.all?(segments, &segment?/1),
      do: raise(ArgumentError, "a served file's path is one or more plain segments")

    encoded = Enum.map(segments, fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)
    "/" <> Enum.join([@asset_prefix, credential | encoded], "/")
  end

  @doc """
  A served-file path's credential and its file segments, from the request
  path's segments (as a router splits them, decoded) or from a path
  string. `:error` for another prefix, a credential outside the grammar,
  no file, or a segment that is empty, `.`, `..`, or carries a separator
  or a NUL.
  """
  @spec parse_asset_path(String.t() | [String.t()]) ::
          {:ok, %{credential: String.t(), path: [String.t()]}} | :error
  def parse_asset_path("/" <> path) do
    path
    |> String.split("/")
    |> Enum.map(&URI.decode/1)
    |> parse_asset_path()
  rescue
    ArgumentError -> :error
  end

  def parse_asset_path([@asset_prefix, credential | rest]) when rest != [] do
    if credential?(credential) and Enum.all?(rest, &segment?/1),
      do: {:ok, %{credential: credential, path: rest}},
      else: :error
  end

  def parse_asset_path(_path), do: :error

  defp segment?(segment) do
    is_binary(segment) and segment not in ["", ".", ".."] and
      not String.contains?(segment, ["/", "\\", <<0>>])
  end
end
