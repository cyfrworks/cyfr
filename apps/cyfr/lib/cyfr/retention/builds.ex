# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Retention.Builds do
  @moduledoc "Build records: the newest N per athanor survive."
  @behaviour Cyfr.Retention.Kind

  @impl true
  def key, do: "builds"

  @impl true
  def default, do: Keyword.get(Application.get_env(:cyfr, Cyfr.Retention, []), :builds, 100)

  @impl true
  def unit, do: :keep

  @impl true
  def prune(ctx, keep, dry_run), do: Cyfr.BuildRecords.prune(ctx, keep, dry_run: dry_run)
end
