# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.CreateConsents do
  use Ecto.Migration

  # Consent revisions are insert-only: removing one edge writes a complete
  # new revision and atomically advances the profile's head pointer. No
  # updated_at exists because no update ever happens — the storage layer
  # exports no update function and a test pins that. granted_at is the
  # only timestamp a revision can have.
  #
  # The two-column composite FK to profiles carries the tenant, so a
  # consent can never reference a profile across an org boundary.
  def change do
    create table(:consents, primary_key: false) do
      add :id, :string, primary_key: true
      add :org_id, :string, null: false, default: ""

      add :profile_id,
          references(:profiles, column: :id, type: :string, with: [org_id: :org_id]),
          null: false

      add :revision, :integer, null: false
      add :scope, :string, null: false
      add :pinned_version, :string, null: false, default: ""
      add :invoke_mode, :string, null: false, default: "open_inert"
      add :shape_digest, :string, null: false
      add :commit_digest, :string, null: false
      add :resolved_policy, :binary, null: false
      add :activation, :binary, null: false
      add :granted_by, :string, null: false
      add :granted_via, :string, null: false
      add :granted_at, :utc_datetime_usec, null: false
      add :supersedes_id, :string
    end

    create unique_index(:consents, [:profile_id, :revision])
    create index(:consents, [:org_id, :profile_id])
  end
end
