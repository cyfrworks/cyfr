# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.ExecutionsProfileId do
  use Ecto.Migration

  # Records the profile pinned for a root execution so approvals reuse
  # the same authority. Nullable for child executions and unrecorded profiles.
  def up do
    alter table(:executions) do
      add :profile_id, :string
    end

    # "What has this grant actually done?" — the lender's-ledger question,
    # and the one a person asks before revoking a profile.
    create index(:executions, [:athanor_id, :profile_id, :started_at])
  end

  def down do
    drop index(:executions, [:athanor_id, :profile_id, :started_at])

    alter table(:executions) do
      remove :profile_id
    end
  end
end
