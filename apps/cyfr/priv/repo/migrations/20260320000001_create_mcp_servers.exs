defmodule Arca.Repo.Migrations.CreateMcpServers do
  use Ecto.Migration

  def up do
    create table(:mcp_servers, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :url, :string, null: false
      add :config_json, :text, default: "{}"
      add :enabled, :boolean, default: true
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"
      timestamps()
    end

    create unique_index(:mcp_servers, [:name, :org_id, :project_id])
    create index(:mcp_servers, [:org_id, :project_id])
  end

  def down do
    drop_if_exists index(:mcp_servers, [:org_id, :project_id])
    drop_if_exists unique_index(:mcp_servers, [:name, :org_id, :project_id])
    drop_if_exists table(:mcp_servers)
  end
end
