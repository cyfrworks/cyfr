defmodule Arca.Repo.Migrations.AddTenantColumnsToExecutions do
  use Ecto.Migration

  def change do
    alter table(:executions) do
      add :org_id, :string
      add :project_id, :string
    end

    create index(:executions, [:org_id])
    create index(:executions, [:project_id])
    create index(:executions, [:org_id, :project_id])
  end
end
