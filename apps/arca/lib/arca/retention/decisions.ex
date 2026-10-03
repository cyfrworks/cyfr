# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Retention.Decisions do
  @moduledoc """
  Admission decisions (`Arca.DecisionLog`): an athanor's rows older than N
  days go. The rows without a tenant are the host's, purged under its own
  retention (`Cyfr.RetentionScheduler`), never by an athanor's.
  """
  @behaviour Arca.Retention.Kind

  alias Arca.Retention.Kind

  @impl true
  def key, do: "decisions_days"

  @impl true
  def default, do: Kind.configured(:decisions_days, 90)

  @impl true
  def unit, do: :days

  @impl true
  def prune(%Prima.Actor{athanor_id: athanor}, days, dry_run) when is_binary(athanor) do
    cutoff = Kind.days_cutoff(days)
    opts = [athanor_id: athanor]

    if dry_run,
      do: Arca.DecisionLog.count_before(cutoff, opts),
      else: Arca.DecisionLog.delete_before(cutoff, opts)
  end
end
