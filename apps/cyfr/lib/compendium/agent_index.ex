# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AgentIndex do
  @moduledoc """
  The `agents` rows: a derived index of the estate's `aqua/` tree.

  The tree is the source. After every write to it — a role created,
  edited or dropped, the seed synced — the index is rewritten from what
  the overlay serves: one row per soul or role, with the digest of the
  file's bytes (its revision) and of its security-relevant subset
  (`Compendium.AquaAgent.to_manifest/1`, its capability). Every revision's
  bytes are kept by digest (`Arca.AgentRevisions`) before the row names
  it, so a turn that pins a revision can always retrieve it. A file that
  fails to parse leaves no row and is reported; the index is never a
  second mutable source, and a sync that cannot read the tree leaves the
  rows as they were.

  A sync sweeps the estate's activation and live-shape caches: an agent
  is a consent source (`Compendium.AgentSource`), and its shape must be
  re-derived from the file as it now stands.
  """

  alias Arca.Schemas.Agent
  alias Compendium.{AquaAgent, AquaPath}
  alias Sanctum.Context

  @doc "Rewrite the athanor's rows from its tree."
  @spec sync(Context.t()) :: {:ok, [Agent.t()]} | {:error, term()}
  def sync(%Context{} = ctx) do
    with {:ok, agents, _errors} <- AquaAgent.list(ctx),
         {:ok, rows} <- rows_for(ctx, agents),
         {:ok, replaced} <- Arca.AgentStorage.replace_all(Context.athanor!(ctx), rows) do
      Compendium.Registry.invalidate_executor_caches(ctx)
      {:ok, replaced}
    end
  end

  @doc "The athanor's rows, the soul first, then the roles by name."
  @spec list(Context.t()) :: {:ok, [Agent.t()]} | {:error, term()}
  def list(%Context{} = ctx) do
    with {:ok, rows} <- Arca.AgentStorage.list(Context.athanor!(ctx)) do
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
    with {:ok, bytes} <- Arca.get(ctx, AquaPath.agent_file(name)),
         {:ok, revision} <- Arca.AgentRevisions.put(Context.athanor!(ctx), bytes),
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
