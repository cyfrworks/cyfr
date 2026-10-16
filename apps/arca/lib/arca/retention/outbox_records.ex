# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Retention.OutboxRecords do
  @moduledoc """
  Outbox records (`Arca.Outbox`) every consumer of their kind has
  receipted go N days after the newest of those receipts, with the
  receipts. A record some consumer has not receipted stays, whatever its
  age: it is work still to be done. Independent of the schedule payloads
  (`Arca.Retention.SchedulePayloads`): a record's snapshot is its own
  copy, kept until its consumers are done with it.
  """
  @behaviour Arca.Retention.Kind

  alias Arca.Retention.Kind

  @impl true
  def key, do: "outbox_record_days"

  @impl true
  def default, do: Kind.configured(:outbox_record_days, 30)

  @impl true
  def unit, do: :days

  @impl true
  def prune(%Prima.Actor{} = actor, days, dry_run)
      when is_integer(days) and days > 0 and is_boolean(dry_run),
      do: Arca.Outbox.prune(actor, Kind.days_cutoff(days), dry_run)
end
