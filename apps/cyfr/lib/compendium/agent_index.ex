# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AgentIndex do
  @moduledoc """
  The `agents` rows: a derived index of the estate's `aqua/` tree.

  The tree is the source. After every write to it — a role created,
  edited or dropped, the seed synced — the index is rewritten from what
  the overlay serves: one row per soul or role, with the digest of the
  file's bytes (its revision) and of its security-relevant subset
  (`Compendium.AquaAgent.to_manifest/1`, its capability). A file that
  fails to parse leaves no row and is reported; the index is never a
  second mutable source, and a sync that cannot read the tree leaves the
  rows as they were.
  """

  alias Arca.Schemas.Agent
  alias Compendium.{AquaAgent, AquaPath}
  alias Sanctum.Context

  @doc "Rewrite the athanor's rows from its tree."
  @spec sync(Context.t()) :: {:ok, [Agent.t()]} | {:error, term()}
  def sync(%Context{} = ctx) do
    with {:ok, agents, _errors} <- AquaAgent.list(ctx),
         {:ok, rows} <- rows_for(ctx, agents) do
      Arca.AgentStorage.replace_all(Context.athanor!(ctx), rows)
    end
  end

  @doc "The athanor's rows, the soul first, then the roles by name."
  @spec list(Context.t()) :: {:ok, [Agent.t()]} | {:error, term()}
  def list(%Context{} = ctx) do
    with {:ok, rows} <- Arca.AgentStorage.list(Context.athanor!(ctx)) do
      {:ok, Enum.sort_by(rows, &{&1.kind != AquaAgent.soul_type(), &1.name})}
    end
  end

  defp rows_for(ctx, agents) do
    athanor_id = Context.athanor!(ctx)
    now = DateTime.utc_now()

    Enum.reduce_while(agents, {:ok, []}, fn agent, {:ok, acc} ->
      with {:ok, bytes} <- Arca.get(ctx, AquaPath.agent_file(agent.name)),
           {:ok, capability} <- AquaAgent.capability_digest(agent) do
        {:cont,
         {:ok,
          [
            %{
              id: Cyfr.UUID7.generate_id("agt"),
              athanor_id: athanor_id,
              name: agent.name,
              kind: AquaAgent.type_of(agent),
              revision_digest: Cyfr.Digest.sha256(bytes),
              capability_digest: capability,
              catalyst_ref: agent.catalyst_ref,
              disabled: agent.disabled == true,
              synced_at: now
            }
            | acc
          ]}}
      else
        {:error, reason} -> {:halt, {:error, {:agent_unreadable, agent.name, reason}}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end
end
