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
  def log_started(%Context{} = ctx, request_id, data)
      when is_binary(request_id) and is_map(data) do
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
  @spec log_completed(Context.t(), String.t(), map()) :: :ok | {:error, term()}
  def log_completed(%Context{} = ctx, request_id, data)
      when is_binary(request_id) and is_map(data) do
    case Arca.McpLog.record_update(ctx, request_id, %{
           status: "success",
           duration_ms: data[:duration_ms] || data["duration_ms"],
           routed_to: data[:routed_to] || data["routed_to"],
           output: encode_json(sanitize_input(data[:output] || data["output"]))
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Log failure of an MCP request.
  """
  @spec log_failed(Context.t(), String.t(), map()) :: :ok | {:error, term()}
  def log_failed(%Context{} = ctx, request_id, data)
      when is_binary(request_id) and is_map(data) do
    case Arca.McpLog.record_update(ctx, request_id, %{
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

  defp encode_json(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> encoded
      {:error, _} -> inspect(value)
    end
  end
end
