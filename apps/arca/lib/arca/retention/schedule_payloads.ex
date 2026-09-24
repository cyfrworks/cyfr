# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Retention.SchedulePayloads do
  @moduledoc """
  Retained payloads of scheduled executions (retention class `schedule`) older than N
  days go — the bytes and the rows that reference them.
  """
  @behaviour Arca.Retention.Kind

  alias Arca.Retention.{Kind, Payloads}

  @impl true
  def key, do: "schedule_payload_days"

  @impl true
  def default, do: Kind.configured(:schedule_payload_days, 30)

  @impl true
  def unit, do: :days

  @impl true
  def prune(actor, days, dry_run), do: Payloads.prune_classes(actor, ["schedule"], days, dry_run)
end
