defmodule EmissaryWeb.MCPController do
  @moduledoc """
  MCP HTTP controller implementing Streamable HTTP transport.

  Endpoints:
  - POST /mcp - Handle MCP requests/notifications
  - DELETE /mcp - Terminate session

  ## Request Format

  POST body must be valid JSON-RPC 2.0:
  - Single request or notification (batching not supported per 2025-11-25 spec)

  ## Headers

  - `Content-Type: application/json` (required)
  - `Accept: application/json, text/event-stream` (recommended)
  - `MCP-Session-Id: <id>` (required after initialization)
  - `MCP-Protocol-Version: 2025-11-25` (returned in responses)
  - `X-Request-Id: req_<uuid7>` (returned in responses for correlation)

  ## Response

  For initialization: Returns result with `MCP-Session-Id` and `MCP-Protocol-Version` headers.
  For other requests: Returns JSON-RPC response with `X-Request-Id` header.

  ## Telemetry

  Emits `[:cyfr, :emissary, :request]` on every request with:
  - Measurements: `%{duration: native_time}`
  - Metadata: `%{method: String.t(), tool: String.t() | nil, status: :success | :error}`
  """

  use EmissaryWeb, :controller

  alias Emissary.MCP
  alias Emissary.MCP.{Message, RequestLog, Session}
  alias Emissary.UUID7

  @protocol_version "2025-11-25"

  @doc """
  Handle MCP POST requests.

  Routes to initialize flow or regular message handling based on
  whether a session exists.
  """
  def handle(conn, params) do
    request_id = UUID7.request_id()
    start_time = System.monotonic_time()

    case {conn.assigns[:mcp_session], params} do
      # No session, initialize request
      {nil, %{"method" => "initialize"} = params} ->
        handle_initialize(conn, params, request_id, start_time)

      # No session, but not an initialize request
      {nil, _params} ->
        conn
        |> put_resp_header("x-request-id", request_id)
        |> put_status(400)
        |> json(%{
          "jsonrpc" => "2.0",
          "error" => %{
            "code" => Message.cyfr_code(:session_required),
            "message" => "Session required. Send initialize request first."
          },
          "id" => params["id"]
        })

      # Has session, handle normally
      {session, params} ->
        handle_message(conn, session, params, request_id, start_time)
    end
  end

  defp handle_initialize(conn, params, request_id, start_time) do
    context = conn.assigns[:mcp_context]
    id = params["id"]

    # Log request start asynchronously
    log_request_started(context, request_id, %{
      method: "initialize",
      tool: nil,
      action: nil,
      input: params["params"] || %{}
    })

    case MCP.initialize(context, params["params"] || %{}) do
      {:ok, result, session} ->
        duration_ms = duration_ms(start_time)
        emit_telemetry(start_time, %{method: "initialize", tool: nil, status: :success})
        log_request_completed(request_id, result, duration_ms, "emissary")

        conn
        |> put_resp_header("mcp-session-id", session.id)
        |> put_resp_header("mcp-protocol-version", @protocol_version)
        |> put_resp_header("x-request-id", request_id)
        |> json(MCP.encode_result(id, result))

      {:error, code, message} ->
        duration_ms = duration_ms(start_time)
        emit_telemetry(start_time, %{method: "initialize", tool: nil, status: :error})
        log_request_failed(request_id, message, Message.error_code(code), duration_ms)

        conn
        |> put_resp_header("x-request-id", request_id)
        |> put_status(400)
        |> json(MCP.encode_error(id, code, message))
    end
  end

  defp handle_message(conn, session, params, request_id, start_time) do
    method = params["method"]
    tool = extract_tool(params)
    action = extract_action(params)

    # Inject request_id and session_id into context
    context = %{session.context | request_id: request_id, session_id: session.id}
    session = %{session | context: context}

    # Log request start asynchronously
    log_request_started(context, request_id, %{
      method: method,
      tool: tool,
      action: action,
      input: params["params"] || %{}
    })

    case MCP.handle_message(session, params) do
      {:ok, result, id} ->
        duration_ms = duration_ms(start_time)
        routed_to = determine_routed_to(tool, action)
        emit_telemetry(start_time, %{method: method, tool: tool, status: :success})
        log_request_completed(request_id, result, duration_ms, routed_to)

        conn
        |> put_resp_header("mcp-protocol-version", @protocol_version)
        |> put_resp_header("x-request-id", request_id)
        |> json(MCP.encode_result(id, result))

      :ok ->
        # Notification - no response needed
        duration_ms = duration_ms(start_time)
        emit_telemetry(start_time, %{method: method, tool: tool, status: :success})
        log_request_completed(request_id, %{}, duration_ms, "emissary")

        conn
        |> put_resp_header("x-request-id", request_id)
        |> send_resp(202, "")

      {:error, code, message, id} ->
        duration_ms = duration_ms(start_time)
        emit_telemetry(start_time, %{method: method, tool: tool, status: :error})
        log_request_failed(request_id, message, Message.error_code(code), duration_ms)

        conn
        |> put_resp_header("x-request-id", request_id)
        |> put_status(400)
        |> json(MCP.encode_error(id, code, message))

      {:error, code, message} ->
        duration_ms = duration_ms(start_time)
        emit_telemetry(start_time, %{method: method, tool: tool, status: :error})
        log_request_failed(request_id, message, Message.error_code(code), duration_ms)

        conn
        |> put_resp_header("x-request-id", request_id)
        |> put_status(400)
        |> json(%{
          "jsonrpc" => "2.0",
          "error" => %{"code" => Message.error_code(code), "message" => message},
          "id" => nil
        })
    end
  end

  @doc """
  Terminate an MCP session.

  DELETE /mcp with Mcp-Session-Id header.
  """
  def terminate_session(conn, _params) do
    case conn.assigns[:mcp_session] do
      nil ->
        send_resp(conn, 404, "")

      session ->
        Session.terminate(session.id)
        send_resp(conn, 202, "")
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp extract_tool(%{"method" => "tools/call", "params" => %{"name" => name}}), do: name
  defp extract_tool(%{"method" => "resources/read"}), do: "resources"
  defp extract_tool(_), do: nil

  defp extract_action(%{"params" => %{"arguments" => %{"action" => action}}}), do: action
  defp extract_action(_), do: nil

  defp determine_routed_to(tool, _action) do
    case tool do
      "execution" -> "opus"
      "build" -> "locus"
      "component" -> "compendium"
      "storage" -> "arca"
      "session" -> "sanctum"
      "permission" -> "sanctum"
      "secret" -> "sanctum"
      "key" -> "sanctum"
      "audit" -> "sanctum"
      "system" -> "emissary"
      _ -> "emissary"
    end
  end

  defp duration_ms(start_time) do
    System.monotonic_time()
    |> Kernel.-(start_time)
    |> System.convert_time_unit(:native, :millisecond)
  end

  # Logging - failures must not break requests
  defp log_request_started(context, request_id, data) do
    try do
      result = RequestLog.log_started(context, request_id, data)
      if result != :ok do
        require Logger
        Logger.error("Request log_started returned: #{inspect(result)}")
      end
      result
    rescue
      e ->
        require Logger
        Logger.error("Request log failed: #{inspect(e)}")
        :ok
    end
  end

  defp log_request_completed(request_id, output, duration_ms, routed_to) do
    try do
      RequestLog.log_completed(request_id, %{
        output: output,
        duration_ms: duration_ms,
        routed_to: routed_to
      })
    rescue
      _ -> :ok
    end
  end

  defp log_request_failed(request_id, error, code, duration_ms) do
    try do
      RequestLog.log_failed(request_id, %{
        error: error,
        code: code,
        duration_ms: duration_ms
      })
    rescue
      _ -> :ok
    end
  end

  defp emit_telemetry(start_time, metadata) do
    :telemetry.execute(
      [:cyfr, :emissary, :request],
      %{duration: System.monotonic_time() - start_time},
      metadata
    )
  end
end
