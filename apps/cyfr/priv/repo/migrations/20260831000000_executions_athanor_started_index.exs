# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.ExecutionsAthanorStartedIndex do
  use Ecto.Migration

  # Retention's own query had no index to walk.
  #
  # `Arca.Execution.stale_query/2` — the spelling both the six-hourly delete
  # and its dry-run count share — asks for `WHERE athanor_id = ? ORDER BY
  # started_at DESC LIMIT keep` (10_000 by default). The table already
  # carried `(athanor_id)`, `(started_at)`, `(athanor_id, user_id,
  # started_at)` and `(athanor_id, status, started_at)`, and not one of them
  # serves it: the two composites lead with a column the query does not
  # constrain, so rows come back ordered by `user_id`/`status` and have to be
  # re-sorted, while the single-column pair forces a choice between filtering
  # and ordering. So every cycle scanned the athanor's whole execution set
  # and sorted it.
  #
  # Same gap, same fix as `policy_logs`/`mcp_logs` `(athanor_id, timestamp)`;
  # executions were simply missed because they had four indexes that looked
  # like they covered it.
  def change do
    create index(:executions, [:athanor_id, :started_at])
  end
end
