# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.SimplifyMemberships do
  @moduledoc """
  Collapse memberships to a presence-only scope assignment.

  A membership row now says exactly one thing: "user X is admin of scope S".
  The old `role` (owner/admin/member) was never consulted for any access
  decision, and the invite ceremony (`invited_at`/`accepted_at`) had no
  surface. They are dropped. A new `scope` column (`platform`/`org`/`project`)
  plus a nullable `project_id` lets a single row express any of the three
  assignment shapes; `org_id` becomes nullable so a platform-scope row needs
  no org.

  Implemented as a table rebuild because SQLite cannot relax a NOT NULL
  column in place. Existing rows (org memberships) carry over as `scope:
  "org"`.
  """

  use Ecto.Migration

  def up do
    create table(:memberships_new, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, :string, null: false
      add :scope, :string, null: false, default: "project"
      add :org_id, references(:orgs, type: :string, on_delete: :delete_all)
      add :project_id, references(:projects, type: :string, on_delete: :delete_all)
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    # Carry existing org memberships over. Role/invite columns are dropped.
    execute """
    INSERT INTO memberships_new (id, user_id, scope, org_id, project_id, created_at, updated_at)
    SELECT id, user_id, 'org', org_id, NULL, created_at, updated_at FROM memberships
    """

    drop table(:memberships)
    rename table(:memberships_new), to: table(:memberships)

    # Presence-of-row = assignment. COALESCE keeps the uniqueness check working
    # across the nullable org_id/project_id on both SQLite and Postgres (which
    # otherwise treat NULLs as distinct).
    execute(
      "CREATE UNIQUE INDEX memberships_assignment_index ON memberships " <>
        "(user_id, scope, COALESCE(org_id, ''), COALESCE(project_id, ''))",
      "DROP INDEX memberships_assignment_index"
    )

    create index(:memberships, [:user_id])
  end

  def down do
    # Best-effort reverse to the legacy shape. Platform/project-scope rows
    # cannot be represented with a NOT NULL org_id, so only org-scope rows
    # carry back.
    create table(:memberships_old, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, :string, null: false
      add :org_id, references(:orgs, type: :string, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "member"
      add :invited_at, :utc_datetime_usec
      add :accepted_at, :utc_datetime_usec
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    execute """
    INSERT INTO memberships_old (id, user_id, org_id, role, created_at, updated_at)
    SELECT id, user_id, org_id, 'member', created_at, updated_at
    FROM memberships WHERE scope = 'org' AND org_id IS NOT NULL
    """

    drop table(:memberships)
    rename table(:memberships_old), to: table(:memberships)

    create unique_index(:memberships, [:user_id, :org_id])
  end
end
