# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Retention.Threads do
  @moduledoc """
  Daily and workspace threads with no activity for N days are archived:
  put behind the Archived filter of the person's list, with nothing of
  them deleted and nothing else about them changed. One in which work
  remains, or in a crew thread under it, is never touched
  (`Arca.ThreadStorage` owns that rule). The value is `0` to archive
  nothing (`unit/0`), three days unless the athanor set one.
  """
  @behaviour Arca.Retention.Kind

  alias Arca.Retention.Kind

  @impl true
  def key, do: "archive_days"

  @impl true
  def default, do: Kind.configured(:archive_days, 3)

  @impl true
  def unit, do: :archive_days

  @impl true
  def prune(%Prima.Actor{}, 0, _dry_run), do: {:ok, 0}

  def prune(%Prima.Actor{} = actor, days, dry_run) do
    cutoff = Kind.days_cutoff(days)

    if dry_run,
      do: Arca.ThreadStorage.count_idle(actor, cutoff),
      else: Arca.ThreadStorage.archive_idle(actor, cutoff)
  end
end
