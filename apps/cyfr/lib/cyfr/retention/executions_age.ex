# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Retention.ExecutionsAge do
  @moduledoc """
  Execution records older than N days go. The count-based kind
  (`Cyfr.Retention.Executions`) bounds how many rows an athanor keeps;
  this one bounds how long, because a quiet athanor kept its last ten
  thousand executions — and what their inputs carried — forever.
  """
  @behaviour Cyfr.Retention.Kind

  @impl true
  def key, do: "execution_days"

  @impl true
  def default,
    do: Keyword.get(Application.get_env(:cyfr, Cyfr.Retention, []), :execution_days, 90)

  @impl true
  def unit, do: :days

  @impl true
  def prune(ctx, days, dry_run) do
    opts = [athanor_id: Sanctum.Context.athanor!(ctx)]

    if dry_run,
      do: Arca.Execution.count_older_than_days(days, opts),
      else:
        Cyfr.Retention.ExecutionRows.delete(
          ctx,
          fn -> Arca.Execution.ids_older_than_days(days, opts) end,
          opts
        )
  end
end
