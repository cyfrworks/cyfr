# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ComponentPath do
  @moduledoc """
  Centralized path segment construction for component storage.

  Produces Arca path segments (a list of strings) that are tenant-scoped, in
  lock-step with the `data/{org}/{project}/...` layout used for runtime data:

      components/{org_id}/{project_id}/{type}s/{publisher}/{name}/{version}/

  Every function takes a `tenant` — a `%Sanctum.Context{}`, a component row/map
  (anything exposing `:org_id` and `:project_id`), or an explicit
  `{org_id, project_id}` tuple. The tenant must be resolved: an absent
  org/project raises, exactly like `Arca.Storage.tenant_segments/1` for the
  `data/` tree, so an unresolved context can never land in the shared seeded
  `local/default` workspace. The `publisher` segment is normalized through
  `normalize_publisher/1` (`nil`/`""` collapse to the seeded `local`
  namespace). So this module is the single chokepoint for component-path
  tenancy *and* publisher defaulting — there is exactly one on-disk layout,
  no flat fallback, and the segment can never diverge from the id minted by
  `Compendium.ComponentId`.
  """

  @type_plurals ["catalysts", "reagents", "formulas", "tinctures"]

  @default_publisher "local"

  @type tenant ::
          %{org_id: String.t(), project_id: String.t()}
          | {String.t(), String.t()}

  @doc "Root prefix segments: `[\"components\", org_id, project_id]` (requires a resolved tenant)."
  @spec base_prefix(tenant()) :: [String.t()]
  def base_prefix(%{org_id: org_id, project_id: project_id}),
    do: prefix(org_id, project_id)

  def base_prefix({org_id, project_id}), do: prefix(org_id, project_id)

  defp prefix(org_id, project_id)
       when is_binary(org_id) and org_id != "" and is_binary(project_id) and project_id != "" do
    ["components", org_id, project_id]
  end

  defp prefix(org_id, project_id) do
    raise ArgumentError,
          "Compendium.ComponentPath: a resolved org_id/project_id is required " <>
            "(got org_id=#{inspect(org_id)} project_id=#{inspect(project_id)})"
  end

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
  the seeder copies into every new project — so only locally-built
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
  @spec version_dir(String.t(), String.t() | nil, String.t(), String.t(), tenant()) :: [
          String.t()
        ]
  def version_dir(type, publisher, name, version, tenant) do
    base_prefix(tenant) ++ ["#{type}s", normalize_publisher(publisher), name, version]
  end

  @doc "Path segments to the WASM binary for a component."
  @spec wasm_path(String.t(), String.t() | nil, String.t(), String.t(), tenant()) :: [String.t()]
  def wasm_path(type, publisher, name, version, tenant) do
    version_dir(type, publisher, name, version, tenant) ++ ["#{type}.wasm"]
  end

  @doc "Path segments to an arbitrary file in a component version directory."
  @spec file_path(String.t(), String.t() | nil, String.t(), String.t(), String.t(), tenant()) ::
          [String.t()]
  def file_path(type, publisher, name, version, filename, tenant) do
    version_dir(type, publisher, name, version, tenant) ++ [filename]
  end

  @doc "Path segments to a component name directory (parent of version dirs)."
  @spec name_dir(String.t(), String.t() | nil, String.t(), tenant()) :: [String.t()]
  def name_dir(type, publisher, name, tenant) do
    base_prefix(tenant) ++ ["#{type}s", normalize_publisher(publisher), name]
  end

  @doc "Path segments to a publisher directory."
  @spec publisher_dir(String.t(), String.t() | nil, tenant()) :: [String.t()]
  def publisher_dir(type, publisher, tenant) do
    base_prefix(tenant) ++ ["#{type}s", normalize_publisher(publisher)]
  end

  @doc "Known type plural strings."
  def type_plurals, do: @type_plurals
end
