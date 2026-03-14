defmodule Arca.Repo.Migrations.AddAllowedToolsToPolicies do
  use Ecto.Migration

  def change do
    alter table(:policies) do
      add :allowed_tools, :text        # JSON array of tool patterns (e.g. ["component.*", "storage.read"])
      add :allowed_storage_paths, :text # JSON array of path prefixes (e.g. ["agent/"])
    end
  end
end
