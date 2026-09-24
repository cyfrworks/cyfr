# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Retention.Threads do
  @moduledoc """
  Threads whose last activity is older than N days — messages and
  attachment blobs go with them; one with a running turn is never touched
  (`Arca.ThreadStorage` owns that rule).
  """
  @behaviour Arca.Retention.Kind

  alias Arca.Retention.Kind

  @impl true
  def key, do: "messages_days"

  @impl true
  def default, do: Kind.configured(:messages_days, 365)

  @impl true
  def unit, do: :days

  @impl true
  def prune(%Prima.Actor{} = actor, days, dry_run) do
    cutoff = Kind.days_cutoff(days)

    if dry_run,
      do: Arca.ThreadStorage.count_before(actor, cutoff),
      else: Arca.ThreadStorage.delete_before(actor, cutoff)
  end
end
