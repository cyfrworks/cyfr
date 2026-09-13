# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.DropSessionPermissions do
  use Ecto.Migration

  # A session is a person's: what they may do is decided by their
  # memberships, the estate's consents and the policy, never by a list
  # frozen at sign-in. A key carries its scope on its own row.
  def change do
    alter table(:sessions) do
      remove :permissions, :text, null: false, default: "[]"
    end
  end
end
