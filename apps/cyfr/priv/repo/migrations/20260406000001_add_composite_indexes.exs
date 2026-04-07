defmodule Arca.Repo.Migrations.AddCompositeIndexes do
  use Ecto.Migration

  def change do
    # Execution list: WHERE org_id AND project_id AND user_id ORDER BY started_at
    create_if_not_exists index(:executions, [:org_id, :project_id, :user_id, :started_at])

    # Execution list with status filter
    create_if_not_exists index(:executions, [:org_id, :project_id, :status, :started_at])

    # MCP log list: WHERE org_id AND project_id ORDER BY timestamp
    create_if_not_exists index(:mcp_logs, [:org_id, :project_id, :timestamp])

    # Secret grants: WHERE component_ref AND scope (scope missing from existing index)
    create_if_not_exists index(:secret_grants, [:component_ref, :scope, :org_id, :project_id])
  end
end
