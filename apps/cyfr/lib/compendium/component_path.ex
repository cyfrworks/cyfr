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

  The seed bundle every athanor is provisioned from lives under the
  reserved `seed/components/{type}s/local/...` prefix (`Compendium.Bundle`)
  and is read in place from the seed tree (`:seed_path`), outside the
  storage root; it is bytes only and never a tenant.
  """

  @type_plurals Enum.map(Sanctum.ComponentRef.valid_types(), &(&1 <> "s"))

  @default_publisher "local"

  @doc "Root prefix segments: `[\"components\"]` — the context's athanor's tree."
  @spec base_prefix() :: [String.t()]
  def base_prefix, do: ["components"]

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
  `local` is the highest-trust namespace — the tree the scanner indexes and
  the seeder copies into every new athanor — so only locally-built
  components may enter it. Remote ingress (OCI pull) must refuse it, and
  directory registration accepts only it.

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

  @doc "Path segments to a component version directory."
  @spec version_dir(String.t(), String.t() | nil, String.t(), String.t()) :: [String.t()]
  def version_dir(type, publisher, name, version) do
    base_prefix() ++ ["#{type}s", normalize_publisher(publisher), name, version]
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
    base_prefix() ++ ["#{type}s", normalize_publisher(publisher), name]
  end

  @doc "Path segments to a publisher directory."
  @spec publisher_dir(String.t(), String.t() | nil) :: [String.t()]
  def publisher_dir(type, publisher) do
    base_prefix() ++ ["#{type}s", normalize_publisher(publisher)]
  end

  @doc "Known type plural strings."
  def type_plurals, do: @type_plurals
end
