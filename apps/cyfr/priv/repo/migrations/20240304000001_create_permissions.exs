defmodule Arca.Repo.Migrations.CreatePermissions do
  use Ecto.Migration

  def change do
    create table(:permissions, primary_key: false) do
      add :id, :string, primary_key: true
      add :subject, :string, null: false
      add :permissions, :text, null: false, default: "[]"
      add :scope_type, :string, null: false, default: "personal"
      add :org_id, :string, null: false, default: ""

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:permissions, [:subject, :scope_type, :org_id])
  end
end
