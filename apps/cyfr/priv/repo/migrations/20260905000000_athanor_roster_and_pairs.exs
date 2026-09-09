# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.AthanorRosterAndPairs do
  use Ecto.Migration

  # Add frozen rosters for two-person athanors. Members are fixed at creation.
  # pair_key hashes sorted member ids; a partial unique index permits only one
  # active pair per key. Archived pairs retain their history without blocking
  # a new pair between the same members.
  def up do
    alter table(:athanors) do
      add :roster, :string, null: false, default: "open"
      add :pair_key, :string
    end

    # Default index name on purpose, exactly as the baseline's
    # `owner_user_id` index documents: ecto_sqlite3 reports a violation by
    # COLUMN and derives the constraint name from it, so only the derived
    # name matches the changeset on both adapters. A custom `name:` here
    # compiles, migrates, and then never catches the race it exists for.
    create unique_index(:athanors, [:pair_key],
             where: "pair_key IS NOT NULL AND status = 'active'"
           )
  end

  def down do
    drop index(:athanors, [:pair_key])

    alter table(:athanors) do
      remove :pair_key
      remove :roster
    end
  end
end
