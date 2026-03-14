defmodule Arca.Repo.Migrations.CreatePolicies do
  use Ecto.Migration

  def change do
    create table(:policies, primary_key: false) do
      add :id, :string, primary_key: true
      add :component_ref, :string, null: false
      add :component_type, :string, null: false, default: "reagent"
      add :allowed_domains, :text  # JSON array
      add :allowed_methods, :text  # JSON array
      add :rate_limit_requests, :integer
      add :rate_limit_window_seconds, :integer
      add :timeout, :string, default: "30s"
      add :max_memory_bytes, :bigint, default: 67_108_864  # 64MB
      add :max_request_size, :integer, default: 1_048_576  # 1MB
      add :max_response_size, :integer, default: 5_242_880  # 5MB

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:policies, [:component_ref])
    create index(:policies, [:component_type])
  end
end
