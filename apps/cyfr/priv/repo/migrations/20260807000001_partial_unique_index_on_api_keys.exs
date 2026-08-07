# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.PartialUniqueIndexOnApiKeys do
  use Ecto.Migration

  # Soft-revoked keys kept their name reserved forever: the unique index had
  # no predicate, so a revoked key squatted its name. Follow the
  # cron_schedules precedent — uniqueness applies to live rows only.
  # `revoked` has been NOT NULL DEFAULT false since table creation, so no
  # backfill is needed. `NOT revoked` parses on both SQLite and Postgres.
  def up do
    drop unique_index(:api_keys, [:name, :scope_type, :org_id, :project_id])

    create unique_index(:api_keys, [:name, :scope_type, :org_id, :project_id],
             where: "NOT revoked",
             name: :api_keys_active_name_index
           )
  end

  # Recreating the unconditional index fails if the same name has since been
  # reused over a revoked key — expected: the duplicate rows must be resolved
  # by hand before rolling back.
  def down do
    drop unique_index(:api_keys, [:name, :scope_type, :org_id, :project_id],
           name: :api_keys_active_name_index
         )

    create unique_index(:api_keys, [:name, :scope_type, :org_id, :project_id])
  end
end
