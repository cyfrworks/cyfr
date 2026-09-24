# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Retention.Executions do
  @moduledoc "Execution records: the newest N per athanor survive."
  @behaviour Arca.Retention.Kind

  alias Arca.Retention.{ExecutionRows, Kind}

  @impl true
  def key, do: "executions"

  @impl true
  def default, do: Kind.configured(:executions, 10_000)

  @impl true
  def unit, do: :keep

  @impl true
  def prune(%Cyfr.Actor{athanor_id: athanor} = actor, keep, dry_run) when is_binary(athanor) do
    opts = [athanor_id: athanor]

    if dry_run,
      do: Arca.Execution.count_stale(keep, opts),
      else: ExecutionRows.delete(actor, fn -> Arca.Execution.stale_ids(keep, opts) end, opts)
  end
end
