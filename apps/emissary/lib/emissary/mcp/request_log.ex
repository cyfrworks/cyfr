defmodule Emissary.MCP.RequestLog do
  @moduledoc """
  MCP request logging for CYFR.

  Logs every MCP request to enable forensic replay and audit trails.
  Each log entry captures the complete request context, allowing exact
  reproduction of request handling.

  Routes all persistent storage through `Arca.McpLog`
  which owns path construction, file writes, and SQLite indexing.

  ## Sensitive Data

  Input parameters are automatically sanitized to redact passwords,
  secrets, tokens, and API keys before logging.
  """

  alias Sanctum.Context

  @type log_entry :: %{
          request_id: String.t(),
          session_id: String.t() | nil,
          user_id: String.t(),
          timestamp: String.t(),
          tool: String.t() | nil,
          action: String.t() | nil,
          method: String.t() | nil,
          input: map(),
          output: map() | nil,
          status: String.t(),
          duration_ms: non_neg_integer() | nil,
          routed_to: String.t() | nil,
          error: String.t() | nil,
          error_code: integer() | nil
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Log the start of an MCP request.

  Called before routing the request. This creates the initial log entry
  with status "pending". Input is automatically sanitized.
  """
  @spec log_started(Context.t(), String.t(), map()) :: :ok | {:error, term()}
  def log_started(%Context{} = ctx, request_id, data) when is_binary(request_id) and is_map(data) do
    case Arca.McpLog.record(%{
      id: request_id,
      session_id: ctx.session_id,
      user_id: ctx.user_id || "system",
      timestamp: DateTime.utc_now(),
      tool: data[:tool] || data["tool"],
      action: data[:action] || data["action"],
      method: data[:method] || data["method"],
      status: "pending",
      input: encode_json(sanitize_input(data[:input] || data["input"] || %{}))
    }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Log successful completion of an MCP request.
  """
  @spec log_completed(String.t(), map()) :: :ok | {:error, term()}
  def log_completed(request_id, data) when is_binary(request_id) and is_map(data) do
    case Arca.McpLog.record_update(request_id, %{
      status: "success",
      duration_ms: data[:duration_ms] || data["duration_ms"],
      routed_to: data[:routed_to] || data["routed_to"],
      output: encode_json(data[:output] || data["output"])
    }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Log failure of an MCP request.
  """
  @spec log_failed(String.t(), map()) :: :ok | {:error, term()}
  def log_failed(request_id, data) when is_binary(request_id) and is_map(data) do
    case Arca.McpLog.record_update(request_id, %{
      status: "error",
      error_code: data[:code] || data["code"],
      duration_ms: data[:duration_ms] || data["duration_ms"],
      error: data[:error] || data["error"],
      routed_to: data[:routed_to] || data["routed_to"]
    }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get a request log by request_id.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, term()}
  def get(request_id) when is_binary(request_id) do
    case Arca.McpLog.get(request_id) do
      nil -> {:error, :not_found}
      record -> {:ok, atom_map_to_string_map(mcp_log_to_map(record))}
    end
  end

  @doc """
  List recent request logs.

  ## Options

  - `:limit` - Maximum number of logs to return (default: 20)
  - `:status` - Filter by status ("pending", "success", "error")
  - `:user_id` - Filter by user ID
  """
  @spec list(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(opts \\ []) do
    query_opts = []
    query_opts = if opts[:limit], do: Keyword.put(query_opts, :limit, opts[:limit]), else: query_opts
    query_opts = if opts[:status], do: Keyword.put(query_opts, :status, opts[:status]), else: query_opts
    query_opts = if opts[:user_id], do: Keyword.put(query_opts, :user_id, opts[:user_id]), else: query_opts

    records = Arca.McpLog.list(query_opts)
    {:ok, Enum.map(records, fn r -> atom_map_to_string_map(mcp_log_to_map(r)) end)}
  end

  @doc false
  # Deprecated: MCP logs are append-only. Use Arca.Retention.cleanup_mcp_logs/2
  # for retention-based cleanup instead.
  @deprecated "MCP logs are append-only. Use Arca.Retention.cleanup_mcp_logs/2 for retention cleanup."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(request_id) when is_binary(request_id) do
    case Arca.McpLog.get(request_id) do
      nil -> {:error, :not_found}
      record ->
        case Arca.Repo.delete(record) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, :not_found}
        end
    end
  end

  # ============================================================================
  # Input Sanitization
  # ============================================================================

  @doc """
  Sanitize input data to redact sensitive values.

  Delegates to `Sanctum.Sanitizer.sanitize/1`.
  """
  @spec sanitize_input(term()) :: term()
  defdelegate sanitize_input(input), to: Sanctum.Sanitizer, as: :sanitize

  # ============================================================================
  # Private
  # ============================================================================

  defp encode_json(nil), do: nil
  defp encode_json(value) when is_binary(value), do: value
  defp encode_json(value), do: Jason.encode!(value)

  defp mcp_log_to_map(log) when is_struct(log) do
    %{
      id: log.id,
      session_id: log.session_id,
      user_id: log.user_id,
      timestamp: format_datetime(log.timestamp),
      tool: log.tool,
      action: log.action,
      method: log.method,
      status: log.status,
      input: decode_json(log.input),
      output: decode_json(log.output),
      duration_ms: log.duration_ms,
      routed_to: log.routed_to,
      error: log.error,
      error_code: log.error_code
    }
  end

  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(%NaiveDateTime{} = ndt), do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  defp format_datetime(other), do: other

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
      {:id, v} -> {"request_id", v}
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

end
