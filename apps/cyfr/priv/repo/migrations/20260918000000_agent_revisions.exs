# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.AgentRevisions do
  use Ecto.Migration

  # Every agent file revision the estate's index has seen, by the digest
  # of its bytes: content-addressed and immutable, so a turn that pinned
  # a revision can retrieve it after the tree moved on.
  def change do
    create table(:agent_revisions, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false
      add :digest, :string, null: false
      add :bytes, :binary, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:agent_revisions, [:athanor_id, :digest])
  end
end
