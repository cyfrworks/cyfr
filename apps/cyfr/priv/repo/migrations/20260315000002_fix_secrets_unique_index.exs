defmodule Arca.Repo.Migrations.FixSecretsUniqueIndex do
  use Ecto.Migration

  def up do
    # The original migration created a 3-column index (name, scope, org_id).
    # Migration 20260312000001 created a 4-column index but didn't drop the old one.
    # The old 3-column index blocks inserts with same (name, scope, org_id) but different project_id.
    drop_if_exists unique_index(:secrets, [:name, :scope, :org_id])
  end

  def down do
    create unique_index(:secrets, [:name, :scope, :org_id])
  end
end
