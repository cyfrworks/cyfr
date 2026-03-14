defmodule Arca.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  def change do
    create table(:api_keys, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :key_hash, :binary, null: false
      add :key_prefix, :string, null: false
      add :type, :string, null: false
      add :scope, :text, null: false, default: "[]"
      add :rate_limit, :string
      add :ip_allowlist, :text
      add :revoked, :boolean, null: false, default: false
      add :created_by, :string
      add :rotated_at, :utc_datetime_usec
      add :scope_type, :string, null: false, default: "personal"
      add :org_id, :string, null: false, default: ""

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_keys, [:name, :scope_type, :org_id])
    create unique_index(:api_keys, [:key_hash])
  end
end
