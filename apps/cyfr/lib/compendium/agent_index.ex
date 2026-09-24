# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AgentIndex do
  @moduledoc """
  The `agents` rows: a derived index of the estate's `aqua/` tree.

  The tree is the source. After a write to it — a role created, edited
  or dropped, the seed synced — the index is rewritten from what the
  overlay serves before it is read again: one row per soul or role, with
  the digest of the
  file's bytes (its revision) and of its security-relevant subset
  (`Compendium.AquaAgent.to_manifest/1`, its capability). Every revision's
  bytes are kept by digest (`Arca.AgentRevisions`) before the row names
  it, so a turn that pins a revision can always retrieve it. A file that
  fails to parse leaves no row and is reported; the index is never a
  second mutable source, and a sync that cannot read the tree leaves the
  rows as they were.

  The index is the `aqua` root's projection, kept by
  `Compendium.ProjectionReconciler`: every change of a unit under `aqua/`
  is stamped for it, `list/1` waits for it to reflect every one
  (`Compendium.ProjectionReconciler.await/2`), and a rewrite is made
  against a snapshot of the root and acknowledged with it. A unit still
  pending holds the whole rewrite back.

  A rewrite sweeps the estate's activation and live-shape caches: an agent
  is a consent source (`Compendium.AgentSource`), and its shape must be
  re-derived from the file as it now stands.
  """

  alias Compendium.{AquaAgent, AquaPath, ProjectionReconciler}
  alias Sanctum.Context

  @root "aqua"

  @doc """
  Rewrite the athanor's rows from its tree, through the projection
  reconciler (`Compendium.ProjectionReconciler.reconcile/3`).

  `:claim` in `opts` is the provisioning claim the rewrite is made under,
  and then the rows are written in the same transaction that holds it
  (`Arca.AgentStorage.replace_projection/4`): a sync whose claim a
  successor took publishes nothing and answers `{:error, :claim_lost}`. A
  sync with no claim — a person editing a role — has none to lose.
  `{:error, :projection_unavailable}` when a unit under `aqua/` is still
  pending or three rewrites conflicted.
  """
  @spec sync(Context.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def sync(ctx, opts \\ [])

  def sync(%Context{} = ctx, opts) when is_list(opts) do
    with {:ok, %{rows: rows}} <-
           ProjectionReconciler.reconcile(ctx, @root, Keyword.take(opts, [:claim])),
         do: {:ok, rows}
  end

  @doc false
  # The rows the tree derives, for the reconciler's rewrite. Reads the tree
  # directly: this runs behind the barrier.
  @spec derive(Context.t()) :: {:ok, [map()]} | {:error, term()}
  def derive(%Context{} = ctx) do
    with {:ok, agents, _errors} <- AquaAgent.list(ctx), do: rows_for(ctx, agents)
  end

  @doc """
  The athanor's rows, the soul first, then the roles by name — once the
  index reflects every change of the tree, else
  `{:error, :projection_unavailable}`.
  """
  @spec list(Context.t()) :: {:ok, [map()]} | {:error, term()}
  def list(%Context{} = ctx) do
    with :ok <- ProjectionReconciler.await(ctx, @root),
         {:ok, rows} <- Arca.AgentStorage.list(Context.actor(ctx)) do
      {:ok, Enum.sort_by(rows, &{&1.kind != AquaAgent.soul_type(), &1.name})}
    end
  end

  @doc """
  One read of the agent's file: keep the bytes, parse the same bytes,
  and answer the revision and capability digests a turn pins.
  """
  @spec snapshot(Context.t(), String.t()) ::
          {:ok,
           %{
             agent: AquaAgent.t(),
             revision_digest: String.t(),
             capability_digest: String.t()
           }}
          | {:error, term()}
  def snapshot(%Context{} = ctx, name) when is_binary(name) do
    with {:ok, bytes} <- Arca.get(Sanctum.Context.actor(ctx), AquaPath.agent_file(name)),
         {:ok, revision} <- Arca.AgentRevisions.put(Context.actor(ctx), bytes),
         {:ok, agent} <- AquaAgent.parse(name, bytes),
         {:ok, capability} <- AquaAgent.capability_digest(agent) do
      {:ok, %{agent: agent, revision_digest: revision, capability_digest: capability}}
    end
  end

  defp rows_for(ctx, agents) do
    athanor_id = Context.athanor!(ctx)
    now = DateTime.utc_now()

    Enum.reduce_while(agents, {:ok, []}, fn agent, {:ok, acc} ->
      case snapshot(ctx, agent.name) do
        {:ok, snap} ->
          {:cont,
           {:ok,
            [
              %{
                id: Cyfr.UUID7.generate_id("agt"),
                athanor_id: athanor_id,
                name: snap.agent.name,
                kind: AquaAgent.type_of(snap.agent),
                revision_digest: snap.revision_digest,
                capability_digest: snap.capability_digest,
                catalyst_ref: snap.agent.catalyst_ref,
                disabled: snap.agent.disabled == true,
                synced_at: now
              }
              | acc
            ]}}

        {:error, reason} ->
          {:halt, {:error, {:agent_unreadable, agent.name, reason}}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end
end
