defmodule Sanctum.PolicyLog do
  @moduledoc """
  Policy consultation logging for CYFR.

  Logs every policy consultation to enable forensic replay and audit trails.
  Each log entry captures the complete policy context at the time of consultation,
  allowing exact reproduction of policy decisions.

  Routes all persistent storage through `Arca.PolicyLog`
  which owns path construction, file writes, and SQLite indexing.

  ## Correlation

  Policy logs are linked to other logs via correlation IDs:
  - `request_id`: Links to the MCP request in `mcp_logs/`
  - `execution_id`: Links to the execution in `executions/`
  """

  alias Sanctum.Context

  @type log_entry :: %{
          request_id: String.t(),
          execution_id: String.t() | nil,
          timestamp: String.t(),
          event_type: String.t(),
          component_ref: String.t(),
          component_type: String.t() | nil,
          host_policy_snapshot: map(),
          decision: String.t(),
          decision_reason: String.t() | nil
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Log a policy consultation event.
  """
  @spec log(Context.t(), map()) :: :ok | {:error, term()}
  def log(%Context{} = ctx, data) when is_map(data) do
    component_ref = data[:component_ref] || data["component_ref"]

    case Arca.PolicyLog.record(%{
      id: generate_id("plog"),
      request_id: ctx.request_id || generate_request_id(),
      execution_id: data[:execution_id] || data["execution_id"],
      session_id: ctx.session_id,
      user_id: ctx.user_id,
      timestamp: DateTime.utc_now(),
      event_type: data[:event_type] || data["event_type"] || "policy_consultation",
      component_ref: component_ref,
      component_type: normalize_component_type(data[:component_type] || data["component_type"]),
      decision: data[:decision] || data["decision"],
      host_policy_snapshot: encode_json(data[:host_policy_snapshot] || data["host_policy_snapshot"] || %{}),
      decision_reason: data[:decision_reason] || data["decision_reason"]
    }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get a policy log by ID or request_id.
  """
  @spec get(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(%Context{} = _ctx, id) do
    record = Arca.PolicyLog.get(id) || Arca.PolicyLog.get_by_request_id(id)

    case record do
      nil -> {:error, :not_found}
      record -> {:ok, atom_map_to_string_map(policy_log_to_map(record))}
    end
  end

  @doc """
  Get a policy log by execution_id.

  Searches policy logs to find one matching the given execution_id.
  """
  @spec get_by_execution(Context.t(), String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_by_execution(%Context{} = _ctx, execution_id) do
    case Arca.PolicyLog.list(execution_id: execution_id, limit: 1) do
      [log | _] -> {:ok, atom_map_to_string_map(policy_log_to_map(log))}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  List policy logs for the current user.

  ## Options

  - `:limit` - Maximum number of logs to return (default: 20)
  - `:event_type` - Filter by event type
  """
  @spec list(Context.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(%Context{} = ctx, opts \\ []) do
    query_opts = [user_id: ctx.user_id]
    query_opts = if opts[:limit], do: Keyword.put(query_opts, :limit, opts[:limit]), else: query_opts
    query_opts = if opts[:event_type], do: Keyword.put(query_opts, :event_type, opts[:event_type]), else: query_opts

    records = Arca.PolicyLog.list(query_opts)
    {:ok, Enum.map(records, fn r -> atom_map_to_string_map(policy_log_to_map(r)) end)}
  end

  @doc """
  Delete a policy log by ID or request_id.
  """
  @spec delete(Context.t(), String.t()) :: :ok | {:error, term()}
  def delete(%Context{} = _ctx, id) do
    record = Arca.PolicyLog.get(id) || Arca.PolicyLog.get_by_request_id(id)

    case record do
      nil -> {:error, :not_found}
      record ->
        case Arca.Repo.delete(record) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, :not_found}
        end
    end
  end

  # ============================================================================
  # Convenience Functions for Common Events
  # ============================================================================

  @doc """
  Log a successful policy consultation where execution was allowed.
  """
  @spec log_allowed(Context.t(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def log_allowed(%Context{} = ctx, component_ref, host_policy, opts \\ []) do
    log(ctx, %{
      event_type: "policy_consultation",
      component_ref: component_ref,
      component_type: Keyword.get(opts, :component_type),
      execution_id: Keyword.get(opts, :execution_id),
      host_policy_snapshot: host_policy,
      decision: "allowed",
      decision_reason: Keyword.get(opts, :reason)
    })
  end

  @doc """
  Log a policy consultation where execution was denied.
  """
  @spec log_denied(Context.t(), String.t(), map(), String.t(), keyword()) :: :ok | {:error, term()}
  def log_denied(%Context{} = ctx, component_ref, host_policy, reason, opts \\ []) do
    log(ctx, %{
      event_type: "policy_denied",
      component_ref: component_ref,
      component_type: Keyword.get(opts, :component_type),
      execution_id: Keyword.get(opts, :execution_id),
      host_policy_snapshot: host_policy,
      decision: "denied",
      decision_reason: reason
    })
  end

  @doc """
  Log a policy violation from HTTP proxy.
  """
  @spec log_violation(map()) :: :ok | {:error, term()}
  def log_violation(data) when is_map(data) do
    request_id = generate_request_id()

    ctx = %Context{
      user_id: data[:user_id] || "unknown",
      permissions: MapSet.new([:*]),
      scope: :personal,
      request_id: request_id
    }

    log_denied(
      ctx,
      data[:component_ref] || "unknown",
      %{},
      data[:reason] || "Policy violation",
      domain: data[:domain],
      method: data[:method]
    )
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp generate_request_id do
    hex = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    "req_#{String.slice(hex, 0, 8)}-#{String.slice(hex, 8, 4)}-#{String.slice(hex, 12, 4)}-#{String.slice(hex, 16, 4)}-#{String.slice(hex, 20, 12)}"
  end

  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(%NaiveDateTime{} = ndt), do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  defp format_datetime(other), do: other

  defp normalize_component_type(nil), do: nil
  defp normalize_component_type(type) when is_atom(type), do: Atom.to_string(type)
  defp normalize_component_type(type) when is_binary(type), do: type

  defp generate_id(prefix) do
    hex = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    "#{prefix}_#{hex}"
  end

  defp encode_json(nil), do: nil
  defp encode_json(value) when is_binary(value), do: value
  defp encode_json(value), do: Jason.encode!(value)

  defp policy_log_to_map(log) when is_struct(log) do
    %{
      id: log.id,
      request_id: log.request_id,
      execution_id: log.execution_id,
      session_id: log.session_id,
      user_id: log.user_id,
      timestamp: format_datetime(log.timestamp),
      event_type: log.event_type,
      component_ref: log.component_ref,
      component_type: log.component_type,
      decision: log.decision,
      host_policy_snapshot: decode_json(log.host_policy_snapshot),
      decision_reason: log.decision_reason
    }
  end

  defp decode_json(nil), do: nil
  defp decode_json(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, value} -> value
      _ -> str
    end
  end
  defp decode_json(value), do: value

  defp atom_map_to_string_map(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
