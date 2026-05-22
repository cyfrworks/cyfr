# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.SeedAndBackfillLocalOrg do
  @moduledoc """
  Seed the single-user `"local"` org and `"default"` project, then
  backfill `org_id = "local"` (and `project_id = "default"`) on every
  tenant-scoped row that still carries the legacy empty-string sentinel.

  Atomically idempotent: re-running is a no-op. Uses `on_conflict: :nothing`
  for the seeds and `WHERE org_id IN ('', NULL)` for the backfills.

  After this migration, every authenticated `Sanctum.Context` carries a
  resolved `org_id` (single-user installs use `"local"`; multi-tenant
  deployments mint real ids), unifying the tenancy model.
  """

  use Ecto.Migration

  @tenant_tables ~w(
    api_keys
    component_dependencies
    components
    cron_schedules
    executions
    mcp_logs
    mcp_servers
    oauth_credentials
    permissions
    policies
    policy_logs
    secret_grants
    secrets
    sessions
    webhooks
  )

  def up do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Seed the "local" org. on_conflict ensures multi-pod boots don't race.
    execute(fn ->
      repo().insert_all(
        "orgs",
        [
          %{
            id: "local",
            name: "Local",
            slug: "local",
            plan: "free",
            created_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: :id
      )
    end)

    # Seed the "default" project under the "local" org.
    execute(fn ->
      repo().insert_all(
        "projects",
        [
          %{
            id: "default",
            org_id: "local",
            name: "Default",
            slug: "default",
            settings: nil,
            created_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: :id
      )
    end)

    # Backfill every tenant-scoped table. Empty-string and NULL both map
    # to the "local" sentinel. project_id defaults to "default" where
    # null/empty so the strict tenancy policy has a real value to verify.
    for table <- @tenant_tables do
      execute("""
      UPDATE #{table}
      SET org_id = 'local'
      WHERE org_id IS NULL OR org_id = ''
      """)

      # `executions` is the only table with a nullable project_id today;
      # leaving the broad UPDATE for safety as more tables gain nullability.
      execute("""
      UPDATE #{table}
      SET project_id = 'default'
      WHERE project_id IS NULL OR project_id = ''
      """)
    end
  end

  def down do
    # Reverse the backfill (does NOT remove the seed rows — orgs/projects
    # rows are harmless to leave). Restores the legacy "" sentinel so an
    # older binary can boot against this DB.
    for table <- @tenant_tables do
      execute("""
      UPDATE #{table}
      SET org_id = ''
      WHERE org_id = 'local'
      """)
    end
  end
end
