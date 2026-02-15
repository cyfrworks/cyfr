defmodule Sanctum.PolicyStore do
  @moduledoc """
  SQLite-backed storage for Host Policies.

  Policies are stored in the `policies` table via Arca. Caching is
  handled transparently by `Arca.Cache` inside the storage layer.

  ## Usage

      # Get a policy for a component
      {:ok, policy} = Sanctum.PolicyStore.get("local.stripe-catalyst:1.0.0")

      # Save a policy
      :ok = Sanctum.PolicyStore.put("local.stripe-catalyst:1.0.0", policy)

      # Delete a policy
      :ok = Sanctum.PolicyStore.delete("local.stripe-catalyst:1.0.0")

      # List all policies
      {:ok, policies} = Sanctum.PolicyStore.list()

  ## Database Access

  This module calls through to `Arca.PolicyStorage` via MCP boundary
  for actual database operations.
  """

  require Logger

  alias Sanctum.Policy

  defp mcp_ctx, do: Sanctum.Context.local()

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Get the policy for a component reference.

  Returns `{:ok, policy}` or `{:error, :not_found}`.
  """
  @spec get(String.t()) :: {:ok, Policy.t()} | {:error, :not_found}
  def get(component_ref) when is_binary(component_ref) do
    with {:ok, component_ref} <- normalize_component_ref(component_ref) do
      case Arca.MCP.handle("policy_store", mcp_ctx(), %{"action" => "get", "component_ref" => component_ref}) do
        {:ok, %{policy: row}} when is_map(row) ->
          case row_to_policy(row) do
            {:ok, policy} -> {:ok, policy}
            {:error, reason} -> {:error, {:corrupt_policy, reason}}
          end
        {:error, :not_found} -> {:error, :not_found}
        {:error, reason} -> {:error, {:store_error, reason}}
      end
    end
  end

  @doc """
  Save a policy for a component reference.

  Upserts the policy in SQLite and updates the cache.
  """
  @spec put(String.t(), Policy.t() | map()) :: :ok | {:error, term()}
  def put(component_ref, %Policy{} = policy) when is_binary(component_ref) do
    put(component_ref, policy_to_map(policy))
  end

  def put(component_ref, policy_map) when is_binary(component_ref) and is_map(policy_map) do
    with {:ok, component_ref} <- normalize_component_ref(component_ref),
         raw_type = Map.get(policy_map, :component_type, "reagent"),
         {:ok, component_type} <- validate_component_type(raw_type),
         {:ok, window_seconds} <- get_rate_limit_window_seconds(policy_map) do
      now = DateTime.utc_now()
      id = generate_id(component_ref)

      attrs = %{
        "id" => id,
        "component_ref" => component_ref,
        "component_type" => component_type,
        "allowed_domains" => encode_json_field(Map.get(policy_map, :allowed_domains, [])),
        "allowed_methods" => encode_json_field(Map.get(policy_map, :allowed_methods, ["GET", "POST", "PUT", "DELETE", "PATCH"])),
        "rate_limit_requests" => get_rate_limit_requests(policy_map),
        "rate_limit_window_seconds" => window_seconds,
        "timeout" => Map.get(policy_map, :timeout, "30s"),
        "max_memory_bytes" => Map.get(policy_map, :max_memory_bytes, 64 * 1024 * 1024),
        "max_request_size" => Map.get(policy_map, :max_request_size, 1_048_576),
        "max_response_size" => Map.get(policy_map, :max_response_size, 5_242_880),
        "allowed_tools" => encode_json_field(Map.get(policy_map, :allowed_tools, [])),
        "allowed_storage_paths" => encode_json_field(Map.get(policy_map, :allowed_storage_paths, [])),
        "inserted_at" => DateTime.to_iso8601(now),
        "updated_at" => DateTime.to_iso8601(now)
      }

      case Arca.MCP.handle("policy_store", mcp_ctx(), %{"action" => "put", "attrs" => attrs}) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Delete a policy for a component reference.
  """
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(component_ref) when is_binary(component_ref) do
    with {:ok, component_ref} <- normalize_component_ref(component_ref) do
      case Arca.MCP.handle("policy_store", mcp_ctx(), %{"action" => "delete", "component_ref" => component_ref}) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  List all stored policies.
  """
  @spec list() :: {:ok, [%{component_ref: String.t(), policy: Policy.t()}]}
  def list do
    case Arca.MCP.handle("policy_store", mcp_ctx(), %{"action" => "list"}) do
      {:ok, %{policies: rows}} ->
        db_policies =
          rows
          |> Enum.reduce([], fn row, acc ->
            case row_to_policy(row) do
              {:ok, policy} ->
                [%{component_ref: row.component_ref, policy: policy} | acc]

              {:error, reason} ->
                Logger.error("[Sanctum.PolicyStore] Corrupt policy for #{row.component_ref}: #{reason}")
                acc
            end
          end)
          |> Enum.reverse()

        {:ok, db_policies}

      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Update a single policy field for a component.

  Used by CLI commands like `cyfr policy set <ref> <key> <value>`.
  """
  @spec update_field(String.t(), String.t(), term()) :: :ok | {:error, term()}
  def update_field(component_ref, field, value) when is_binary(component_ref) do
    # Get existing policy or create new one
    existing =
      case get(component_ref) do
        {:ok, policy} -> policy_to_map(policy)
        {:error, :not_found} -> %{}
      end

    # Update the field
    updated = update_policy_field(existing, field, value)

    # Save back
    put(component_ref, updated)
  end

  # ============================================================================
  # Private: Database Operations (via Arca MCP)
  # ============================================================================

  defp row_to_policy(row) when is_map(row) do
    with {:ok, domains} <- decode_json_field(Map.get(row, :allowed_domains), []),
         {:ok, methods} <- decode_json_field(Map.get(row, :allowed_methods), ["GET", "POST", "PUT", "DELETE", "PATCH"]),
         {:ok, tools} <- decode_json_field(Map.get(row, :allowed_tools), []),
         {:ok, storage_paths} <- decode_json_field(Map.get(row, :allowed_storage_paths), []) do
      {:ok,
       %Policy{
         allowed_domains: domains,
         allowed_methods: methods,
         rate_limit: build_rate_limit(Map.get(row, :rate_limit_requests), Map.get(row, :rate_limit_window_seconds)),
         timeout: Map.get(row, :timeout) || "30s",
         max_memory_bytes: Map.get(row, :max_memory_bytes) || 64 * 1024 * 1024,
         max_request_size: Map.get(row, :max_request_size) || 1_048_576,
         max_response_size: Map.get(row, :max_response_size) || 5_242_880,
         allowed_tools: tools,
         allowed_storage_paths: storage_paths
       }}
    end
  end

  # ============================================================================
  # Private: Helpers
  # ============================================================================

  defp generate_id(component_ref) do
    hash = :crypto.hash(:sha256, component_ref) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    "pol_#{hash}"
  end

  defp encode_json_field(nil), do: "[]"
  defp encode_json_field(list) when is_list(list), do: Jason.encode!(list)
  defp encode_json_field(value), do: Jason.encode!([value])

  defp decode_json_field(nil, default), do: {:ok, default}
  defp decode_json_field(json, _default) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, _} -> {:error, "Invalid JSON field: expected a list, got: #{json}"}
      {:error, _} -> {:error, "Invalid JSON in policy field: #{json}"}
    end
  end
  defp decode_json_field(other, _default), do: {:error, "Invalid policy field value: #{inspect(other)}"}

  defp get_rate_limit_requests(%{rate_limit: %{requests: r}}), do: r
  defp get_rate_limit_requests(_), do: nil

  defp get_rate_limit_window_seconds(%{rate_limit: %{window: w}}) when is_binary(w) do
    parse_window_to_seconds(w)
  end
  defp get_rate_limit_window_seconds(_), do: {:ok, nil}

  defp parse_window_to_seconds(window) do
    result =
      cond do
        String.ends_with?(window, "s") ->
          parse_window_int(window, "s", 1)

        String.ends_with?(window, "m") ->
          parse_window_int(window, "m", 60)

        String.ends_with?(window, "h") ->
          parse_window_int(window, "h", 3600)

        true ->
          {:error, "Invalid window '#{window}'. Expected format: 30s, 5m, or 1h"}
      end

    case result do
      {:ok, seconds} -> {:ok, seconds}
      {:error, _} = err -> err
    end
  end

  defp parse_window_int(str, suffix, multiplier) do
    raw = String.trim_trailing(str, suffix)

    case Integer.parse(raw) do
      {n, ""} -> {:ok, n * multiplier}
      _ -> {:error, "Invalid window '#{str}'. Expected format: 30s, 5m, or 1h"}
    end
  end

  defp build_rate_limit(nil, _), do: nil
  defp build_rate_limit(_, nil), do: nil
  defp build_rate_limit(requests, window_seconds) do
    %{
      requests: requests,
      window: format_window(window_seconds)
    }
  end

  defp format_window(seconds) when seconds >= 3600 and rem(seconds, 3600) == 0 do
    "#{div(seconds, 3600)}h"
  end
  defp format_window(seconds) when seconds >= 60 and rem(seconds, 60) == 0 do
    "#{div(seconds, 60)}m"
  end
  defp format_window(seconds), do: "#{seconds}s"

  defp policy_to_map(%Policy{} = policy) do
    %{
      allowed_domains: policy.allowed_domains,
      allowed_methods: Map.get(policy, :allowed_methods, ["GET", "POST", "PUT", "DELETE", "PATCH"]),
      rate_limit: policy.rate_limit,
      timeout: policy.timeout,
      max_memory_bytes: policy.max_memory_bytes,
      max_request_size: policy.max_request_size,
      max_response_size: policy.max_response_size,
      allowed_tools: policy.allowed_tools,
      allowed_storage_paths: policy.allowed_storage_paths
    }
  end

  defp update_policy_field(policy_map, "allowed_domains", value) do
    domains = parse_json_value(value, [])
    Map.put(policy_map, :allowed_domains, domains)
  end

  defp update_policy_field(policy_map, "allowed_methods", value) do
    methods = parse_json_value(value, ["GET", "POST", "PUT", "DELETE", "PATCH"])
    Map.put(policy_map, :allowed_methods, methods)
  end

  defp update_policy_field(policy_map, "rate_limit", value) do
    rate_limit = parse_rate_limit_value(value)
    Map.put(policy_map, :rate_limit, rate_limit)
  end

  defp update_policy_field(policy_map, "timeout", value) do
    Map.put(policy_map, :timeout, value)
  end

  defp update_policy_field(policy_map, "max_memory_bytes", value) do
    Map.put(policy_map, :max_memory_bytes, parse_int(value, 64 * 1024 * 1024))
  end

  defp update_policy_field(policy_map, "allowed_tools", value) do
    tools = parse_json_value(value, [])
    Map.put(policy_map, :allowed_tools, tools)
  end

  defp update_policy_field(policy_map, "allowed_storage_paths", value) do
    paths = parse_json_value(value, [])
    Map.put(policy_map, :allowed_storage_paths, paths)
  end

  defp update_policy_field(policy_map, key, value) do
    Map.put(policy_map, String.to_atom(key), value)
  end

  defp parse_json_value(value, _default) when is_list(value), do: value
  defp parse_json_value(value, default) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> list
      _ -> default
    end
  end
  defp parse_json_value(_, default), do: default

  defp parse_rate_limit_value(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{"requests" => r, "window" => w}} -> %{requests: r, window: w}
      _ -> nil
    end
  end
  defp parse_rate_limit_value(_), do: nil

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end
  defp parse_int(value, _) when is_integer(value), do: value
  defp parse_int(_, default), do: default

  defp normalize_component_ref(ref) do
    Sanctum.ComponentRef.normalize(ref)
  end

  defp validate_component_type(type) when is_atom(type) do
    validate_component_type(Atom.to_string(type))
  end

  defp validate_component_type(type) when type in ["catalyst", "reagent", "formula"] do
    {:ok, type}
  end

  defp validate_component_type(invalid) do
    {:error, "Invalid component type '#{inspect(invalid)}'. Must be one of: catalyst, reagent, formula"}
  end
end
