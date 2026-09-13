# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Retention.SchedulePayloads do
  @moduledoc """
  Retained payloads of scheduled executions (retention class `schedule`) older than N
  days go — the bytes and the rows that reference them.
  """
  @behaviour Cyfr.Retention.Kind

  @impl true
  def key, do: "schedule_payload_days"

  @impl true
  def default,
    do: Keyword.get(Application.get_env(:cyfr, Cyfr.Retention, []), :schedule_payload_days, 30)

  @impl true
  def unit, do: :days

  @impl true
  def prune(ctx, days, dry_run),
    do: Cyfr.Retention.Payloads.prune_classes(ctx, ["schedule"], days, dry_run)
end
