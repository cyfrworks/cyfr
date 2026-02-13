defmodule Arca.Repo.Migrations.AddTypeToComponentUniqueness do
  use Ecto.Migration

  def change do
    # Drop old unique index (publisher+name+version+org_id) and recreate with component_type
    drop_if_exists unique_index(:components, [:publisher, :name, :version, :org_id])
    create unique_index(:components, [:publisher, :name, :version, :component_type, :org_id])
  end
end
