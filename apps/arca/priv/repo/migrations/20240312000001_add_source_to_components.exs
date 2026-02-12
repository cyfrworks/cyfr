defmodule Arca.Repo.Migrations.AddSourceToComponents do
  use Ecto.Migration

  def change do
    alter table(:components) do
      add :source, :string, default: "published", null: false
    end

    create index(:components, [:source])
  end
end
