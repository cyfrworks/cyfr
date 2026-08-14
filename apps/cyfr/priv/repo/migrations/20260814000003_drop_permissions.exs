# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.DropPermissions do
  @moduledoc """
  Drop the `permissions` table.

  Nothing on any authorization path ever read it: OIDC login grants the
  full permission set, sessions carry their permissions from creation, and
  API keys hold scopes in their own column. The table was written and read
  only by the `permission` MCP tool that leaves with it — memberships are
  presence-only and there are no roles.
  """
  use Ecto.Migration

  def up do
    drop_if_exists table(:permissions)
  end

  def down do
    create table(:permissions, primary_key: false) do
      add :id, :string, primary_key: true
      add :subject, :string, null: false
      add :permissions, :text, null: false, default: "[]"
      add :scope_type, :string, null: false, default: "personal"
      add :org_id, :string, null: false, default: ""

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:permissions, [:subject, :scope_type, :org_id])
  end
end
