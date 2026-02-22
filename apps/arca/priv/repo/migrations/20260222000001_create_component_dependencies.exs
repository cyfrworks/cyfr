defmodule Arca.Repo.Migrations.CreateComponentDependencies do
  use Ecto.Migration

  def change do
    create table(:component_dependencies, primary_key: false) do
      add :id, :string, primary_key: true
      add :component_id, references(:components, type: :string, on_delete: :delete_all), null: false
      add :dependency_ref, :string, null: false
      add :dep_type, :string, null: false
      add :dep_namespace, :string, null: false
      add :dep_name, :string, null: false
      add :dep_version, :string, null: false
      add :optional, :integer, default: 0, null: false
      add :reason, :text

      timestamps()
    end

    create index(:component_dependencies, [:component_id])
    create index(:component_dependencies, [:dep_name])
    create unique_index(:component_dependencies, [:component_id, :dependency_ref])
  end
end
