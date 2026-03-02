defmodule Arca.Repo.Migrations.AddAllowedActionsToPolicies do
  use Ecto.Migration

  def change do
    alter table(:policies) do
      add :allowed_actions, :text, default: ~s(["read","write","list","delete","exists"])
    end
  end
end
