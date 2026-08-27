# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ComponentPath do
  @moduledoc """
  Centralized path segment construction for component storage.

  Produces tenant-relative Arca path segments (a list of strings):

      components/{type}s/{publisher}/{name}/{version}/

  These are logical segments — `Arca.Storage.physical_segments/2` maps them
  under the *context's* athanor (`athanors/{athanor_id}/components/...`), so
  the paths carry no tenant: which athanor's tree they land in is decided by
  the context handed to `Arca`, exactly like the data tree, and naming
  another athanor's components is structurally impossible. The `publisher`
  segment is normalized through `normalize_publisher/1` (`nil`/`""` collapse
  to the `local` namespace), so this module is the single chokepoint for
  component-path shape *and* publisher defaulting — there is exactly one
  layout, and the segment can never diverge from the id minted by
  `Compendium.ComponentId`.

  The seed bundle every athanor reads through lives under the reserved
  `seed/components/{type}s/local/...` prefix
  (`Arca.Storage.seed_prefix("components")`) and is read in place from the
  seed tree (`:seed_path`), outside the storage root; it is bytes only and
  never a tenant.

  Vocabulary note: paths and the components table say `publisher`;
  references and identity (`Sanctum.ComponentRef`) say `namespace` — the
  SAME value under two names, one per vocabulary. This module's
  `normalize_publisher/1` / `default_publisher/0` are the bridge.
  """

  @behaviour Arca.Storage.UnitLocator

  @type_plurals Enum.map(Sanctum.ComponentRef.valid_types(), &(&1 <> "s"))

  @default_publisher "local"

  @manifest_name "cyfr-manifest.json"

  @components_root "components"

  # components/{type}s/{publisher}/{name}/{version} — the shadow unit is
  # the version directory, `version_dir/4`'s exact shape.
  @unit_depth 5

  @doc "Root prefix segments: `[\"components\"]` — the context's athanor's tree."
  @spec base_prefix() :: [String.t()]
  def base_prefix, do: [@components_root]

  @doc """
  Parse tenant-relative component segments against the one layout — the
  inverse of `version_dir/4`. `{:ok, parts}` for a path at or below a
  version directory under a known type plural (`rest` is what follows the
  version — `[]` for the version directory itself, `[filename]` for a
  file in it); `:error` for anything else. The registration, scan and
  tincture-index guards all speak through this one parser, so the
  five-segment shape is never re-stated as a pattern elsewhere.

  ## Examples

      iex> Compendium.ComponentPath.parse(["components", "catalysts", "local", "files", "0.5.0"])
      {:ok, %{type: "catalyst", publisher: "local", name: "files", version: "0.5.0", rest: []}}

      iex> Compendium.ComponentPath.parse(["components", "not-a-type", "local", "x", "1.0.0"])
      :error

  """
  @spec parse([String.t()]) ::
          {:ok,
           %{
             type: String.t(),
             publisher: String.t(),
             name: String.t(),
             version: String.t(),
             rest: [String.t()]
           }}
          | :error
  def parse([@components_root, type_plural, publisher, name, version | rest])
      when type_plural in @type_plurals do
    with :ok <- Sanctum.ComponentRef.validate_namespace(publisher),
         :ok <- Sanctum.ComponentRef.validate_name(name),
         :ok <- Sanctum.ComponentRef.validate_version(version) do
      {:ok,
       %{
         type: String.trim_trailing(type_plural, "s"),
         publisher: publisher,
         name: name,
         version: version,
         rest: rest
       }}
    else
      {:error, _} -> :error
    end
  end

  def parse(_segments), do: :error

  @doc """
  Filter walked leaves down to manifest files — the discovery filter the
  component scanners share (`Compendium.AutoIndexer`,
  `Prism.TinctureRegistry`).
  """
  @spec manifest_leaves([[String.t()]]) :: [[String.t()]]
  def manifest_leaves(leaves), do: Enum.filter(leaves, &(List.last(&1) == @manifest_name))

  @doc """
  The manifest's filename — the one file every valid version directory
  carries, which is why `locate/1` names it the overlay sentinel.

  ## Examples

      iex> Compendium.ComponentPath.manifest_name()
      "cyfr-manifest.json"

  """
  @spec manifest_name() :: String.t()
  def manifest_name, do: @manifest_name

  @doc """
  The overlay's unit grammar for `components/`
  (`Arca.Storage.UnitLocator`): every path at or below a version
  directory that `parse/1` accepts belongs to that directory-shaped
  unit, sentinel'd by the manifest; anything else is above the units.
  A unit is a claim the storage layer acts on — copy-on-write, origin
  marks, status — so only the grammar mints one: a junk five-segment
  shape stays plain storage, never a CoW'd, quota-charged phantom unit.

  ## Examples

      iex> Compendium.ComponentPath.locate(["components", "catalysts", "local", "files", "0.5.0", "src", "lib.rs"])
      {:dir, ["components", "catalysts", "local", "files", "0.5.0"], "cyfr-manifest.json"}

      iex> Compendium.ComponentPath.locate(["components", "catalysts"])
      :above_unit

      iex> Compendium.ComponentPath.locate(["components", "junk", "a", "b", "not-semver"])
      :above_unit

  """
  @impl Arca.Storage.UnitLocator
  def locate(path) do
    case parse(path) do
      {:ok, _parts} -> {:dir, Enum.take(path, @unit_depth), @manifest_name}
      :error -> :above_unit
    end
  end

  @doc "Path segments to a component version's manifest."
  @spec manifest_path(String.t(), String.t() | nil, String.t(), String.t()) :: [String.t()]
  def manifest_path(type, publisher, name, version) do
    version_dir(type, publisher, name, version) ++ [@manifest_name]
  end

  @doc """
  Path segments to a component's stored artifact — the version directory
  for a tincture (its artifact is the directory-shaped bundle), the
  `.wasm` file for every other type. The one home for that type-shaped
  distinction.

  ## Examples

      iex> Compendium.ComponentPath.artifact_path("tincture", "local", "widget", "1.0.0")
      ["components", "tinctures", "local", "widget", "1.0.0"]

      iex> Compendium.ComponentPath.artifact_path("catalyst", "local", "files", "0.5.0")
      ["components", "catalysts", "local", "files", "0.5.0", "catalyst.wasm"]

  """
  @spec artifact_path(String.t(), String.t() | nil, String.t(), String.t()) :: [String.t()]
  def artifact_path("tincture", publisher, name, version),
    do: version_dir("tincture", publisher, name, version)

  def artifact_path(type, publisher, name, version),
    do: wasm_path(type, publisher, name, version)

  @doc """
  The default publisher segment — the `local` namespace every locally-built
  and bundled component ships under. The one spelling; callers that need
  the literal read it here.

  ## Examples

      iex> Compendium.ComponentPath.default_publisher()
      "local"

  """
  @spec default_publisher() :: String.t()
  def default_publisher, do: @default_publisher

  @doc """
  Canonical publisher segment default. `nil`/`""` collapse to the seeded
  `local` namespace — the same default `Compendium.ComponentId` applies, so a
  component's path and its id never disagree about an absent publisher.
  """
  @spec normalize_publisher(String.t() | nil) :: String.t()
  def normalize_publisher(publisher) when is_binary(publisher) and publisher != "", do: publisher
  def normalize_publisher(_), do: @default_publisher

  @doc """
  Whether a publisher segment names the local namespace.

  The single source of truth for a distinction several gates depend on:
  `local` is the highest-trust namespace — the tree the scanner indexes,
  where the seed bundle shows through the overlay — so only locally-built
  and bundled components may enter it. Remote ingress (OCI pull) must
  refuse it, and directory registration accepts only it.

  ## Examples

      iex> Compendium.ComponentPath.local_publisher?("local")
      true

      iex> Compendium.ComponentPath.local_publisher?("moonmoon69")
      false

      iex> Compendium.ComponentPath.local_publisher?(nil)
      true

  """
  @spec local_publisher?(String.t() | nil) :: boolean()
  def local_publisher?(publisher), do: normalize_publisher(publisher) == @default_publisher

  @doc """
  The plural directory name for a component type — the one pluralization
  rule.

  ## Examples

      iex> Compendium.ComponentPath.type_plural("catalyst")
      "catalysts"

  """
  @spec type_plural(String.t()) :: String.t()
  def type_plural(type) when is_binary(type), do: type <> "s"

  @doc "Path segments to a component version directory."
  @spec version_dir(String.t(), String.t() | nil, String.t(), String.t()) :: [String.t()]
  def version_dir(type, publisher, name, version) do
    base_prefix() ++ [type_plural(type), normalize_publisher(publisher), name, version]
  end

  @doc "Path segments to the WASM binary for a component."
  @spec wasm_path(String.t(), String.t() | nil, String.t(), String.t()) :: [String.t()]
  def wasm_path(type, publisher, name, version) do
    version_dir(type, publisher, name, version) ++ ["#{type}.wasm"]
  end

  @doc "Path segments to an arbitrary file in a component version directory."
  @spec file_path(String.t(), String.t() | nil, String.t(), String.t(), String.t()) ::
          [String.t()]
  def file_path(type, publisher, name, version, filename) do
    version_dir(type, publisher, name, version) ++ [filename]
  end

  @doc "Path segments to a component name directory (parent of version dirs)."
  @spec name_dir(String.t(), String.t() | nil, String.t()) :: [String.t()]
  def name_dir(type, publisher, name) do
    base_prefix() ++ [type_plural(type), normalize_publisher(publisher), name]
  end

  @doc "Path segments to a publisher directory."
  @spec publisher_dir(String.t(), String.t() | nil) :: [String.t()]
  def publisher_dir(type, publisher) do
    base_prefix() ++ [type_plural(type), normalize_publisher(publisher)]
  end

  @doc "Known type plural strings."
  def type_plurals, do: @type_plurals
end
