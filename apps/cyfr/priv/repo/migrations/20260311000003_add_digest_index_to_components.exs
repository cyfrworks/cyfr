defmodule Arca.Repo.Migrations.AddDigestIndexToComponents do
  use Ecto.Migration

  def change do
    create index(:components, [:digest])
  end
end
