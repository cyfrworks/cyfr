# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Retention.Builds do
  @moduledoc "Build records: the newest N per athanor survive."
  @behaviour Arca.Retention.Kind

  alias Arca.Retention.Kind

  @impl true
  def key, do: "builds"

  @impl true
  def default, do: Kind.configured(:builds, 100)

  @impl true
  def unit, do: :keep

  @impl true
  def prune(%Cyfr.Actor{} = actor, keep, dry_run),
    do: Arca.BuildRecords.prune(actor, keep, dry_run: dry_run)
end
