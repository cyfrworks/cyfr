# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Retention.ExecutionsAge do
  @moduledoc """
  Execution records older than N days go. The count-based kind
  (`Arca.Retention.Executions`) bounds how many rows an athanor keeps;
  this one bounds how long, because a quiet athanor kept its last ten
  thousand executions — and what their inputs carried — forever.
  """
  @behaviour Arca.Retention.Kind

  alias Arca.Retention.{ExecutionRows, Kind}

  @impl true
  def key, do: "execution_days"

  @impl true
  def default, do: Kind.configured(:execution_days, 90)

  @impl true
  def unit, do: :days

  @impl true
  def prune(%Prima.Actor{athanor_id: athanor} = actor, days, dry_run) when is_binary(athanor) do
    opts = [athanor_id: athanor]

    if dry_run,
      do: Arca.Execution.count_older_than_days(days, opts),
      else:
        ExecutionRows.delete(
          actor,
          fn -> Arca.Execution.ids_older_than_days(days, opts) end,
          opts
        )
  end
end
