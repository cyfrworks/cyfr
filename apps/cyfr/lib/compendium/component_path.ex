defmodule Compendium.ComponentPath do
  @moduledoc """
  Centralized path segment construction for component storage.

  Produces Arca path segments (list of strings) that are org-aware:

  - **Core** (`org_id = nil`): `components/{type}s/{publisher}/{name}/{version}/`
  - **Arx** (`org_id` set): `components/{org_id}/{type}s/{publisher}/{name}/{version}/`

  No collision risk: org_ids are UUIDs/slugs, never `catalysts`/`reagents`/`formulas`/`tinctures`.
  """

  @type_plurals ["catalysts", "reagents", "formulas", "tinctures"]

  @doc "Root prefix segments. Core: `[\"components\"]`, Arx: `[\"components\", org_id]`."
  def base_prefix(nil), do: ["components"]
  def base_prefix(org_id) when is_binary(org_id), do: ["components", org_id]

  @doc "Path segments to a component version directory."
  def version_dir(type, publisher, name, version, org_id \\ nil) do
    base_prefix(org_id) ++ ["#{type}s", publisher, name, version]
  end

  @doc "Path segments to the WASM binary for a component."
  def wasm_path(type, publisher, name, version, org_id \\ nil) do
    version_dir(type, publisher, name, version, org_id) ++ ["#{type}.wasm"]
  end

  @doc "Path segments to an arbitrary file in a component version directory."
  def file_path(type, publisher, name, version, filename, org_id \\ nil) do
    version_dir(type, publisher, name, version, org_id) ++ [filename]
  end

  @doc "Path segments to a component name directory (parent of version dirs)."
  def name_dir(type, publisher, name, org_id \\ nil) do
    base_prefix(org_id) ++ ["#{type}s", publisher, name]
  end

  @doc "Path segments to a publisher directory."
  def publisher_dir(type, publisher, org_id \\ nil) do
    base_prefix(org_id) ++ ["#{type}s", publisher]
  end

  @doc "Known type plural strings."
  def type_plurals, do: @type_plurals
end
