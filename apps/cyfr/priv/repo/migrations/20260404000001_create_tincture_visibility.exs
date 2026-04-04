defmodule Arca.Repo.Migrations.CreateTinctureVisibility do
  use Ecto.Migration

  def change do
    create table(:tincture_visibility, primary_key: false) do
      add :id, :string, primary_key: true
      add :publisher, :string, null: false
      add :name, :string, null: false
      add :is_public, :boolean, null: false, default: false
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tincture_visibility, [:publisher, :name, :org_id, :project_id])
  end
end
