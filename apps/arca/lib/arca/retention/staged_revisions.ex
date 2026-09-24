# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Retention.StagedRevisions do
  @moduledoc """
  Staged revisions no pointer, draft or pin keeps, older than N days, go
  (`Arca.StorageGC` owns the roots and the collection order). The same
  sweep finishes the committed moves that never finished; a repair writes
  the unit's pending generation before it touches a served byte, so the
  projection of the root derives the finished unit again with nothing
  else asked (`Arca.StorageProjectionChanges`).

  Collection deletes objects a successor boot may be staging against, so
  it runs only on a member that holds its slot in the cell
  (`Arca.ControlPlane.held?/0`): anywhere else it refuses as
  `{:error, :control_plane_lost}`. One sweep collects at most `limit/0`
  prefixes per athanor; the next takes up where it stopped.
  """
  @behaviour Arca.Retention.Kind

  alias Arca.Retention.Kind

  @impl true
  def key, do: "staging_days"

  @impl true
  def default, do: Kind.configured(:staging_days, 1)

  @impl true
  def unit, do: :days

  @doc "How many prefixes one sweep of one athanor collects or repairs."
  @spec limit() :: pos_integer()
  def limit, do: Kind.configured(:staging_sweep_limit, 200)

  @impl true
  def prune(%Prima.Actor{} = actor, days, dry_run) do
    with :ok <- held(),
         {:ok, report} <-
           Arca.StorageGC.sweep(actor,
             grace_ms: days * 86_400_000,
             limit: limit(),
             dry_run: dry_run
           ) do
      {:ok, report.collected}
    end
  end

  # The collection is this member's only while it holds its slot; a member
  # that does not refuses rather than deleting objects a successor may be
  # staging against.
  defp held do
    if Arca.ControlPlane.held?(), do: :ok, else: {:error, :control_plane_lost}
  end
end
