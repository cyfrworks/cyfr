# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.AddScopeToSessions do
  use Ecto.Migration

  # Nullable, no default: pre-existing rows are left NULL on purpose so
  # `Sanctum.Session.row_to_context/1` re-resolves their scope from memberships
  # on next load. New sessions persist the resolved scope, which lets the
  # per-request membership re-resolution be skipped (the tenant resolver no-ops
  # when a session already carries a concrete org + scope).
  def change do
    alter table(:sessions) do
      add :scope, :string
    end
  end
end
