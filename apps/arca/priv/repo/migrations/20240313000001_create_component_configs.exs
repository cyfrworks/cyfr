defmodule Arca.Repo.Migrations.CreateComponentConfigs do
  use Ecto.Migration

  def change do
    create table(:component_configs, primary_key: false) do
      add :id, :string, primary_key: true
      add :component_ref, :string, null: false
      add :key, :string, null: false
      add :value, :text, null: false      # JSON-encoded
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:component_configs, [:component_ref, :key])
    create index(:component_configs, [:component_ref])
  end
end
