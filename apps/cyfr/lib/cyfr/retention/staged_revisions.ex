# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Retention.StagedRevisions do
  @moduledoc """
  Staged revisions no pointer, draft or pin keeps, older than N days, go
  (`Arca.StorageGC` owns the roots and the collection order). The same
  sweep finishes the committed moves that never finished.

  Collection deletes objects a successor boot may be staging against, so
  it runs only on a member that holds its slot in the cell
  (`Arca.ControlPlane.held?/0`): anywhere else it refuses as
  `{:error, :control_plane_lost}`. One sweep collects at most `limit/0`
  prefixes per athanor; the next takes up where it stopped.

  A sweep that finished a move re-derives the estate's agent index. The
  index is derived from what the overlay SERVES of the `aqua/` tree, and
  a commit whose move did not finish leaves the row committed with its
  bytes not yet where readers read — so a role published by such a commit
  is absent from the index until something writes the tree again. Its
  three writers are the aqua tool, `Arca.Files` and provisioning, and none
  of them runs because a sweep repaired something. This is where the
  repair is known, and it is the lowest place above `Arca.StorageGC` that
  may name the component domain: the sweep itself sits below it.
  """
  @behaviour Cyfr.Retention.Kind

  require Logger

  @impl true
  def key, do: "staging_days"

  @impl true
  def default,
    do: Keyword.get(Application.get_env(:cyfr, Cyfr.Retention, []), :staging_days, 1)

  @impl true
  def unit, do: :days

  @doc "How many prefixes one sweep of one athanor collects or repairs."
  @spec limit() :: pos_integer()
  def limit,
    do: Keyword.get(Application.get_env(:cyfr, Cyfr.Retention, []), :staging_sweep_limit, 200)

  # The collection is this member's only while it holds its slot; a member
  # that does not refuses rather than deleting objects a successor may be
  # staging against.
  defp held do
    if Arca.ControlPlane.held?(), do: :ok, else: {:error, :control_plane_lost}
  end

  @impl true
  def prune(ctx, days, dry_run) do
    with :ok <- held(),
         {:ok, report} <-
           Arca.StorageGC.sweep(Sanctum.Context.actor(ctx),
             grace_ms: days * 86_400_000,
             limit: limit(),
             dry_run: dry_run
           ) do
      resync_agents(ctx, report)
      {:ok, report.collected}
    end
  end

  # The sweep counts the moves it finished without naming their roots, so
  # any repair is a reason to re-derive: the index is small beside the
  # estate the sweep just walked, a re-derivation of an unchanged tree
  # writes the rows it already held, and a repair is rare. The sweep's own
  # answer is what `prune/3` returns either way — the collection happened,
  # and an index that could not be re-derived is a warning, not a failed
  # sweep.
  defp resync_agents(_ctx, %{repaired: 0}), do: :ok

  defp resync_agents(ctx, %{repaired: repaired}) do
    case Compendium.AgentIndex.sync(ctx) do
      {:ok, _rows} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Cyfr.Retention.StagedRevisions] #{repaired} move(s) finished and the agent " <>
            "index could not be re-derived: #{inspect(reason)} — a role published by one " <>
            "of them stays out of the index until the next write to the tree"
        )

        :ok
    end
  end
end
