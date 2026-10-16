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
  def prune(%Prima.Actor{athanor_id: athanor} = actor, days, dry_run) when is_binary(athanor) do
    cutoff = Kind.days_cutoff(days)

    if dry_run,
      do: Arca.PolicyLog.count_before(actor, cutoff),
      else: Arca.PolicyLog.delete_before(actor, cutoff)
  end
end
