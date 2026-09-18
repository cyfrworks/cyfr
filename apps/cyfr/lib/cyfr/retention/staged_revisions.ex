# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Retention.StagedRevisions do
  @moduledoc """
  Staged revisions no pointer, draft or pin keeps, older than N days, go
  (`Arca.StorageGC` owns the roots and the collection order). The same
  sweep finishes the committed moves that never finished.

  Collection deletes objects a successor boot may be staging against, so
  it runs only on the boot that owns the control plane: anywhere else it
  refuses as `{:error, :control_plane_lost}`. One sweep collects at most
  `limit/0` prefixes per athanor; the next takes up where it stopped.
  """
  @behaviour Cyfr.Retention.Kind

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

  @impl true
  def prune(ctx, days, dry_run) do
    with :ok <- Cyfr.ControlPlane.assert_owner(),
         {:ok, report} <-
           Arca.StorageGC.sweep(Sanctum.Context.actor(ctx),
             grace_ms: days * 86_400_000,
             limit: limit(),
             dry_run: dry_run
           ) do
      {:ok, report.collected}
    end
  end
end
