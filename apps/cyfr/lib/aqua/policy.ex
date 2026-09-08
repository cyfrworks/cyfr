# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Policy do
  @moduledoc """
  What an AUTHORED tool policy may say — the semantic rule the interactive
  write doors (the `aqua` tool, the AQUA page) apply on top of the grammar
  `Compendium.AquaAgent.check_tool_policy/1` holds every file to.

  Three layers, each with one job. The parser keeps grammar only, so a
  hand-edited file still loads. The doors refuse what a person must not be
  able to write: an automatic destructive or external action on any agent,
  an `ask` on a role (a cloned role's answer is a tool result, not a turn —
  it has no card to raise), a glob whose actions include one of those, and
  a UI event held at anything but `auto`. The runtime
  (`Aqua.ToolGrants.effective/2`) normalises whatever loaded anyway, so a
  file written past this door reaches the guest already demoted.
  """

  alias Aqua.Actions
  alias Aqua.VirtualTools
  alias Compendium.AquaAgent

  @type agent_type :: String.t()

  @doc """
  `:ok`, or `{:error, sentence}` — the sentence is the person's.
  """
  @spec check_authored(map(), agent_type()) :: :ok | {:error, String.t()}
  def check_authored(policy, agent_type) when is_map(policy) and is_binary(agent_type) do
    role? = agent_type == AquaAgent.role_type()

    Enum.find_value(policy, :ok, fn {key, value} ->
      cond do
        role? and value == "ask" ->
          {:error,
           "#{key} cannot be held at ask on a role — a cloned role has no card to raise; " <>
             "grant it (auto) or leave it out"}

        value == "auto" ->
          auto_refusal(key)

        true ->
          nil
      end
    end)
  end

  def check_authored(_policy, _agent_type), do: :ok

  defp auto_refusal(key) do
    case String.split(key, ".", parts: 2) do
      [tool, "*"] ->
        case Enum.reject(Actions.actions_of(tool), &Actions.auto_permitted?(tool, &1)) do
          [] ->
            nil

          asking ->
            {:error,
             "#{key} at auto would cover #{Enum.map_join(asking, ", ", &"#{tool}.#{&1}")}, " <>
               "which always asks — list the actions instead"}
        end

      [tool, action] ->
        cond do
          VirtualTools.auto_only?(tool, action) -> nil
          Actions.kind_for(tool, action) == nil -> nil
          Actions.auto_permitted?(tool, action) -> nil
          true -> {:error, "#{key} always asks — it cannot be set to auto"}
        end

      _ ->
        nil
    end
  end

  @doc """
  The one rule for a UI event: `request_setup.open` is answered by the
  guest in place, so a policy that holds it at `ask` names a card nothing
  can execute.
  """
  @spec check_auto_only(map()) :: :ok | {:error, String.t()}
  def check_auto_only(policy) when is_map(policy) do
    Enum.find_value(policy, :ok, fn {key, value} ->
      case String.split(key, ".", parts: 2) do
        [tool, action] ->
          if VirtualTools.auto_only?(tool, action) and value != "auto",
            do: {:error, "#{key} runs on its own — it is auto or absent, never ask"}

        _ ->
          nil
      end
    end)
  end
end
