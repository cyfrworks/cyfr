defmodule Arca.Repo.Migrations.AddTenantToRevokedSessions do
  use Ecto.Migration

  def change do
    alter table(:revoked_sessions) do
      add :org_id, :string, default: "", null: false
      add :project_id, :string, default: "default", null: false
    end
  end
end
