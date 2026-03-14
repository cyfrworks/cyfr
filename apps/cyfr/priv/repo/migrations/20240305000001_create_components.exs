defmodule Arca.Repo.Migrations.CreateComponents do
  use Ecto.Migration

  def change do
    create table(:components, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :version, :string, null: false
      add :component_type, :string, null: false
      add :description, :string
      add :tags, :string
      add :category, :string
      add :license, :string
      add :digest, :string, null: false
      add :size, :integer
      add :exports, :string
      add :publisher_id, :string
      add :org_id, :string
      timestamps()
    end

    create unique_index(:components, [:name, :version, :org_id])
    create index(:components, [:name])
    create index(:components, [:component_type])
  end
end
