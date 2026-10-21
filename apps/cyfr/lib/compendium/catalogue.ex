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

  Rows are the atom-keyed rows of a tool result: the local registry's and
  cyfr.run's (`Compendium.Registry.Client`), which name the publisher
  `publisher` alike.
  """

  # A component reference from its parts:
  # `("catalyst", "alice", "api", "1.0.0")` → `"catalyst:alice.api:1.0.0"`,
  # through the one constructor (`Prima.ComponentRef.build/4`). An absent
  # publisher normalizes to `local`, since the parser refuses a ref with
  # no namespace.
  defp build_ref(type, publisher, name, version) do
    Prima.ComponentRef.build(
      type,
      Compendium.ComponentPath.normalize_publisher(presence(publisher)),
      name,
      version
    )
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  @doc """
  Group merged-search rows by `{name, publisher, type}`: one entry per
  component, all versions under it. The search response carries only the
  latest row per component plus its `remote_versions` list, so versions
  not held locally are folded in as `%{remote_only: true}` stubs.
  """
  def group_search_results(rows) do
    rows
    |> Enum.group_by(fn row ->
      {row[:name], row[:publisher], row[:component_type]}
    end)
    |> Enum.map(fn {{name, publisher, type}, local_versions} ->
      sorted = Compendium.Semver.sort_desc_by(local_versions, &(&1[:version] || "0.0.0"))
      latest = hd(sorted)

      remote_vs = latest[:remote_versions] || []
      local_vs = MapSet.new(sorted, & &1[:version])

      remote_only =
        remote_vs
        |> Enum.reject(&MapSet.member?(local_vs, &1))
        |> Enum.map(fn v ->
          %{version: v, component_ref: build_ref(type, publisher, name, v), remote_only: true}
        end)

      all_versions =
        Compendium.Semver.sort_desc_by(sorted ++ remote_only, &(&1[:version] || "0.0.0"))

      %{
        name: name,
        publisher: Compendium.ComponentPath.normalize_publisher(publisher),
        component_type: type,
        description: latest[:description],
        latest: latest,
        versions: all_versions,
        version_count: length(all_versions),
        # Latest version's status (active|deprecated|yanked|taken_down):
        # cyfr.run's, or "active" for a local row, which carries none.
        # Callers render a status badge when != "active".
        status: latest[:status] || "active",
        status_reason: latest[:status_reason]
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
      ref = row[:component_ref] || row[:id] || "-"

      case Prima.ComponentRef.to_name_ref(ref) do
        {:ok, nr} -> nr
        _ -> ref
      end
    end)
    |> Enum.map(fn {name_ref, versions} ->
      sorted = Compendium.Semver.sort_desc_by(versions, &(&1[:version] || "0.0.0"))
      latest = hd(sorted)

      %{
        name_ref: name_ref,
        latest: latest,
        versions: sorted,
        version_count: length(sorted),
        component_type: latest[:component_type] || "unknown",
        description: latest[:description]
      }
    end)
    |> Enum.sort_by(& &1.name_ref)
  end
end
