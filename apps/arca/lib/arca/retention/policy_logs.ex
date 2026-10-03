# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Retention.PolicyLogs do
  @moduledoc "Policy consultation logs: rows older than N days go."
  @behaviour Arca.Retention.Kind

  alias Arca.Retention.Kind

  @impl true
  def key, do: "policy_log_days"

  @impl true
  def default, do: Kind.configured(:policy_log_days, 30)

  @impl true
  def unit, do: :days

  @impl true
  def prune(%Prima.Actor{athanor_id: athanor}, days, dry_run) when is_binary(athanor) do
    cutoff = Kind.days_cutoff(days)
    opts = [athanor_id: athanor]

    if dry_run,
      do: Arca.PolicyLog.count_before(cutoff, opts),
      else: Arca.PolicyLog.delete_before(cutoff, opts)
  end
end
