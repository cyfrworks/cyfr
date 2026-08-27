# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Retention.McpLogs do
  @moduledoc "MCP request logs: rows older than N days go."
  @behaviour Cyfr.Retention.Kind

  @impl true
  def key, do: "mcp_log_days"

  @impl true
  def default, do: Keyword.get(Application.get_env(:cyfr, Cyfr.Retention, []), :mcp_log_days, 30)

  @impl true
  def unit, do: :days

  @impl true
  def prune(ctx, days, dry_run) do
    cutoff = Cyfr.Retention.Kind.days_cutoff(days)
    opts = [athanor_id: Sanctum.Context.athanor!(ctx)]

    if dry_run,
      do: Arca.McpLog.count_before(cutoff, opts),
      else: Arca.McpLog.delete_before(cutoff, opts)
  end
end
