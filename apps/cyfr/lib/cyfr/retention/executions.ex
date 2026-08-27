# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Retention.Executions do
  @moduledoc "Execution records: the newest N per athanor survive."
  @behaviour Cyfr.Retention.Kind

  @impl true
  def key, do: "executions"

  @impl true
  def default,
    do: Keyword.get(Application.get_env(:cyfr, Cyfr.Retention, []), :executions, 10_000)

  @impl true
  def unit, do: :keep

  @impl true
  def prune(ctx, keep, dry_run) do
    opts = [athanor_id: Sanctum.Context.athanor!(ctx)]

    if dry_run,
      do: Arca.Execution.count_stale(keep, opts),
      else: Arca.Execution.delete_older_than(keep, opts)
  end
end
