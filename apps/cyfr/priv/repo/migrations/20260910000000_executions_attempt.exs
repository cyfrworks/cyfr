# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.ExecutionsAttempt do
  use Ecto.Migration

  # The fence on a running execution.
  #
  # A row's lease said WHEN a runner last renewed it, but nothing said
  # WHICH runner attempt the row belonged to: every write matched on
  # `status = 'running'` alone, `runner_id` was `node()` — the same
  # `nonode@nohost` on every node, distribution being unconfigured — and
  # the sweeper's read and write were two statements. So a sweep that
  # observed a lapsed lease could fail an execution that had renewed in
  # between, and the completion guard then refused that execution's real
  # result as "not running".
  #
  # `attempt` is minted with the row and carried by the one attempt that
  # opened it. Renewal, completion and the sweep all name it (and the
  # sweep names the exact `lease_until` it observed), so a stale owner's
  # write matches nothing. Nullable: rows opened before the column existed
  # fence on status alone, as they always did.
  def up do
    alter table(:executions) do
      add :attempt, :string
    end
  end

  def down do
    alter table(:executions) do
      remove :attempt
    end
  end
end
