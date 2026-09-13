# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.Agents do
  use Ecto.Migration

  # The estate's agents as rows: a derived index of the `aqua/` tree, one
  # row per soul or role, carrying the digest of the file's bytes (its
  # revision) and the digest of its security-relevant subset (its
  # capability: type, catalyst, model, tool policy). The tree stays the
  # source; the index is rewritten from it after every write and is what
  # derivation tests and, later, revision registration read.
  def change do
    create table(:agents, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false
      add :name, :string, null: false
      # soul | role
      add :kind, :string, null: false
      add :revision_digest, :string, null: false
      add :capability_digest, :string, null: false
      add :catalyst_ref, :string
      add :disabled, :boolean, null: false, default: false
      add :synced_at, :utc_datetime_usec, null: false
    end

    create unique_index(:agents, [:athanor_id, :name])
  end
end
