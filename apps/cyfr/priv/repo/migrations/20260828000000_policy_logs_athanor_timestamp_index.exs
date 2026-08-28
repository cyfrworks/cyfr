# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.PolicyLogsAthanorTimestampIndex do
  use Ecto.Migration

  # `Arca.PolicyLog.list/1` filters on athanor_id and orders by timestamp
  # desc with a limit — the exact query the mcp_logs composite index
  # already serves for its sibling table. policy_logs had the two columns
  # indexed separately, so the hot listing walked one index and sorted.
  def change do
    create index(:policy_logs, [:athanor_id, :timestamp])
  end
end
