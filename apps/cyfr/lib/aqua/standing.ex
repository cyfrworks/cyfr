# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Standing do
  @moduledoc """
  The standing half of a card's decision: whether the answer a person
  gives may stand for calls nobody has seen yet, and the rows it becomes.

  `:once` answers this call alone. `:thread` and `:always` are
  standing allows: both are refused for a destructive or external action,
  and the action's own standing rule — minted onto the card's intent from
  the annotation `Aqua.ToolGrants` reads at the write — has the last word:
  `false` takes no standing answer at all, `"thread"` none at agent
  scope. `:never` is a standing deny, always recordable. The card hides
  the buttons a rule refuses, but the card is a client; the rule is
  decided here, on what the intent carries.
  """

  alias Sanctum.Context

  @type scope :: :once | :thread | :always | :never

  @doc "Whether `scope` may stand for the card's intent."
  @spec check(map(), scope()) :: :ok | {:error, {:scope_not_permitted, term()}}
  def check(intent, scope) when scope in [:thread, :always] do
    standing = Cyfr.Ops.Annotations.standing(intent["standing"])

    cond do
      intent["action_kind"] in ["destructive", "external"] ->
        {:error, {:scope_not_permitted, intent["action_kind"]}}

      standing == false ->
        {:error, {:scope_not_permitted, :never_standing}}

      standing == :thread and scope == :always ->
        {:error, {:scope_not_permitted, :thread_only}}

      true ->
        :ok
    end
  end

  def check(_intent, _scope), do: :ok

  @doc """
  The grant rows a decision writes with itself, for the agent the turn
  runs: none for `:once`, an allow at thread or agent scope, a deny
  at agent scope for `:never`. Checked against the action's standing rule.
  """
  @spec rows(Context.t(), map(), map(), scope()) :: {:ok, [map()]} | {:error, term()}
  def rows(_ctx, _turn, _proposal, :once), do: {:ok, []}

  def rows(%Context{} = ctx, turn, %{"tool" => tool, "action" => action}, scope)
      when scope in [:thread, :always, :never] and is_binary(tool) and is_binary(action) do
    {grant_scope, effect} =
      case scope do
        :thread -> {"thread", "allow"}
        :always -> {"agent", "allow"}
        :never -> {"agent", "deny"}
      end

    with {:ok, row} <-
           Aqua.ToolGrants.row(ctx, %{
             scope: grant_scope,
             effect: effect,
             thread_id: turn.thread_id,
             agent_name: turn.orchestrator,
             tool: tool,
             action: action
           }) do
      {:ok, [row]}
    end
  end

  def rows(_ctx, _turn, _proposal, _scope), do: {:ok, []}

  @doc "The words a standing answer is called by on the tape."
  @spec answer(scope()) :: String.t()
  def answer(:never), do: "\"Never\""
  def answer(:always), do: "\"Always\""
  def answer(:thread), do: "\"Always for this thread\""
  def answer(:once), do: "\"Once\""
end
