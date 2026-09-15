# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Delegation do
  @moduledoc """
  What a formula's child of the same formula may be.

  A formula's roster is the `sub_agents` its admitted input carries
  (`roster/1`), each a map with a `name`. CYFR takes it from the input it
  admitted and stages for the formula and keeps it with the formula's
  attempt (`Cyfr.Execution.Attempt`); a runner's copy of the input is never
  read.

  A formula invoking itself is delegation when there is a roster to
  delegate from, and the roster is then the only source of what a delegate
  may be (`input/4`): the child must name a `role` the roster lists, and
  its `tool_policy`, `system` and roster are the roster entry's, whatever
  the guest's request carried, so a model-written child input can never
  widen the policy the parent was admitted with. A parent with no roster (a
  delegate itself, or a formula that recurses plainly) delegates to nobody:
  a child of the same formula that names a role or carries a policy or a
  roster is refused, and one that carries none of those is the ordinary
  recursion it looks like. Any other reference is an ordinary child, its
  input its own.
  """

  @host_controlled ~w(role tool_policy sub_agents)

  @doc "The delegation roster a formula's input carries: its `sub_agents` that name themselves, or `[]`."
  @spec roster(term()) :: [map()]
  def roster(%{"sub_agents" => roster}) when is_list(roster),
    do: Enum.filter(roster, &(is_map(&1) and is_binary(&1["name"])))

  def roster(_input), do: []

  @doc """
  The input a child of `reference` is admitted with, for a parent formula
  of `parent_ref` holding `roster`: `{:ok, input}`, or
  `{:error, {:delegation_refused, sentence}}`.
  """
  @spec input(String.t(), map(), String.t() | nil, [map()]) ::
          {:ok, map()} | {:error, {:delegation_refused, String.t()}}
  def input(reference, input, parent_ref, roster) when is_map(input) and is_list(roster) do
    cond do
      not (is_binary(parent_ref) and same_component?(reference, parent_ref)) ->
        {:ok, input}

      roster != [] ->
        delegate_from(roster, input)

      Enum.any?(@host_controlled, &Map.has_key?(input, &1)) ->
        {:error,
         {:delegation_refused,
          "this formula has no roster to delegate from — a child of it names no role and carries no policy"}}

      true ->
        {:ok, input}
    end
  end

  defp delegate_from(roster, input) do
    role = input["role"]

    case Enum.find(roster, &(&1["name"] == role)) do
      nil when is_binary(role) and role != "" ->
        {:error, {:delegation_refused, "the roster lists no role #{inspect(role)}"}}

      nil ->
        {:error,
         {:delegation_refused, "a delegate of the same formula must name a role its roster lists"}}

      entry ->
        {:ok,
         input
         |> Map.put("tool_policy", entry["tool_policy"] || %{})
         |> Map.put("system", entry["prompt"] || "")
         |> Map.put("sub_agents", [])
         |> put_if_binary("catalyst_ref", entry["catalyst_ref"])
         |> put_if_binary("model", entry["model"])}
    end
  end

  defp put_if_binary(input, key, value) when is_binary(value) and value != "",
    do: Map.put(input, key, value)

  defp put_if_binary(input, _key, _value), do: input

  defp same_component?(a, b) do
    case {Cyfr.ComponentRef.to_name_ref(a), Cyfr.ComponentRef.to_name_ref(b)} do
      {{:ok, name_a}, {:ok, name_b}} -> name_a == name_b
      _ -> false
    end
  end
end
