# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Retention.ProjectionTombstones do
  @moduledoc """
  The deletion evidence of seeded units that the projection of their root
  has fully consumed, older than N days, goes
  (`Arca.StorageProjectionChanges.prune_acknowledged_tombstones/3`, which
  owns what fully consumed means). A tombstone still pending, or not yet
  ready, stays whatever its age, and the root's epoch is never touched:
  a unit recreated later still takes a generation above every one it held.

  Every seeded root is walked in turn (`Arca.Storage.overlay_roots/0`);
  the first root whose store cannot answer ends the kind with its error.
  """
  @behaviour Arca.Retention.Kind

  alias Arca.Retention.Kind

  @impl true
  def key, do: "projection_tombstone_days"

  @impl true
  def default, do: Kind.configured(:projection_tombstone_days, 7)

  @impl true
  def unit, do: :days

  @impl true
  def prune(%Cyfr.Actor{} = actor, days, dry_run) do
    opts = [before: Kind.days_cutoff(days), dry_run: dry_run]

    Enum.reduce_while(Arca.Storage.overlay_roots(), {:ok, 0}, fn root, {:ok, total} ->
      case Arca.StorageProjectionChanges.prune_acknowledged_tombstones(actor, root, opts) do
        {:ok, count} -> {:cont, {:ok, total + count}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
