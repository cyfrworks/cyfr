defmodule Arca.Repo.Migrations.AddTenantColumnsToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"
    end
  end
end
