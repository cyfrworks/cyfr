# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Retention.Threads do
  @moduledoc """
  Threads whose last activity is older than N days — messages and
  attachment blobs go with them; one with a running turn is never touched
  (`Arca.ThreadStorage` owns that rule).
  """
  @behaviour Cyfr.Retention.Kind

  @impl true
  def key, do: "messages_days"

  @impl true
  def default,
    do: Keyword.get(Application.get_env(:cyfr, Cyfr.Retention, []), :messages_days, 365)

  @impl true
  def unit, do: :days

  @impl true
  def prune(ctx, days, dry_run) do
    cutoff = Cyfr.Retention.Kind.days_cutoff(days)

    if dry_run,
      do: Arca.ThreadStorage.count_before(Sanctum.Context.actor(ctx), cutoff),
      else: Arca.ThreadStorage.delete_before(Sanctum.Context.actor(ctx), cutoff)
  end
end
