# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.DropConversationHistory do
  use Ecto.Migration

  # The tape is the transcript and a turn's root is on its own row: the
  # conversation's provider-shaped history and running execution, and the
  # turn's execution-keyed column, go.
  def up do
    drop index(:conversations, [:athanor_id, :execution_id])
    drop index(:turns, [:execution_id])

    alter table(:conversations) do
      remove :history
      remove :execution_id
    end

    alter table(:turns) do
      remove :execution_id
    end
  end

  def down do
    alter table(:conversations) do
      add :history, :text
      add :execution_id, :string
    end

    alter table(:turns) do
      add :execution_id, :string
    end

    create index(:conversations, [:athanor_id, :execution_id])
    create unique_index(:turns, [:execution_id], where: "execution_id IS NOT NULL")
  end
end
