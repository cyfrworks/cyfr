# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Retention.Conversations do
  @moduledoc """
  Conversations whose last activity is older than N days — messages and
  attachment blobs go with them; one with a running turn is never touched
  (`Arca.ConversationStorage` owns that rule).
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
      do: Arca.ConversationStorage.count_before(ctx, cutoff),
      else: Arca.ConversationStorage.delete_before(ctx, cutoff)
  end
end
