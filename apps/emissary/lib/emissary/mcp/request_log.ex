defmodule Emissary.MCP.RequestLog do
  @moduledoc """
  MCP request logging for CYFR.

  Logs every MCP request to enable forensic replay and audit trails.
  Each log entry captures the complete request context, allowing exact
  reproduction of request handling.

  Routes all persistent storage through `Arca.MCP.handle("mcp_log", ...)`
  which owns path construction, file writes, and SQLite indexing.

  ## Sensitive Data

  Input parameters are automatically sanitized to redact passwords,
  secrets, tokens, and API keys before logging.
  """

  alias Sanctum.Context

  @sensitive_keys ~w(
    password secret token api_key apikey access_token refresh_token
    private_key secret_key auth bearer credential credentials
    passwd pwd api-key x-api-key authorization
  )

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
    case Arca.MCP.handle("mcp_log", ctx, %{
      "action" => "log_started",
      "id" => request_id,
      "tool" => data[:tool] || data["tool"],
      "tool_action" => data[:action] || data["action"],
      "method" => data[:method] || data["method"],
      "input" => sanitize_input(data[:input] || data["input"] || %{})
    }) do
      {:ok, %{logged: true}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Log successful completion of an MCP request.
  """
  @spec log_completed(String.t(), map()) :: :ok | {:error, term()}
  def log_completed(request_id, data) when is_binary(request_id) and is_map(data) do
    case Arca.MCP.handle("mcp_log", mcp_ctx(), %{
      "action" => "log_completed",
      "id" => request_id,
      "output" => data[:output] || data["output"],
      "duration_ms" => data[:duration_ms] || data["duration_ms"],
      "routed_to" => data[:routed_to] || data["routed_to"]
    }) do
      {:ok, %{logged: true}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Log failure of an MCP request.
  """
  @spec log_failed(String.t(), map()) :: :ok | {:error, term()}
  def log_failed(request_id, data) when is_binary(request_id) and is_map(data) do
    case Arca.MCP.handle("mcp_log", mcp_ctx(), %{
      "action" => "log_failed",
      "id" => request_id,
      "error" => data[:error] || data["error"],
      "error_code" => data[:code] || data["code"],
      "duration_ms" => data[:duration_ms] || data["duration_ms"]
    }) do
      {:ok, %{logged: true}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get a request log by request_id.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, term()}
  def get(request_id) when is_binary(request_id) do
    case Arca.MCP.handle("mcp_log", mcp_ctx(), %{"action" => "get", "id" => request_id}) do
      {:ok, result} -> {:ok, atom_map_to_string_map(result)}
      {:error, _} -> {:error, :not_found}
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
    args = %{"action" => "list"}
    args = if opts[:limit], do: Map.put(args, "limit", opts[:limit]), else: args
    args = if opts[:status], do: Map.put(args, "status", opts[:status]), else: args
    args = if opts[:user_id], do: Map.put(args, "user_id", opts[:user_id]), else: args

    case Arca.MCP.handle("mcp_log", mcp_ctx(), args) do
      {:ok, %{logs: logs}} -> {:ok, Enum.map(logs, &atom_map_to_string_map/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Delete a request log by request_id.
  """
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(request_id) when is_binary(request_id) do
    case Arca.MCP.handle("mcp_log", mcp_ctx(), %{"action" => "delete", "id" => request_id}) do
      {:ok, %{deleted: true}} -> :ok
      {:error, _} -> {:error, :not_found}
    end
  end

  # ============================================================================
  # Input Sanitization (Emissary-specific)
  # ============================================================================

  @doc """
  Sanitize input data to redact sensitive values.

  Recursively traverses maps and lists, redacting any values whose
  keys match known sensitive patterns.
  """
  @spec sanitize_input(term()) :: term()
  def sanitize_input(input) when is_map(input) do
    input
    |> Enum.map(fn {key, value} ->
      if sensitive_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, sanitize_input(value)}
      end
    end)
    |> Map.new()
  end

  def sanitize_input(input) when is_list(input) do
    Enum.map(input, &sanitize_input/1)
  end

  def sanitize_input(input), do: input

  # ============================================================================
  # Private
  # ============================================================================

  defp mcp_ctx do
    %Context{
      user_id: "system",
      permissions: MapSet.new([:*]),
      scope: :personal,
      auth_method: :local
    }
  end

  defp atom_map_to_string_map(map) when is_map(map) do
    Map.new(map, fn
      {:id, v} -> {"request_id", v}
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp sensitive_key?(key) when is_binary(key) do
    normalized = String.downcase(key) |> String.replace(["-", "_"], "")
    Enum.any?(@sensitive_keys, fn sensitive ->
      normalized_sensitive = String.downcase(sensitive) |> String.replace(["-", "_"], "")
      String.contains?(normalized, normalized_sensitive)
    end)
  end

  defp sensitive_key?(key) when is_atom(key) do
    sensitive_key?(Atom.to_string(key))
  end

  defp sensitive_key?(_), do: false
end
