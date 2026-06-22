# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ComponentsLive.Editor do
  @moduledoc """
  Pure data-transformation helpers extracted from `PrismWeb.ComponentsLive`.

  These functions perform validation, parsing, serialization and formatting on
  plain data only — they never touch the socket, assigns, or rendered markup.
  """

  @array_policy_fields ~w(allowed_domains allowed_methods allowed_private_ips allowed_tools allowed_paths allowed_actions)

  # Build a component reference from its parts: e.g.
  # ("catalyst", "moonmoon69", "supabase", "1.0.0") -> "catalyst:moonmoon69.supabase:1.0.0"
  def build_ref_from_parts(type, publisher, name, version) do
    base = if publisher && publisher != "", do: "#{publisher}.#{name}", else: name
    ref = if type && type != "", do: "#{type}:#{base}", else: base
    if version, do: "#{ref}:#{version}", else: ref
  end

  def format_push_error(reason) when is_binary(reason), do: "Push failed: #{reason}"

  def format_push_error({:error, msg}) when is_binary(msg),
    do: "Push failed: #{msg}"

  def format_push_error(reason), do: "Push failed: #{inspect(reason)}"

  def policy_value(policy, field) when is_map(policy) do
    policy[field] || policy[String.to_existing_atom(field)]
  rescue
    ArgumentError -> policy[field]
  end

  def policy_value(_, _), do: nil

  def format_policy_for_edit(value, :array) when is_list(value), do: Enum.join(value, ", ")

  def format_policy_for_edit(value, :json) when is_map(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value)
    end
  end

  def format_policy_for_edit(value, _type), do: to_string(value)

  def parse_policy_for_save(value, field)
      when field in [
             "allowed_domains",
             "allowed_methods",
             "allowed_private_ips",
             "allowed_tools",
             "allowed_paths",
             "allowed_actions"
           ] do
    # Try JSON array first, fall back to comma-separated
    case Jason.decode(value) do
      {:ok, list} when is_list(list) ->
        case Jason.encode(list) do
          {:ok, json} -> json
          {:error, _} -> "[]"
        end

      _ ->
        list =
          value
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        case Jason.encode(list) do
          {:ok, json} -> json
          {:error, _} -> "[]"
        end
    end
  end

  def parse_policy_for_save(value, "rate_limit") do
    case Jason.decode(value) do
      {:ok, _map} -> value
      _ -> value
    end
  end

  def parse_policy_for_save("true", "is_public"), do: "true"
  def parse_policy_for_save(_, "is_public"), do: "false"
  def parse_policy_for_save(value, _field), do: value

  def parse_policy_for_save_empty(field) when field in @array_policy_fields, do: "[]"
  def parse_policy_for_save_empty(_field), do: ""

  def type_sort_order("catalyst"), do: 0
  def type_sort_order("reagent"), do: 1
  def type_sort_order("formula"), do: 2
  def type_sort_order("tincture"), do: 3
  def type_sort_order(_), do: 4
end
