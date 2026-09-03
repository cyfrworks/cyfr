# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.ConversationsOrchestratorOwner do
  use Ecto.Migration

  # Whose agent this conversation last ran was stored as a bare name.
  #
  # Once agents belong to people as well as estates, two rosters can hold
  # the same name: your `aqua` and the estate's. A conversation row that
  # remembers only `"aqua"` cannot say WHICH — so recovery after a restart
  # re-read the name from the estate in focus and could resume a turn on
  # the wrong agent's policy, and the picker could not re-select a personal
  # agent at all.
  #
  # `orchestrator_owner` is the owning athanor's ID — not its slug, which a
  # rename moves. Nullable: rows written before the column, and turns whose
  # orchestrator came from an unqualified fallback, carry none and resolve
  # from the estate in focus as before.
  def up do
    alter table(:conversations) do
      add :orchestrator_owner, :string
    end
  end

  def down do
    alter table(:conversations) do
      remove :orchestrator_owner
    end
  end
end
