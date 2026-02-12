defmodule Arca.Repo.Migrations.CreateSecrets do
  use Ecto.Migration

  def change do
    create table(:secrets, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :encrypted_value, :binary, null: false
      add :scope, :string, null: false, default: "personal"
      add :org_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:secrets, [:name, :scope, :org_id])

    create table(:secret_grants, primary_key: false) do
      add :id, :string, primary_key: true
      add :secret_name, :string, null: false
      add :component_ref, :string, null: false
      add :scope, :string, null: false, default: "personal"
      add :org_id, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:secret_grants, [:secret_name, :component_ref, :scope, :org_id])
  end
end
