# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Catalogue do
  @moduledoc """
  The read-side shaping of catalogue rows for display surfaces: group the
  flat version rows the registry and the merged search return into
  per-component entries, newest first, with remote-only versions folded
  in. This is catalogue domain logic — semver ordering, remote merging,
  status defaulting — and it lives here so the console renders what the
  registry means rather than re-deriving it.

  Rows arrive in both key spellings (registry rows atom-keyed, search
  JSON string-keyed); `field/2` reads either.
  """

  @doc "Read `key` from a row that may be atom- or string-keyed."
  def field(row, key) when is_map(row), do: row[key] || row[to_string(key)]
  def field(_, _), do: nil

  @doc """
  Assemble a component reference from its parts:
  `("catalyst", "alice", "api", "1.0.0")` → `"catalyst:alice.api:1.0.0"`.
  Absent parts are omitted.
  """
  def build_ref(type, publisher, name, version) do
    base = if publisher && publisher != "", do: "#{publisher}.#{name}", else: name
    ref = if type && type != "", do: "#{type}:#{base}", else: base
    if version, do: "#{ref}:#{version}", else: ref
  end

  @doc """
  Group merged-search rows by `{name, publisher, type}`: one entry per
  component, all versions under it. The search response carries only the
  latest row per component plus its `remote_versions` list, so versions
  not held locally are folded in as `%{remote_only: true}` stubs.
  """
  def group_search_results(rows) do
    rows
    |> Enum.group_by(fn row ->
      {field(row, :name), field(row, :publisher) || field(row, :namespace_slug),
       field(row, :component_type)}
    end)
    |> Enum.map(fn {{name, publisher, type}, local_versions} ->
      sorted = Compendium.Semver.sort_desc_by(local_versions, &(field(&1, :version) || "0.0.0"))
      latest = hd(sorted)

      remote_vs = field(latest, :remote_versions) || []
      local_vs = MapSet.new(sorted, &field(&1, :version))

      remote_only =
        remote_vs
        |> Enum.reject(&MapSet.member?(local_vs, &1))
        |> Enum.map(fn v ->
          %{version: v, component_ref: build_ref(type, publisher, name, v), remote_only: true}
        end)

      all_versions =
        Compendium.Semver.sort_desc_by(sorted ++ remote_only, &(field(&1, :version) || "0.0.0"))

      %{
        name: name,
        publisher: Compendium.ComponentPath.normalize_publisher(publisher),
        component_type: type,
        description: field(latest, :description),
        latest: latest,
        versions: all_versions,
        version_count: length(all_versions),
        # Latest version's status (active|deprecated|yanked|taken_down).
        # Older rows + local-only entries may omit it; default to "active".
        # Callers render a status badge when != "active".
        status: field(latest, :status) || "active",
        status_reason: field(latest, :status_reason)
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Group locally installed rows by their name ref (the versionless
  spelling): one entry per component, versions newest first.
  """
  def group_by_component(rows) do
    rows
    |> Enum.group_by(fn row ->
      ref = field(row, :component_ref) || field(row, :id) || "-"

      case Sanctum.ComponentRef.to_name_ref(ref) do
        {:ok, nr} -> nr
        _ -> ref
      end
    end)
    |> Enum.map(fn {name_ref, versions} ->
      sorted = Compendium.Semver.sort_desc_by(versions, &(field(&1, :version) || "0.0.0"))
      latest = hd(sorted)

      %{
        name_ref: name_ref,
        latest: latest,
        versions: sorted,
        version_count: length(sorted),
        component_type: field(latest, :component_type) || "unknown",
        description: field(latest, :description)
      }
    end)
    |> Enum.sort_by(& &1.name_ref)
  end
end
