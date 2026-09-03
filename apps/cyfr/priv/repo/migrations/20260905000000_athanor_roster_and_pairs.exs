# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.AthanorRosterAndPairs do
  use Ecto.Migration

  # A DM is a group athanor whose roster is closed.
  #
  # Two people talking had no representation: a person's athanor is 1:1 and
  # refuses members forever (`Sanctum.Tenancy.Members.add/3`), and the only
  # other shape was an open group anyone in it could invite into. So a DM
  # meant either minting a group that behaves like a room with a door
  # propped open, or inventing a second tenancy primitive beside the
  # athanor — a conversation that owns no keys, no cron and no files, which
  # is most of what an estate is for.
  #
  # `roster` closes the door instead. A frozen group takes its members at
  # birth and never gains another, so it can be exactly a pair, and
  # everything an estate already knows how to do — a vault, a schedule, an
  # audit trail, storage — works in it unchanged.
  #
  # ## Why `pair_key`, and why the index is partial on ACTIVE
  #
  # "Click Alice" must find the pair already there rather than mint a
  # second one, and it must do so without scanning memberships or racing a
  # double-click. `pair_key` is a hash of the sorted member ids: one
  # indexed lookup, and the unique index is what makes the race a typed
  # conflict instead of two tapes.
  #
  # `status = 'active'` in the index is load-bearing. A frozen estate is
  # archived the moment either person leaves (a one-member frozen group
  # would be a second You, and its `pair_key` still hashes both ids). If
  # the index covered archived rows, that husk would block the pair ever
  # being remade — the two could never speak again. Clicking a name after
  # a departure mints a NEW tape; it never reopens the old one.
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
