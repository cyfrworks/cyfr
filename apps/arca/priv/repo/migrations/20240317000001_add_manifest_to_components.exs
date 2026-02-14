defmodule Arca.Repo.Migrations.AddManifestToComponents do
  use Ecto.Migration

  def change do
    alter table(:components) do
      add :manifest, :text
    end
  end
end
