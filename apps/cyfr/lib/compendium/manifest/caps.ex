# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Manifest.Caps do
  @moduledoc """
  The manifest `caps` block: what a component *asks* to be allowed to do.

  Unlike the `setup.policy` block it succeeds, `caps` is never applied to
  anything by itself — it is hashed into the release and shape digests,
  rendered on the consent sheet, and becomes edge resources only when a
  consent revision commits (`effective = cap ∩ operator choices ∩
  ceiling`). Declaring more here widens what the operator is *asked* for,
  never what the component *gets*.

  ## Shape

      "caps": {
        "egress":  { "domains": ["api.example"], "methods": ["GET"],
                     "schemes": ["https"], "private_ips": [] },
        "storage": { "paths": ["data/"], "actions": ["read", "write"] },
        "tools":   ["execution.run", "component.*"],
        "limits":  { "timeout": "3m",
                     "rate_limit": { "requests": 100, "window": "1m" } }
      }

  Closed vocabulary at every level; everything optional. `tools` speaks
  the `Sanctum.ToolPattern` grammar and is expanded at consent time.
  `limits` carries the `Sanctum.Limits` field names — suggestions under
  the platform ceiling, operator-adjustable at commit. `schemes` absent
  means `["https"]` at consent.
  """

  @egress_keys ~w(domains methods schemes private_ips)
  @storage_keys ~w(paths actions)
  @limit_int_keys ~w(max_memory_bytes max_request_size max_response_size max_concurrent_tasks)
  @limit_duration_keys ~w(timeout batch_timeout)
  @duration_re ~r/^\d+(ms|s|m|h)$/

  @type error :: {:invalid_caps, term()}

  @doc """
  Validate a decoded manifest's `caps` block. Absent is valid.
  """
  @spec validate(map() | nil) :: :ok | {:error, error()}
  def validate(nil), do: :ok

  def validate(%{"caps" => caps}) when is_map(caps) do
    with :ok <- only_keys(caps, ~w(egress storage tools limits), :caps),
         :ok <- validate_egress(caps["egress"]),
         :ok <- validate_storage(caps["storage"]),
         :ok <- validate_tools(caps["tools"]),
         :ok <- validate_limits(caps["limits"]) do
      :ok
    end
  end

  def validate(%{"caps" => other}), do: {:error, {:invalid_caps, {:not_a_map, other}}}
  def validate(manifest) when is_map(manifest), do: :ok

  @doc """
  The normalized caps for a decoded manifest: string sets sorted and
  deduplicated, every key present with its empty default. Returns `nil`
  when the manifest declares no `caps` block — callers branch on that for
  source priority.
  """
  @spec from_manifest(map() | nil) :: map() | nil
  def from_manifest(%{"caps" => caps} = manifest) when is_map(caps) do
    case validate(manifest) do
      :ok ->
        egress = caps["egress"] || %{}
        storage = caps["storage"] || %{}

        %{
          egress: %{
            domains: string_set(egress["domains"]),
            methods: string_set(egress["methods"]),
            schemes: string_set(egress["schemes"]),
            private_ips: string_set(egress["private_ips"])
          },
          storage: %{
            paths: string_set(storage["paths"]),
            actions: string_set(storage["actions"])
          },
          tools: string_set(caps["tools"]),
          limits: normalize_limits(caps["limits"] || %{})
        }

      {:error, _} ->
        nil
    end
  end

  def from_manifest(_manifest), do: nil

  # ---------------------------------------------------------------------------
  # Sections
  # ---------------------------------------------------------------------------

  defp validate_egress(nil), do: :ok

  defp validate_egress(%{} = egress) do
    with :ok <- only_keys(egress, @egress_keys, :egress) do
      Enum.reduce_while(@egress_keys, :ok, fn key, :ok ->
        case string_list(egress[key], [:caps, :egress, key]) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp validate_egress(other), do: {:error, {:invalid_caps, {:egress_not_a_map, other}}}

  defp validate_storage(nil), do: :ok

  defp validate_storage(%{} = storage) do
    with :ok <- only_keys(storage, @storage_keys, :storage) do
      Enum.reduce_while(@storage_keys, :ok, fn key, :ok ->
        case string_list(storage[key], [:caps, :storage, key]) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp validate_storage(other), do: {:error, {:invalid_caps, {:storage_not_a_map, other}}}

  defp validate_tools(nil), do: :ok

  defp validate_tools(tools) when is_list(tools) do
    case Enum.find(tools, &(not Sanctum.ToolPattern.valid?(&1))) do
      nil -> :ok
      bad -> {:error, {:invalid_caps, {:invalid_tool_pattern, bad}}}
    end
  end

  defp validate_tools(other), do: {:error, {:invalid_caps, {:tools_not_a_list, other}}}

  defp validate_limits(nil), do: :ok

  defp validate_limits(%{} = limits) do
    with :ok <-
           only_keys(limits, @limit_int_keys ++ @limit_duration_keys ++ ["rate_limit"], :limits) do
      Enum.reduce_while(limits, :ok, fn {key, value}, :ok ->
        case validate_limit(key, value) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp validate_limits(other), do: {:error, {:invalid_caps, {:limits_not_a_map, other}}}

  defp validate_limit(key, value) when key in @limit_int_keys do
    if is_integer(value) and value > 0,
      do: :ok,
      else: {:error, {:invalid_caps, {:invalid_limit, key, value}}}
  end

  defp validate_limit(key, value) when key in @limit_duration_keys do
    if is_binary(value) and Regex.match?(@duration_re, value),
      do: :ok,
      else: {:error, {:invalid_caps, {:invalid_limit, key, value}}}
  end

  defp validate_limit("rate_limit", %{"requests" => requests, "window" => window} = map) do
    cond do
      map_size(map) != 2 ->
        {:error, {:invalid_caps, {:invalid_limit, "rate_limit", map}}}

      not (is_integer(requests) and requests > 0) ->
        {:error, {:invalid_caps, {:invalid_limit, "rate_limit", map}}}

      not (is_binary(window) and Regex.match?(@duration_re, window)) ->
        {:error, {:invalid_caps, {:invalid_limit, "rate_limit", map}}}

      true ->
        :ok
    end
  end

  defp validate_limit("rate_limit", value),
    do: {:error, {:invalid_caps, {:invalid_limit, "rate_limit", value}}}

  # ---------------------------------------------------------------------------
  # Pieces
  # ---------------------------------------------------------------------------

  defp only_keys(map, allowed, section) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      unknown -> {:error, {:invalid_caps, {:unknown_keys, section, Enum.sort(unknown)}}}
    end
  end

  defp string_list(nil, _path), do: :ok

  defp string_list(list, path) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, {:invalid_caps, {:invalid_string_list, path, list}}}
  end

  defp string_list(other, path),
    do: {:error, {:invalid_caps, {:invalid_string_list, path, other}}}

  defp string_set(nil), do: []
  defp string_set(list) when is_list(list), do: list |> Enum.uniq() |> Enum.sort()

  defp normalize_limits(limits) do
    Map.new(limits, fn
      {"rate_limit", %{"requests" => requests, "window" => window}} ->
        {:rate_limit, %{requests: requests, window: window}}

      {key, value} ->
        {String.to_existing_atom(key), value}
    end)
  end
end
