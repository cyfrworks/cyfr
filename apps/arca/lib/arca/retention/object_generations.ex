# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Retention.ObjectGenerations do
  @moduledoc """
  Guest-object generations nothing reads or settles any more, older than
  N days, go with their objects (`Arca.ObjectRevisions.collect/3`): the
  generations a newer settlement superseded, the ones a delete fenced, and
  the ones whose write never settled and whose intent no longer waits.

  A path's settled generation is never collected, whatever its age: it is
  what the path reads. Neither is the generation a pending intent marked,
  nor the path's last generation while it stands above the pointer and
  the deletion fence, a write with no attempt still in flight. The object
  goes before its row, so a pass that stops between the two leaves a row
  the next pass collects; an object whose row is already gone (a store
  that landed after its generation was collected) is deleted once older
  than N days by the adapter's own date, and kept where the adapter cannot
  date it.

  The default is the write intents' (`Arca.Retention.WriteIntents`):
  a generation outlives the evidence of the write that marked it for as
  long, and no longer.
  """

  @behaviour Arca.Retention.Kind

  alias Arca.Retention.Kind

  @impl true
  def key, do: "object_generation_days"

  @impl true
  def default, do: Kind.configured(:object_generation_days, 30)

  @impl true
  def unit, do: :days

  @impl true
  def prune(%Prima.Actor{athanor_id: athanor} = actor, days, dry_run) when is_binary(athanor),
    do: Arca.ObjectRevisions.collect(actor, Kind.days_cutoff(days), dry_run)
end
