defmodule Arca.Repo.Migrations.AddParentExecutionIdToExecutions do
  use Ecto.Migration

  def change do
    alter table(:executions) do
      add :parent_execution_id, :string
    end

    create index(:executions, [:parent_execution_id])
  end
end
