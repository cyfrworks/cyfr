defmodule Arca.Repo.Migrations.CreateExecutions do
  use Ecto.Migration

  def change do
    create table(:executions, primary_key: false) do
      add :id, :string, primary_key: true
      add :reference, :string, null: false
      add :input_hash, :string
      add :user_id, :string, null: false
      add :component_type, :string, default: "reagent"
      add :component_digest, :string
      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec
      add :duration_ms, :integer
      add :status, :string, null: false, default: "running"
      add :error_message, :text
    end

    create index(:executions, [:started_at])
    create index(:executions, [:user_id])
    create index(:executions, [:status])
  end
end
