# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.DropRevokedSessions do
  @moduledoc """
  R4: drop the dead `revoked_sessions` table.

  The JWT-context subsystem (`Sanctum.Context.from_jwt/1`) and the
  session_id-revocation machinery were removed: `Session.create` never minted
  a `session_id`, so `destroy/1`'s revoke branch was unreachable and the only
  reader (`validate_session_not_revoked` ← `from_jwt`) had zero production
  callers. The table only ever held rows in tests.
  """
  use Ecto.Migration

  def up do
    drop table(:revoked_sessions)
  end

  # Recreate in its final pre-drop shape (original create + the later
  # add_tenant_to_revoked_sessions alter, merged) so the migration is
  # reversible.
  def down do
    create table(:revoked_sessions, primary_key: false) do
      add :id, :string, primary_key: true
      add :session_id, :string, null: false
      add :revoked_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :org_id, :string, default: "", null: false
      add :project_id, :string, default: "default", null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:revoked_sessions, [:session_id])
  end
end
