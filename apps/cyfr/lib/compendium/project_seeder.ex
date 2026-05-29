# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ProjectSeeder do
  @moduledoc """
  Seed a newly created project with the bundled components.

  Component storage is project-scoped (`components/{org}/{project}/...`), so a
  brand-new project starts empty. To avoid that, the bundled `local`-publisher
  components shipped under the seeded `local/default` workspace are copied into
  the new tenant and registered, giving every project a working baseline (the
  `http`/`files` catalysts, the `aqua`/`list-models` formulas, sample tinctures
  — whatever ships under `local/default`).

  Seeding is best-effort: a failure is logged but never blocks project
  creation. It is idempotent — re-seeding copies identical bytes and the
  rescan reports the components as unchanged.
  """

  require Logger

  alias Compendium.{AutoIndexer, ComponentPath}

  @bundled_publisher "local"

  @doc """
  Seed the project described by an `Arca.Schemas.Project` (or any map exposing
  `:org_id` and `:id`).
  """
  def seed_project(%{org_id: org_id, id: project_id}) do
    seed(%{org_id: org_id, project_id: project_id})
  end

  @doc """
  Seed the tenant `%{org_id, project_id}` with the bundled component set.

  Returns `:ok`, `{:ok, :is_seed_source}` when the target *is* the bundle
  source (`local/default`), or `{:error, reason}` on a copy failure.
  """
  def seed(%{org_id: org_id, project_id: project_id} = target) do
    source = {Arca.Tenant.local_org(), Arca.Tenant.default_project()}

    if {normalize_org(org_id), normalize_proj(project_id)} == source do
      # local/default is the bundle itself — nothing to copy into it.
      {:ok, :is_seed_source}
    else
      ctx =
        Sanctum.internal_context(
          user_id: "_seed",
          org_id: org_id,
          project_id: project_id
        )

      with :ok <- copy_bundled(ctx, source, target) do
        # Register DB rows for the copied blobs under the new tenant. The scan
        # is scoped to this ctx's tenant, so it only touches the new project.
        AutoIndexer.scan(ctx: ctx)
        :ok
      end
    end
  rescue
    e ->
      Logger.warning(
        "[ProjectSeeder] Failed to seed #{org_id}/#{project_id}: #{Exception.message(e)}"
      )

      {:error, :seed_failed}
  end

  defp copy_bundled(ctx, source, target) do
    Enum.reduce_while(ComponentPath.type_plurals(), :ok, fn type_plural, :ok ->
      src = ComponentPath.base_prefix(source) ++ [type_plural, @bundled_publisher]
      dest = ComponentPath.base_prefix(target) ++ [type_plural, @bundled_publisher]

      case Arca.copy_tree(ctx, src, dest) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_org(org), do: Arca.QueryHelpers.normalize_org_id(org)
  defp normalize_proj(proj), do: Arca.QueryHelpers.normalize_project_id(proj)
end
