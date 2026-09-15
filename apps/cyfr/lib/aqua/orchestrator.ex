# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Orchestrator do
  @moduledoc """
  The agent a turn is addressed to — the estate's soul or one of its roles
  — as the runner carries it from the pick to the running turn.

  A pick is a NAME: the roster entry an `@tom` matched, the entry the
  picker sent, the previous turn's agent, or the estate's first. The
  agent lives in the estate in focus — a tape runs its own estate's soul
  and roles alone — so the name is the whole identity: the thread
  row (`orchestrator`), the standing-grant key and the recovery read after
  a restart are written in terms of it.

  Between turns the runner keeps the IDENTITY only. Every turn resolves
  it again (`resolve/2`, inside the turn-start task, never in the
  runner's loop): the current enabled definition — `agent`, the
  string-keyed projection a turn reads, with the
  AUTHORED policy under `"tool_policy"` — and then the EFFECTIVE policy
  (`policy`, `with_grants/2`) composed from the standing decisions made
  since. Keeping the two apart is what lets a revoked "always" go back to
  asking: a composition that started from the previous composition could
  never recover an `ask` it had already promoted.

  The word is the code's, not the product's: a person addresses a soul or
  a role; the row, the runner and the tool option call whichever one
  answers the turn its orchestrator.
  """

  alias Sanctum.Context

  @type agent :: %{String.t() => term()}

  @type t :: %__MODULE__{
          name: String.t(),
          agent: agent() | nil,
          policy: map() | nil
        }

  @enforce_keys [:name]
  defstruct [:name, :agent, :policy]

  @doc "A pick by name, from the estate in focus."
  @spec by_name(String.t()) :: t()
  def by_name(name) when is_binary(name), do: %__MODULE__{name: name}

  @doc "The identity of a pick, resolved or not — what the runner keeps between turns."
  @spec identity(t()) :: t()
  def identity(%__MODULE__{name: name}), do: by_name(name)

  @doc "A resolved agent, from its run-time detail."
  @spec resolved(agent()) :: t()
  def resolved(%{"name" => name} = agent) when is_binary(name),
    do: %__MODULE__{name: name, agent: agent}

  @doc "The pick a thread row recorded, or `nil` when no turn has run in it."
  @spec from_thread(%{:orchestrator => String.t() | nil, optional(atom()) => term()}) ::
          t() | nil
  def from_thread(%{orchestrator: name}) when is_binary(name), do: by_name(name)
  def from_thread(_row), do: nil

  @doc "Whether the run-time detail has been read."
  @spec resolved?(t()) :: boolean()
  def resolved?(%__MODULE__{agent: %{}}), do: true
  def resolved?(%__MODULE__{}), do: false

  @doc """
  Read the agent's CURRENT definition from the estate's tree — always,
  even for a pick that was resolved before: a definition edited or
  disabled since the last turn must not run as it was.
  `{:error, :no_orchestrator}` when the tree holds no such enabled agent
  — a turn fails here, in its task, so an unknown mention never holds the
  send hostage to a catalog read.
  """
  @spec resolve(Context.t(), t()) :: {:ok, t()} | {:error, :no_orchestrator}
  def resolve(%Context{} = ctx, %__MODULE__{} = pick) do
    with {:ok, orchestrator, _roster} <- resolve_with_roster(ctx, pick), do: {:ok, orchestrator}
  end

  @doc """
  `resolve/2` that also hands back the roster it read — the estate's whole
  tree, once — so a turn composes its roles from the same read rather
  than reading the tree twice. A disabled agent is not on the roster and
  so does not resolve.
  """
  @spec resolve_with_roster(Context.t(), t()) ::
          {:ok, t(), [agent()]} | {:error, :no_orchestrator}
  def resolve_with_roster(%Context{} = ctx, %__MODULE__{name: name}) do
    with {:ok, roster} <- Aqua.AgentConfig.roster(ctx),
         %{} = detail <- Enum.find(roster, &(&1["name"] == name)) do
      agent = %{
        "name" => name,
        "title" => detail["title"] || name,
        "catalyst_ref" => detail["catalyst_ref"],
        "model" => detail["model"],
        "tool_policy" => detail["tool_policy"] || %{}
      }

      {:ok, resolved(agent), roster}
    else
      _ -> {:error, :no_orchestrator}
    end
  end

  @doc """
  The agent's EFFECTIVE policy — composed by `with_grants/2`, else the
  authored one held to the runtime ceiling; empty until resolved.
  """
  @spec tool_policy(t() | nil) :: map()
  def tool_policy(%__MODULE__{policy: %{} = policy}), do: policy

  def tool_policy(%__MODULE__{agent: %{} = agent}),
    do: Aqua.ToolGrants.resolve(agent["tool_policy"] || %{}, [])

  def tool_policy(_orchestrator), do: %{}

  @doc "The authored policy, as the file says it — never handed to a turn."
  @spec authored_policy(t() | nil) :: map()
  def authored_policy(%__MODULE__{agent: %{} = agent}), do: agent["tool_policy"] || %{}
  def authored_policy(_orchestrator), do: %{}

  @doc """
  The authored policy composed with the standing answers people already
  gave (`Aqua.ToolGrants.resolve/2`), so a "never" from three weeks ago
  is not re-offered as a card and a restart does not forget a "for this
  thread". Composed from the AUTHORED policy every time — never
  from a previous composition — so a decision withdrawn since is gone
  from the next turn. A pick has to be resolved first.
  """
  @spec with_grants(t(), [Arca.Schemas.ToolGrant.t()]) :: t()
  def with_grants(%__MODULE__{agent: %{}} = orchestrator, grants) when is_list(grants) do
    %{orchestrator | policy: Aqua.ToolGrants.resolve(authored_policy(orchestrator), grants)}
  end

  @doc "The agent as a turn is composed from it: the detail, with the effective policy in place of the authored one."
  @spec for_turn(t()) :: agent()
  def for_turn(%__MODULE__{agent: %{} = agent} = orchestrator),
    do: Map.put(agent, "tool_policy", tool_policy(orchestrator))
end
