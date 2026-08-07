# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.CreateProfiles do
  use Ecto.Migration

  # A profile carries only stable identity and live revocation state;
  # everything that changes what a grant means lives in the consent
  # revision. head_consent_id deliberately has no foreign key: it points
  # into a table that references back here, and the compare-and-swap
  # advance plus application tests are the guarantee instead of a deferred
  # constraint SQLite cannot express.
  def change do
    create table(:profiles, primary_key: false) do
      add :id, :string, primary_key: true
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"
      add :source_ref, :string, null: false
      add :kind, :string, null: false, default: "owner"
      add :label, :string, null: false, default: "default"
      add :status, :string, null: false, default: "active"
      add :head_consent_id, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:profiles, [:org_id, :id])

    # kind is in the key: a component's owner and public profiles would
    # otherwise collide.
    create unique_index(:profiles, [:source_ref, :label, :kind, :project_id, :org_id],
             where: "status != 'revoked'",
             name: :profiles_active_identity_index
           )

    create index(:profiles, [:source_ref, :project_id, :org_id])
  end
end
