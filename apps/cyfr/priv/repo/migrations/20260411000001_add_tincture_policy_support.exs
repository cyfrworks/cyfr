# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.AddTincturePolicySupport do
  use Ecto.Migration

  def up do
    # Add is_public column to policies table
    alter table(:policies) do
      add :is_public, :boolean, null: false, default: false
    end

    # Migrate existing tincture_visibility rows into policy rows.
    # Each visibility record becomes a tincture policy with default rate_limit/timeout.
    execute("""
    INSERT INTO policies (id, component_ref, component_type, is_public, org_id, project_id,
                          rate_limit_requests, rate_limit_window_seconds, timeout,
                          max_memory_bytes, max_request_size, max_response_size,
                          allowed_domains, allowed_methods, allowed_tools, allowed_paths,
                          allowed_actions, allowed_private_ips,
                          batch_timeout, max_concurrent_tasks,
                          inserted_at, updated_at)
    SELECT
      'pol_tv_' || substr(id, 1, 13),
      'tincture:' || publisher || '.' || name,
      'tincture',
      is_public,
      org_id,
      project_id,
      100,
      60,
      '30s',
      67108864,
      1048576,
      5242880,
      '[]', '[]', '[]', '[]', '[]', '[]',
      '5m',
      10,
      inserted_at,
      updated_at
    FROM tincture_visibility
    WHERE NOT EXISTS (
      SELECT 1 FROM policies p
      WHERE p.component_ref = 'tincture:' || tincture_visibility.publisher || '.' || tincture_visibility.name
        AND p.org_id = tincture_visibility.org_id
        AND p.project_id = tincture_visibility.project_id
    )
    """)

    # Drop the old table
    drop table(:tincture_visibility)
  end

  def down do
    # Recreate tincture_visibility table
    create table(:tincture_visibility, primary_key: false) do
      add :id, :string, primary_key: true
      add :publisher, :string, null: false
      add :name, :string, null: false
      add :is_public, :boolean, null: false, default: false
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tincture_visibility, [:publisher, :name, :org_id, :project_id])

    # Remove is_public from policies
    alter table(:policies) do
      remove :is_public
    end
  end
end
