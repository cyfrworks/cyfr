# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Retention.Payloads do
  @moduledoc """
  Retained execution payloads older than N days go — the bytes and the
  rows that reference them. One setting bounds every retention class for
  now; a per-class policy is the loop's to introduce when chat steps
  reference payloads of their own.
  """
  @behaviour Cyfr.Retention.Kind

  @impl true
  def key, do: "payload_days"

  @impl true
  def default,
    do: Keyword.get(Application.get_env(:cyfr, Cyfr.Retention, []), :payload_days, 30)

  @impl true
  def unit, do: :days

  @impl true
  def prune(ctx, days, dry_run) do
    if dry_run,
      do: Arca.ExecutionPayloads.count_older_than_days(ctx, days),
      else: Arca.ExecutionPayloads.delete_older_than_days(ctx, days)
  end
end
