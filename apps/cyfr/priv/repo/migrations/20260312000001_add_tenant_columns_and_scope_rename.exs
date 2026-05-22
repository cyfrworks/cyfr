# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.AddTenantColumnsAndScopeRename do
  use Ecto.Migration

  def up do
    # ============================================================================
    # Add tenant columns to tables that need them
    # ============================================================================

    # components — already has org_id, add project_id
    execute "UPDATE components SET org_id = '' WHERE org_id IS NULL"

    alter table(:components) do
      add :project_id, :string, null: false, default: "default"
    end

    drop_if_exists unique_index(:components, [:name, :version])
    create unique_index(:components, [:name, :version, :publisher, :org_id, :project_id])

    # api_keys — already has org_id, add project_id
    alter table(:api_keys) do
      add :project_id, :string, null: false, default: "default"
    end

    drop_if_exists unique_index(:api_keys, [:name, :scope_type])
    create unique_index(:api_keys, [:name, :scope_type, :org_id, :project_id])

    # permissions — already has org_id, add project_id
    alter table(:permissions) do
      add :project_id, :string, null: false, default: "default"
    end

    drop_if_exists unique_index(:permissions, [:subject, :scope_type])
    create unique_index(:permissions, [:subject, :scope_type, :org_id, :project_id])

    # secrets — already has org_id, add project_id
    execute "UPDATE secrets SET org_id = '' WHERE org_id IS NULL"

    alter table(:secrets) do
      add :project_id, :string, null: false, default: "default"
    end

    drop_if_exists unique_index(:secrets, [:name, :scope])
    create unique_index(:secrets, [:name, :scope, :org_id, :project_id])

    # secret_grants — already has org_id, add project_id
    execute "UPDATE secret_grants SET org_id = '' WHERE org_id IS NULL"

    alter table(:secret_grants) do
      add :project_id, :string, null: false, default: "default"
    end

    drop_if_exists unique_index(:secret_grants, [:secret_name, :component_ref])
    create unique_index(:secret_grants, [:secret_name, :component_ref, :org_id, :project_id])

    # cron_schedules — add both org_id and project_id
    alter table(:cron_schedules) do
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"
    end

    create index(:cron_schedules, [:org_id, :project_id])

    # mcp_logs — add both
    alter table(:mcp_logs) do
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"
    end

    create index(:mcp_logs, [:org_id, :project_id])

    # policy_logs — add both
    alter table(:policy_logs) do
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"
    end

    create index(:policy_logs, [:org_id, :project_id])

    # policies — add both, recreate unique index
    alter table(:policies) do
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"
    end

    drop_if_exists unique_index(:policies, [:component_ref])
    create unique_index(:policies, [:component_ref, :org_id, :project_id])

    # component_dependencies — add both
    alter table(:component_dependencies) do
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"
    end

    create index(:component_dependencies, [:org_id, :project_id])

    # ============================================================================
    # Scope rename: personal -> project
    # ============================================================================
    execute "UPDATE api_keys SET scope_type = 'project' WHERE scope_type = 'personal'"
    execute "UPDATE permissions SET scope_type = 'project' WHERE scope_type = 'personal'"
    execute "UPDATE secrets SET scope = 'project' WHERE scope = 'personal'"
    execute "UPDATE secret_grants SET scope = 'project' WHERE scope = 'personal'"
  end

  def down do
    # Reverse scope renames
    execute "UPDATE api_keys SET scope_type = 'personal' WHERE scope_type = 'project'"
    execute "UPDATE permissions SET scope_type = 'personal' WHERE scope_type = 'project'"
    execute "UPDATE secrets SET scope = 'personal' WHERE scope = 'project'"
    execute "UPDATE secret_grants SET scope = 'personal' WHERE scope = 'project'"

    # Drop added columns (reverse order)
    drop_if_exists index(:component_dependencies, [:org_id, :project_id])

    alter table(:component_dependencies) do
      remove :org_id
      remove :project_id
    end

    drop_if_exists unique_index(:policies, [:component_ref, :org_id, :project_id])
    create unique_index(:policies, [:component_ref])

    alter table(:policies) do
      remove :org_id
      remove :project_id
    end

    drop_if_exists index(:policy_logs, [:org_id, :project_id])

    alter table(:policy_logs) do
      remove :org_id
      remove :project_id
    end

    drop_if_exists index(:mcp_logs, [:org_id, :project_id])

    alter table(:mcp_logs) do
      remove :org_id
      remove :project_id
    end

    drop_if_exists index(:cron_schedules, [:org_id, :project_id])

    alter table(:cron_schedules) do
      remove :org_id
      remove :project_id
    end

    drop_if_exists unique_index(:secret_grants, [
                     :secret_name,
                     :component_ref,
                     :org_id,
                     :project_id
                   ])

    create unique_index(:secret_grants, [:secret_name, :component_ref])

    alter table(:secret_grants) do
      remove :project_id
    end

    drop_if_exists unique_index(:secrets, [:name, :scope, :org_id, :project_id])
    create unique_index(:secrets, [:name, :scope])

    alter table(:secrets) do
      remove :project_id
    end

    drop_if_exists unique_index(:permissions, [:subject, :scope_type, :org_id, :project_id])
    create unique_index(:permissions, [:subject, :scope_type])

    alter table(:permissions) do
      remove :project_id
    end

    drop_if_exists unique_index(:api_keys, [:name, :scope_type, :org_id, :project_id])
    create unique_index(:api_keys, [:name, :scope_type])

    alter table(:api_keys) do
      remove :project_id
    end

    drop_if_exists unique_index(:components, [:name, :version, :publisher, :org_id, :project_id])
    create unique_index(:components, [:name, :version])

    alter table(:components) do
      remove :project_id
    end
  end
end
