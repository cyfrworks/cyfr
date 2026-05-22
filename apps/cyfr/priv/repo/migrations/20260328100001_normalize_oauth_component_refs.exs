# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.NormalizeOauthComponentRefs do
  use Ecto.Migration

  @doc """
  Consolidate versioned OAuth component_refs to name-level (versionless).

  e.g. "catalyst:local.gmail:0.1.1" → "catalyst:local.gmail"

  If both a versioned and name-level row exist for the same
  (provider, org_id, project_id), the row with the latest updated_at wins.
  """

  def up do
    # Regex pattern: type:namespace.name:version (three colon-separated segments)
    # Name-level refs have only two segments: type:namespace.name
    #
    # Strategy:
    # 1. Find all versioned refs (component_ref LIKE '%:%:%' AND component_ref != '')
    # 2. Compute name-level ref by stripping ":version" suffix
    # 3. For conflicts, keep the row with latest updated_at
    # 4. Update or delete as needed

    rows =
      repo().query!("""
      SELECT id, provider, component_ref, org_id, project_id, updated_at
      FROM oauth_credentials
      WHERE component_ref != ''
      ORDER BY updated_at DESC
      """)

    # Group by (name_ref, provider, org_id, project_id)
    # For each group, keep the row with latest updated_at, delete/update the rest
    groups =
      rows.rows
      |> Enum.map(fn [id, provider, component_ref, org_id, project_id, updated_at] ->
        %{
          id: id,
          provider: provider,
          component_ref: component_ref,
          org_id: org_id,
          project_id: project_id,
          updated_at: updated_at,
          name_ref: strip_version(component_ref)
        }
      end)
      |> Enum.group_by(fn r -> {r.name_ref, r.provider, r.org_id, r.project_id} end)

    for {_key, group_rows} <- groups do
      # Already sorted by updated_at DESC from the query
      [winner | losers] = group_rows

      # Update winner to name-level if it's versioned
      if winner.component_ref != winner.name_ref do
        execute("""
        UPDATE oauth_credentials
        SET component_ref = '#{escape(winner.name_ref)}', updated_at = '#{winner.updated_at}'
        WHERE id = '#{escape(winner.id)}'
        """)
      end

      # Delete duplicates
      for loser <- losers do
        execute("""
        DELETE FROM oauth_credentials WHERE id = '#{escape(loser.id)}'
        """)
      end
    end
  end

  def down do
    # Cannot reverse — version information is lost
    :ok
  end

  # Strip version from "type:namespace.name:version" → "type:namespace.name"
  # Leaves already-versionless refs unchanged.
  defp strip_version(component_ref) do
    case String.split(component_ref, ":") do
      [type, namespace_name, _version] -> "#{type}:#{namespace_name}"
      _ -> component_ref
    end
  end

  defp escape(str), do: String.replace(str, "'", "''")
end
