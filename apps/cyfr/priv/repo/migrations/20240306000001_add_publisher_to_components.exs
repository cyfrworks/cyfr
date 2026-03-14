defmodule Arca.Repo.Migrations.AddPublisherToComponents do
  use Ecto.Migration

  def change do
    alter table(:components) do
      add :publisher, :string, default: "local", null: false
    end

    # Drop old unique index (name+version+org_id) and recreate with publisher
    drop_if_exists unique_index(:components, [:name, :version, :org_id])
    create unique_index(:components, [:publisher, :name, :version, :org_id])
    create index(:components, [:publisher])
  end
end
