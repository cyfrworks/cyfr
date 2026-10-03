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

  alias Prima.ComponentRef

  # Durations must be exact here. Prima.Limits.parse_duration/1 tolerates
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

  def only_keys(_other, _allowed, tag),
    do: {:error, {tag, :input, "expected a map"}}

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
      {:ok, _other} ->
        {:error, {tag, key, "must be a component ref string"}}

      {:error, reason} ->
        {:error, {tag, key, "is not a valid component ref: #{reason}"}}
    end
  end

  def optional_string(map, key, tag) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {tag, key, "must be a non-empty string"}}
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

      _other ->
        {:error, {tag, key, "must be a list"}}
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

      _other ->
        {:error, {tag, key, "must be a list"}}
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

  defp normalize_need(_other, key, tag) do
    {:error, {tag, key, "each need must be a map"}}
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

      _other ->
        {:error, {tag, key, "must be a map"}}
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
  # An agent's policy modes: two disjoint string sets. A key in both
  # would be two answers to one question.
  def tool_policy(map, key, tag) do
    case Map.get(map, key) do
      nil ->
        {:ok, nil}

      policy when is_map(policy) ->
        with :ok <- only_keys(policy, ~w(auto ask)a, tag),
             {:ok, auto} <- string_set(policy, :auto, tag),
             {:ok, ask} <- string_set(policy, :ask, tag) do
          overlap = auto -- (auto -- ask)

          if overlap == [] do
            {:ok, %{"auto" => auto, "ask" => ask}}
          else
            {:error, {tag, key, "auto and ask must be disjoint"}}
          end
        end

      _other ->
        {:error, {tag, key, "must be a map"}}
    end
  end

  @doc false
  # The origins a grant admits: a non-empty list of distinct
  # `Prima.Origin` values, answered as their wire spellings in the enum's
  # order, so two lists naming the same origins are one input.
  def origins(map, key, tag) do
    case Map.fetch(map, key) do
      {:ok, [_ | _] = origins} ->
        if Enum.all?(origins, &Prima.Origin.origin?/1) do
          if length(Enum.uniq(origins)) == length(origins),
            do: {:ok, Prima.Origin.to_wire_list(origins)},
            else: {:error, {tag, key, "names an origin twice"}}
        else
          {:error,
           {tag, key, "must name only origins: #{Enum.join(Prima.Origin.spellings(), ", ")}"}}
        end

      {:ok, []} ->
        {:error, {tag, key, "must name at least one origin"}}

      {:ok, _other} ->
        {:error, {tag, key, "must be a list of origins"}}

      :error ->
        {:error, {tag, key, "is required"}}
    end
  end

  # The kinds a subset may name, each with the fields it narrows; `tools`
  # and the limits are their own shapes below.
  @subset_sets %{
    "egress" => ~w(domains methods schemes private_ips),
    "storage" => ~w(paths actions)
  }
  @subset_kinds ~w(egress storage tools limits)
  @limit_integers ~w(max_memory_bytes max_request_size max_response_size max_concurrent_tasks)
  @limit_durations ~w(timeout batch_timeout)

  @doc false
  # A narrowing, per consent-graph node: a record of the kinds whose
  # enforcement point can check a subset (`egress`, `storage`, `tools`,
  # `limits`), each naming only the fields it narrows. The shape alone is
  # checked here; whether each value lies inside the ask and the ceiling is
  # the builder's, which knows the ask (`Sanctum.Consent.BlobBuilder`).
  #
  # Sets are sorted and deduplicated. A field left out keeps its ask and is
  # absent here too, while an explicit empty set grants none and stays an
  # empty set, so the two never read alike. A kind or node that names no
  # field names nothing and is dropped, so a decision spelled with empty
  # records is the same input as one without them. Answers `%{}` when the
  # map carries no subset.
  def subset(map, key, tag) do
    case Map.get(map, key, %{}) do
      subset when is_map(subset) and not is_struct(subset) ->
        subset
        |> Enum.sort()
        |> Enum.reduce_while({:ok, %{}}, fn {node, record}, {:ok, acc} ->
          with {:ok, node} <- subset_node_ref(node, key, tag),
               {:ok, normalized} <- subset_record(node, record, tag) do
            {:cont, {:ok, put_named(acc, node, normalized)}}
          else
            error -> {:halt, error}
          end
        end)

      _other ->
        {:error, {tag, key, "must be a map from consent-graph node to its narrowing"}}
    end
  end

  defp subset_node_ref(node, key, tag) when is_binary(node) do
    case component_ref(%{node: node}, :node, tag) do
      {:ok, node} -> {:ok, node}
      {:error, _} -> {:error, {tag, key, "names a node that is not a name-level component ref"}}
    end
  end

  defp subset_node_ref(_node, key, tag),
    do: {:error, {tag, key, "names a node that is not a name-level component ref"}}

  defp subset_record(node, record, tag) when is_map(record) and not is_struct(record) do
    record
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn {kind, value}, {:ok, acc} ->
      case subset_kind(node, kind, value, tag) do
        {:ok, normalized} -> {:cont, {:ok, put_named(acc, kind, normalized)}}
        error -> {:halt, error}
      end
    end)
  end

  defp subset_record(node, _record, tag),
    do: {:error, {tag, :subset, "#{node} must be a record of resource kinds"}}

  defp subset_kind(node, kind, value, tag) when is_map_key(@subset_sets, kind),
    do: subset_sets(node, kind, value, Map.fetch!(@subset_sets, kind), tag)

  defp subset_kind(node, "tools", value, tag) do
    case tool_actions(%{tools: value}, :tools, tag) do
      {:ok, tools} -> {:ok, tools}
      {:error, {^tag, :tools, why}} -> {:error, {tag, :subset, "#{node} tools #{why}"}}
    end
  end

  defp subset_kind(node, "limits", value, tag), do: subset_limits(node, value, tag)

  defp subset_kind(node, kind, _value, tag) when is_binary(kind) do
    if kind in Enum.map(Prima.ConsentPreview.kinds(), &Atom.to_string/1) do
      {:error,
       {tag, :subset, "#{node}: #{kind} cannot be narrowed; it is granted whole or not at all"}}
    else
      {:error,
       {tag, :subset, "#{node} names a kind that is not one of #{Enum.join(@subset_kinds, ", ")}"}}
    end
  end

  defp subset_kind(node, _kind, _value, tag),
    do:
      {:error,
       {tag, :subset, "#{node} names a kind that is not one of #{Enum.join(@subset_kinds, ", ")}"}}

  defp subset_sets(node, kind, record, fields, tag)
       when is_map(record) and not is_struct(record) do
    record
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn {field, value}, {:ok, acc} ->
      if field in fields do
        case string_set(%{field => value}, field, tag) do
          {:ok, set} ->
            {:cont, {:ok, Map.put(acc, field, set)}}

          {:error, {^tag, _field, why}} ->
            {:halt, {:error, {tag, :subset, "#{node} #{kind}.#{field} #{why}"}}}
        end
      else
        {:halt,
         {:error, {tag, :subset, "#{node} #{kind} narrows only #{Enum.join(fields, ", ")}"}}}
      end
    end)
  end

  defp subset_sets(node, kind, _record, _fields, tag),
    do: {:error, {tag, :subset, "#{node} #{kind} must be a record"}}

  # The limits in `Prima.Limits`' own vocabulary: four non-negative
  # integers, two exact durations and the rate limit's `requests` and
  # `window`, each optional.
  defp subset_limits(node, record, tag) when is_map(record) and not is_struct(record) do
    record
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn {field, value}, {:ok, acc} ->
      case subset_limit(field, value) do
        {:ok, normalized} ->
          {:cont, {:ok, put_named(acc, field, normalized)}}

        {:error, why} ->
          {:halt, {:error, {tag, :subset, "#{node} limits.#{limit_name(field)} #{why}"}}}
      end
    end)
  end

  defp subset_limits(node, _record, tag),
    do: {:error, {tag, :subset, "#{node} limits must be a record"}}

  defp subset_limit(field, value) when field in @limit_integers do
    if is_integer(value) and value >= 0,
      do: {:ok, value},
      else: {:error, "must be a non-negative integer"}
  end

  defp subset_limit(field, value) when field in @limit_durations, do: exact_duration(value)

  defp subset_limit("rate_limit", record) when is_map(record) and not is_struct(record) do
    Enum.reduce_while(Enum.sort(record), {:ok, %{}}, fn
      {"requests", requests}, {:ok, acc} when is_integer(requests) and requests >= 0 ->
        {:cont, {:ok, Map.put(acc, "requests", requests)}}

      {"requests", _requests}, _acc ->
        {:halt, {:error, "requests must be a non-negative integer"}}

      {"window", window}, {:ok, acc} ->
        case exact_duration(window) do
          {:ok, window} -> {:cont, {:ok, Map.put(acc, "window", window)}}
          {:error, why} -> {:halt, {:error, "window " <> why}}
        end

      {_other, _value}, _acc ->
        {:halt, {:error, "names only requests and window"}}
    end)
  end

  defp subset_limit("rate_limit", _value), do: {:error, "must be a record of requests and window"}

  defp subset_limit(_field, _value),
    do:
      {:error,
       "is not a limit; the limits are #{Enum.map_join(Prima.Limits.fields(), ", ", &Atom.to_string/1)}"}

  defp exact_duration(value) when is_binary(value) do
    if Regex.match?(@duration_re, value),
      do: {:ok, value},
      else: {:error, "must be an exact duration like \"30s\" or \"5m\""}
  end

  defp exact_duration(_value), do: {:error, "must be an exact duration like \"30s\" or \"5m\""}

  defp limit_name(field) when is_binary(field) and byte_size(field) <= 64, do: field
  defp limit_name(_field), do: "(unnamed)"

  # A record that names nothing is left out, so it reads as the ask.
  defp put_named(map, _key, empty) when is_map(empty) and map_size(empty) == 0, do: map
  defp put_named(map, key, value), do: Map.put(map, key, value)

  @doc false
  def put_optional(map, _key, nil), do: map
  def put_optional(map, key, value), do: Map.put(map, key, value)
end
