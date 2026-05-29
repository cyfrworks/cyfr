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
  `{org_id, project_id}` tuple. The org/project are normalized through
  `Arca.QueryHelpers` (`nil`/`""` collapse to the seeded `local`/`default`
  sentinels), so this module is the single chokepoint for component-path
  tenancy — there is exactly one on-disk layout and no flat fallback.
  """

  alias Arca.QueryHelpers

  @type_plurals ["catalysts", "reagents", "formulas", "tinctures"]

  @type tenant ::
          %{org_id: String.t() | nil, project_id: String.t() | nil}
          | {String.t() | nil, String.t() | nil}

  @doc "Root prefix segments: `[\"components\", org_id, project_id]` (normalized)."
  @spec base_prefix(tenant()) :: [String.t()]
  def base_prefix(%{org_id: org_id, project_id: project_id}),
    do: prefix(org_id, project_id)

  def base_prefix({org_id, project_id}), do: prefix(org_id, project_id)

  defp prefix(org_id, project_id) do
    ["components", QueryHelpers.normalize_org_id(org_id), QueryHelpers.normalize_project_id(project_id)]
  end

  @doc "Path segments to a component version directory."
  @spec version_dir(String.t(), String.t(), String.t(), String.t(), tenant()) :: [String.t()]
  def version_dir(type, publisher, name, version, tenant) do
    base_prefix(tenant) ++ ["#{type}s", publisher, name, version]
  end

  @doc "Path segments to the WASM binary for a component."
  @spec wasm_path(String.t(), String.t(), String.t(), String.t(), tenant()) :: [String.t()]
  def wasm_path(type, publisher, name, version, tenant) do
    version_dir(type, publisher, name, version, tenant) ++ ["#{type}.wasm"]
  end

  @doc "Path segments to an arbitrary file in a component version directory."
  @spec file_path(String.t(), String.t(), String.t(), String.t(), String.t(), tenant()) ::
          [String.t()]
  def file_path(type, publisher, name, version, filename, tenant) do
    version_dir(type, publisher, name, version, tenant) ++ [filename]
  end

  @doc "Path segments to a component name directory (parent of version dirs)."
  @spec name_dir(String.t(), String.t(), String.t(), tenant()) :: [String.t()]
  def name_dir(type, publisher, name, tenant) do
    base_prefix(tenant) ++ ["#{type}s", publisher, name]
  end

  @doc "Path segments to a publisher directory."
  @spec publisher_dir(String.t(), String.t(), tenant()) :: [String.t()]
  def publisher_dir(type, publisher, tenant) do
    base_prefix(tenant) ++ ["#{type}s", publisher]
  end

  @doc "Known type plural strings."
  def type_plurals, do: @type_plurals
end
