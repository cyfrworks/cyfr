# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.Normalize do
  @moduledoc false
  #
  # Typed normalization for digest inputs: validate, canonicalize, reject.
  #
  # A digest is only as trustworthy as the normalization in front of it. Two
  # inputs that mean the same thing must produce the same bytes (so lists
  # are sorted and deduplicated), and anything ambiguous must be refused
  # rather than coerced (so unknown keys, non-strings and loose durations
  # are errors). Every function takes the error tag its caller reports
  # under, so `ShapeDigest` and `CommitDigest` keep their own taxonomies.

  alias Sanctum.ComponentRef

  # Durations must be exact here. Sanctum.Policy.parse_duration/1 tolerates
  # repeated trailing suffixes ("5mm" parses as 5 minutes) — harmless for a
  # timeout, unacceptable for a digest input, where it would give one
  # duration two spellings.
  @duration_re ~r/^\d+(ms|s|m|h)$/

  def only_keys(map, allowed, tag) when is_map(map) do
    case Enum.find(Map.keys(map), &(&1 not in allowed)) do
      nil -> :ok
      key -> {:error, {tag, :unknown_field, inspect(key)}}
    end
  end

  def only_keys(other, _allowed, tag),
    do: {:error, {tag, :input, "expected a map, got: #{inspect(other)}"}}

  def enum(map, key, allowed, tag) do
    case Map.get(map, key) do
      value when value in [nil] ->
        {:error, {tag, key, "is required"}}

      value ->
        if value in allowed,
          do: {:ok, value},
          else: {:error, {tag, key, "must be one of #{inspect(allowed)}"}}
    end
  end

  def component_ref(map, key, tag) do
    with {:ok, value} when is_binary(value) <- {:ok, Map.get(map, key)},
         {:ok, parsed} <- ComponentRef.parse(value) do
      if parsed.version do
        {:error, {tag, key, "must be a name-level ref (no version)"}}
      else
        {:ok, value}
      end
    else
      {:ok, other} ->
        {:error, {tag, key, "must be a component ref string, got: #{inspect(other)}"}}

      {:error, reason} ->
        {:error, {tag, key, "is not a valid component ref: #{reason}"}}
    end
  end

  def optional_string(map, key, tag) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" -> {:ok, value}
      other -> {:error, {tag, key, "must be a non-empty string, got: #{inspect(other)}"}}
    end
  end

  def required_string(map, key, tag) do
    case optional_string(map, key, tag) do
      {:ok, nil} -> {:error, {tag, key, "is required"}}
      other -> other
    end
  end

  @doc false
  # A sorted, deduplicated list of non-empty strings. Order carries no
  # meaning in a grant, so it must carry none in the digest.
  def string_set(map, key, tag) do
    case Map.get(map, key, []) do
      list when is_list(list) ->
        if Enum.all?(list, &(is_binary(&1) and &1 != "")) do
          {:ok, list |> Enum.uniq() |> Enum.sort()}
        else
          {:error, {tag, key, "must be a list of non-empty strings"}}
        end

      other ->
        {:error, {tag, key, "must be a list, got: #{inspect(other)}"}}
    end
  end

  @doc false
  # Expanded tool.action pairs. A bare tool name or a glob would be a group
  # by another name, so both are refused.
  def tool_actions(map, key, tag) do
    with {:ok, actions} <- string_set(map, key, tag) do
      case Enum.find(actions, &(not valid_tool_action?(&1))) do
        nil ->
          {:ok, actions}

        bad ->
          {:error,
           {tag, key,
            "must be expanded tool.action pairs — #{inspect(bad)} is not one " <>
              "(groups and wildcards are never a capability)"}}
      end
    end
  end

  defp valid_tool_action?(action) do
    case String.split(action, ".") do
      [tool, verb] -> tool != "" and verb != "" and not String.contains?(action, "*")
      _ -> false
    end
  end

  @doc false
  # Declared needs: name + type, both required. The reason text is
  # deliberately excluded — it is prose shown to the operator, and editing
  # it must not invalidate a consent.
  def needs(map, key, tag) do
    case Map.get(map, key, []) do
      list when is_list(list) ->
        list
        |> Enum.reduce_while({:ok, []}, fn need, {:ok, acc} ->
          case normalize_need(need, key, tag) do
            {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, needs} -> {:ok, needs |> Enum.uniq() |> Enum.sort_by(& &1["name"])}
          error -> error
        end

      other ->
        {:error, {tag, key, "must be a list, got: #{inspect(other)}"}}
    end
  end

  defp normalize_need(need, _key, tag) when is_map(need) do
    with :ok <- only_keys(need, ~w(name type fields scopes)a, tag),
         {:ok, name} <- required_string(need, :name, tag),
         {:ok, type} <- required_string(need, :type, tag),
         {:ok, fields} <- string_set(need, :fields, tag),
         {:ok, scopes} <- string_set(need, :scopes, tag) do
      {:ok, %{"name" => name, "type" => type, "fields" => fields, "scopes" => scopes}}
    end
  end

  defp normalize_need(other, key, tag) do
    {:error, {tag, key, "each need must be a map, got: #{inspect(other)}"}}
  end

  @doc false
  # Declared capabilities: string lists (domains, methods, paths…) and the
  # numeric/duration limits. Values are canonicalized, never interpreted —
  # what a capability means is the loader's business, not the digest's.
  def caps(map, key, tag) do
    case Map.get(map, key, %{}) do
      caps when is_map(caps) ->
        Enum.reduce_while(caps, {:ok, %{}}, fn {cap_key, value}, {:ok, acc} ->
          case normalize_cap(cap_key, value, tag) do
            {:ok, {k, v}} -> {:cont, {:ok, Map.put(acc, k, v)}}
            error -> {:halt, error}
          end
        end)

      other ->
        {:error, {tag, key, "must be a map, got: #{inspect(other)}"}}
    end
  end

  defp normalize_cap(key, value, tag) when is_atom(key),
    do: normalize_cap(Atom.to_string(key), value, tag)

  defp normalize_cap(key, value, tag) when is_binary(key) do
    cond do
      is_list(value) ->
        if Enum.all?(value, &(is_binary(&1) and &1 != "")) do
          {:ok, {key, value |> Enum.uniq() |> Enum.sort()}}
        else
          {:error, {tag, :caps, "#{key} must be a list of non-empty strings"}}
        end

      is_integer(value) ->
        {:ok, {key, value}}

      is_boolean(value) ->
        {:ok, {key, value}}

      is_binary(value) ->
        if Regex.match?(@duration_re, value) do
          {:ok, {key, value}}
        else
          {:error,
           {tag, :caps,
            "#{key} must be an exact duration like \"30s\" or \"5m\", got: #{inspect(value)}"}}
        end

      true ->
        {:error, {tag, :caps, "#{key} has an uncanonicalizable value: #{inspect(value)}"}}
    end
  end

  defp normalize_cap(key, _value, tag),
    do: {:error, {tag, :caps, "key must be a string, got: #{inspect(key)}"}}

  @doc false
  def duration(map, key, tag) do
    with {:ok, value} <- required_string(map, key, tag) do
      if Regex.match?(@duration_re, value) do
        {:ok, value}
      else
        {:error, {tag, key, "must be an exact duration like \"30s\", got: #{inspect(value)}"}}
      end
    end
  end

  @doc false
  def put_optional(map, _key, nil), do: map
  def put_optional(map, key, value), do: Map.put(map, key, value)
end
