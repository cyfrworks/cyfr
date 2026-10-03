# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ComponentPath do
  @moduledoc """
  The component tree's layout, as every side that names a version
  directory agrees on it:

      components/{type}s/{publisher}/{name}/{version}/

  The segments are tenant-relative — which athanor's tree they land in is
  decided by the actor handed to `Arca`, never by the path — so the shape
  is data two sides share and nothing more. The component domain spells it
  `Compendium.ComponentPath`, which adds the parsing, the artifact names
  and the unit locator and delegates the shape here; the identity domain
  reads it here to say which directory a consent or a tincture grant
  covers, and the storage layer to read the publisher of a unit the
  grammar located. Which paths a storage grant admits is read here too
  (`path_granted?/2`), by the boundary that enforces it and by every
  reader of a grant.

  Vocabulary note: paths and the components table say `publisher`;
  references and identity (`Prima.ComponentRef`) say `namespace` — the
  SAME value under two names, one per vocabulary. `normalize_publisher/1`
  and `default_publisher/0` are the bridge.
  """

  @default_publisher "local"
  @components_root "components"

  @doc ~s|Root prefix segments: `["components"]` — the context's athanor's tree.|
  @spec base_prefix() :: [String.t()]
  def base_prefix, do: [@components_root]

  @doc """
  The default publisher segment — the `local` namespace every
  locally-built and bundled component ships under. The one spelling;
  callers that need the literal read it here.

  ## Examples

      iex> Prima.ComponentPath.default_publisher()
      "local"

  """
  @spec default_publisher() :: String.t()
  def default_publisher, do: @default_publisher

  @doc """
  Canonical publisher segment default. `nil`/`""` collapse to the seeded
  `local` namespace, so a component's path and its id never disagree
  about an absent publisher.

  ## Examples

      iex> Prima.ComponentPath.normalize_publisher(nil)
      "local"

      iex> Prima.ComponentPath.normalize_publisher("moonmoon69")
      "moonmoon69"

  """
  @spec normalize_publisher(String.t() | nil) :: String.t()
  def normalize_publisher(publisher) when is_binary(publisher) and publisher != "", do: publisher
  def normalize_publisher(_), do: @default_publisher

  @doc """
  Whether a publisher segment names the local namespace — the
  highest-trust namespace, which only locally-built and bundled
  components may enter.

  ## Examples

      iex> Prima.ComponentPath.local_publisher?("local")
      true

      iex> Prima.ComponentPath.local_publisher?("moonmoon69")
      false

      iex> Prima.ComponentPath.local_publisher?(nil)
      true

  """
  @spec local_publisher?(String.t() | nil) :: boolean()
  def local_publisher?(publisher), do: normalize_publisher(publisher) == @default_publisher

  @doc """
  The plural directory name for a component type — the one
  pluralization rule.

  ## Examples

      iex> Prima.ComponentPath.type_plural("catalyst")
      "catalysts"

  """
  @spec type_plural(String.t()) :: String.t()
  def type_plural(type) when is_binary(type), do: type <> "s"

  @doc """
  The inverse of `type_plural/1` — the one de-pluralization, so the OCI
  repository convention and the on-disk layout cannot each spell it.

  ## Examples

      iex> Prima.ComponentPath.singular("catalysts")
      "catalyst"

  """
  @spec singular(String.t()) :: String.t()
  def singular(type_plural) when is_binary(type_plural),
    do: String.trim_trailing(type_plural, "s")

  @doc """
  Path segments to a component version directory — the shadow unit an
  overlay classifies and a consent covers.

  ## Examples

      iex> Prima.ComponentPath.version_dir("tincture", nil, "widget", "1.0.0")
      ["components", "tinctures", "local", "widget", "1.0.0"]

  """
  @spec version_dir(String.t(), String.t() | nil, String.t(), String.t()) :: [String.t()]
  def version_dir(type, publisher, name, version) do
    base_prefix() ++ [type_plural(type), normalize_publisher(publisher), name, version]
  end

  @doc """
  The publisher segment of a path in the component tree, at or below a
  publisher directory: the segment `version_dir/4` lays out after the
  type plural. `:error` for a path outside the tree or above that depth.

  This reads the layout's positions and nothing more. Whether the type,
  publisher, name and version are ones the layout accepts is the
  component domain's grammar (`Compendium.ComponentPath.parse/1`); a
  layer below it reads the publisher of a unit that grammar located
  (`Arca.Storage.locate/1`), as both storage doors' fork-to-modify rule
  (`Prima.ComponentNamespace`) does.

  ## Examples

      iex> Prima.ComponentPath.publisher(["components", "catalysts", "acme", "tool", "1.0.0"])
      {:ok, "acme"}

      iex> Prima.ComponentPath.publisher(["components", "catalysts"])
      :error

      iex> Prima.ComponentPath.publisher(["aqua", "skills", "tidy"])
      :error

  """
  @spec publisher([String.t()]) :: {:ok, String.t()} | :error
  def publisher([@components_root, _type_plural, publisher | _rest]), do: {:ok, publisher}
  def publisher(_segments), do: :error

  @doc """
  Whether a storage grant's `paths` (`Prima.Authority.Blob.Edge.paths/1`)
  admit `path`: the one reading of a storage grant, which the storage
  boundary enforces (`Crucible.GuestStorage`) and every reader of a grant
  shares, so no reader shows a grant wider or narrower than it is.

  `"*"` admits every path. A grant ending in `/` is a prefix: it admits
  every path it prefixes, and the bare directory it names, since a listing
  names the directory without its slash. Any other grant admits exactly
  the path it spells. An empty list admits nothing.

  Both sides compare as spelled, byte for byte: nothing here trims an
  empty segment or resolves a `..`. Whether `path` is a safe guest path
  is the caller's check, made before this one (`Prima.PathSafety`).

  ## Examples

      iex> Prima.ComponentPath.path_granted?("data/notes/today.md", ["data/notes/"])
      true

      iex> Prima.ComponentPath.path_granted?("data/notes", ["data/notes/"])
      true

      iex> Prima.ComponentPath.path_granted?("data/notesheet.md", ["data/notes/"])
      false

      iex> Prima.ComponentPath.path_granted?("data/report.md", ["data/report.md"])
      true

      iex> Prima.ComponentPath.path_granted?("components/catalysts/local/x/1.0.0/a", ["*"])
      true

      iex> Prima.ComponentPath.path_granted?("data/report.md", [])
      false

  """
  @spec path_granted?(String.t(), [String.t()]) :: boolean()
  def path_granted?(path, grants) when is_binary(path) and is_list(grants) do
    with_slash = if String.ends_with?(path, "/"), do: path, else: path <> "/"
    Enum.any?(grants, &grant_admits?(&1, path, with_slash))
  end

  def path_granted?(_path, _grants), do: false

  @doc """
  A path as the storage door spells one: its segments with the empty ones
  trimmed, joined by `/`, a folder keeping its trailing `/`. `nil` for a
  path that names no segment, an absolute one, or one the door's path
  check refuses (`Prima.PathSafety.validate_relative_path/1`).

  The one spelling a person is offered a path in, and a grant pattern is
  read through: the door reaches the physical path with its empty
  segments trimmed, so a path picked or a call's argument offered in this
  spelling is the one a later call is matched against.

  ## Examples

      iex> Prima.ComponentPath.door_path("data//notes/")
      "data/notes/"

      iex> Prima.ComponentPath.door_path("data/notes/today.md")
      "data/notes/today.md"

      iex> Prima.ComponentPath.door_path("/etc/passwd")
      nil

      iex> Prima.ComponentPath.door_path("data/../secrets")
      nil

  """
  @spec door_path(term()) :: String.t() | nil
  def door_path("/" <> _absolute), do: nil

  def door_path(path) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      [] ->
        nil

      segments ->
        if Prima.PathSafety.validate_relative_path(path) == :ok do
          joined = Enum.join(segments, "/")
          if String.ends_with?(path, "/"), do: joined <> "/", else: joined
        end
    end
  end

  def door_path(_path), do: nil

  defp grant_admits?("*", _path, _with_slash), do: true

  defp grant_admits?(grant, path, with_slash) when is_binary(grant) do
    if String.ends_with?(grant, "/"),
      do: String.starts_with?(path, grant) or String.starts_with?(with_slash, grant),
      else: path == grant or with_slash == grant
  end

  defp grant_admits?(_grant, _path, _with_slash), do: false
end
