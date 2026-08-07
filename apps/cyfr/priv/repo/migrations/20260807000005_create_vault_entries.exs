# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.CreateVaultEntries do
  use Ecto.Migration

  # One row per external account. Credentials are shared, never copied:
  # several profiles reference one entry through consent edges. The sealed
  # payload is encrypted by the caller (Sanctum) — Arca stores bytes.
  #
  # The (org_id, id) unique index exists for the two-column composite
  # foreign keys pointing here: a 3+-column composite FK silently truncates
  # on SQLite, so referencing tables carry (org_id, <fk>) pairs and this is
  # the parent side. It must exist before any referencing table is created.
  def change do
    create table(:vault_entries, primary_key: false) do
      add :id, :string, primary_key: true
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"
      add :name, :string, null: false
      add :provider_hint, :string, null: false, default: ""
      add :kind, :string, null: false
      add :system, :boolean, null: false, default: false
      add :provenance, :string, null: false, default: "user"
      add :field_names, :text, null: false, default: "[]"
      add :binding_digest, :string
      add :oauth_endpoints, :text
      add :oauth_scopes, :text
      add :status, :string, null: false, default: "active"
      add :payload_rev, :integer, null: false, default: 0
      add :sealed_payload, :binary
      add :last_used_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:vault_entries, [:org_id, :id])

    # Names are unique among the living; tombstoned rows keep theirs.
    # `!=` string predicates parse on both SQLite and Postgres.
    create unique_index(:vault_entries, [:name, :project_id, :org_id],
             where: "status != 'tombstoned'",
             name: :vault_entries_active_name_index
           )

    create index(:vault_entries, [:org_id, :project_id])
  end
end
