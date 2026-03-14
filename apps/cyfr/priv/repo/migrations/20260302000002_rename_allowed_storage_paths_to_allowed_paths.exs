defmodule Arca.Repo.Migrations.RenameAllowedStoragePathsToAllowedPaths do
  use Ecto.Migration

  def change do
    rename table(:policies), :allowed_storage_paths, to: :allowed_paths
  end
end
