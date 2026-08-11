# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.MCPController do
  @moduledoc """
  MCP HTTP controller implementing Streamable HTTP transport.

  Endpoints:
  - POST /mcp - Handle MCP requests/notifications

  ## Request Format

  POST body must be valid JSON-RPC 2.0:
  - Single request or notification (batching not supported per 2025-11-25 spec)

  ## Headers

  - `Content-Type: application/json` (required)
  - `Accept: application/json, text/event-stream` (recommended)
  - `Authorization: Bearer <credential>` (an API key or a session token)
  - `MCP-Protocol-Version: 2025-11-25` (returned in responses)
  - `X-Request-Id: req_<uuid7>` (returned in responses for correlation)

  ## Response

  Every request authenticates and declares its own protocol version, so there
  is no handshake. Returns a JSON-RPC response with `MCP-Protocol-Version` and
  `X-Request-Id` headers.

  ## Telemetry

  Emits `[:cyfr, :emissary, :request]` on every request with:
  - Measurements: `%{duration: native_time, duration_ms: integer}`
  - Metadata: `%{method: String.t(), tool: String.t() | nil, status: :success | :error, action: String.t() | nil, request_id: String.t(), session_id: String.t() | nil}`
  """

  use EmissaryWeb, :controller

  alias Emissary.MCP
  alias Emissary.MCP.{Message, RequestLog, Session}
  alias Emissary.UUID7

  @protocol_version Emissary.MCP.Protocol.version()

  @doc """
  Handle MCP POST requests.

  Discovery answers before authentication; everything else needs a credential.
  """
  # MCP 2025-11-25: POST body MUST be a single message, not a batch.
  # Plug.Parsers wraps a top-level JSON array as %{"_json" => [...]}, so this
  # is the shape a batch actually arrives in — a bare `is_list(params)` clause
  # would never match a request that went through the endpoint.
  def handle(conn, %{"_json" => batch}) when is_list(batch) do
    # A batch has no single id, so `nil` here is correct rather than lossy.
    conn
    |> put_resp_header("mcp-protocol-version", @protocol_version)
    |> EmissaryWeb.MCPError.send(
      400,
      :invalid_request,
      "Batch requests not supported. Send one message per request."
    )
  end

  def handle(conn, params) do
    request_id = UUID7.request_id()
    Cyfr.LoggerContext.set_request_id(request_id)
    start_time = System.monotonic_time()

    # One path for every method. `server/discover` used to be answered by a
    # branch of its own so that it could reply before authentication — but the
    # ordinary path already does that: an anonymous caller gets an ephemeral
    # session and the router gates per action, and the discovery clause consults
    # neither. The branch bought nothing and skipped `Message.decode/1`, so a
    # discovery request with a null id — which the specification forbids — was
    # answered 200 instead of rejected.
    #
    # There is no session to require here: a bearer caller gets the plug's
    # credential-keyed session, an auth-provider caller an ephemeral one, and an
    # anonymous caller an unauthenticated context. "Not authenticated" is the
    # tools' answer to give, not the transport's.
    session = conn.assigns[:mcp_session] || Session.ephemeral(conn.assigns[:mcp_context])
    handle_message(conn, session, params, request_id, start_time)
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

    routed_to = determine_routed_to(tool, action)

    case MCP.handle_message(session, params) do
      {:ok, result, id} ->
        duration_ms = duration_ms(start_time)

        emit_telemetry(start_time, context, %{
          method: method,
          tool: tool,
          status: :success,
          action: action,
          request_id: request_id,
          session_id: session.id
        })

        log_request_completed(context, request_id, result, duration_ms, routed_to)

        conn
        |> put_resp_header("mcp-protocol-version", @protocol_version)
        |> put_resp_header("x-request-id", request_id)
        |> json(MCP.encode_result(id, result))

      :ok ->
        # Notification - no response needed
        duration_ms = duration_ms(start_time)

        emit_telemetry(start_time, context, %{
          method: method,
          tool: tool,
          status: :success,
          action: action,
          request_id: request_id,
          session_id: session.id
        })

        log_request_completed(context, request_id, %{}, duration_ms, "emissary")

        conn
        |> put_resp_header("mcp-protocol-version", @protocol_version)
        |> put_resp_header("x-request-id", request_id)
        |> send_resp(202, "")

      {:error, code, message, id} ->
        duration_ms = duration_ms(start_time)

        emit_telemetry(start_time, context, %{
          method: method,
          tool: tool,
          status: :error,
          action: action,
          request_id: request_id,
          session_id: session.id
        })

        log_request_failed(
          context,
          request_id,
          message,
          Message.error_code(code),
          duration_ms,
          routed_to
        )

        conn
        |> put_resp_header("mcp-protocol-version", @protocol_version)
        |> put_resp_header("x-request-id", request_id)
        |> put_status(http_status_for(code))
        |> json(MCP.encode_error(id, code, message))

      {:error, code, message} ->
        duration_ms = duration_ms(start_time)

        emit_telemetry(start_time, context, %{
          method: method,
          tool: tool,
          status: :error,
          action: action,
          request_id: request_id,
          session_id: session.id
        })

        log_request_failed(
          context,
          request_id,
          message,
          Message.error_code(code),
          duration_ms,
          routed_to
        )

        conn
        |> put_resp_header("mcp-protocol-version", @protocol_version)
        |> put_resp_header("x-request-id", request_id)
        |> put_status(http_status_for(code))
        |> json(MCP.encode_error(nil, code, message))
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # An unimplemented method is `404`, not `400`. The specification makes the
  # distinction load-bearing for backward compatibility: a dual-era client reads
  # the status *and* the body to decide whether it is talking to a modern server
  # that lacks this method, or a legacy server that lacks the whole endpoint.
  # Answering `400` for both makes that undecidable.
  defp http_status_for(:method_not_found), do: 404
  defp http_status_for(_code), do: 400

  defp extract_tool(%{"method" => "tools/call", "params" => %{"name" => name}}), do: name
  defp extract_tool(%{"method" => "resources/read"}), do: "resources"
  defp extract_tool(_), do: nil

  defp extract_action(%{"params" => %{"arguments" => %{"action" => action}}}), do: action
  defp extract_action(_), do: nil

  defp determine_routed_to(nil, _action), do: "emissary"

  defp determine_routed_to(tool, _action) do
    case Arca.Cache.get({:mcp_tool, tool}) do
      {:ok, {module, _meta}} -> module_to_service(module)
      :miss -> "emissary"
    end
  end

  @module_service_map %{
    "Opus" => "opus",
    "Locus" => "locus",
    "Compendium" => "compendium",
    "Arca" => "arca",
    "Sanctum" => "sanctum",
    "Emissary" => "emissary"
  }

  defp module_to_service(module) when is_atom(module) do
    case Module.split(module) do
      [top | _] -> Map.get(@module_service_map, top, "emissary")
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

  defp log_request_completed(ctx, request_id, output, duration_ms, routed_to) do
    try do
      RequestLog.log_completed(ctx, request_id, %{
        output: output,
        duration_ms: duration_ms,
        routed_to: routed_to
      })
    rescue
      e ->
        require Logger

        Logger.error(
          "[MCPController] log_request_completed failed for #{request_id}: #{inspect(e)}"
        )

        :ok
    end
  end

  defp log_request_failed(ctx, request_id, error, code, duration_ms, routed_to) do
    try do
      RequestLog.log_failed(ctx, request_id, %{
        error: error,
        code: code,
        duration_ms: duration_ms,
        routed_to: routed_to
      })
    rescue
      e ->
        require Logger
        Logger.error("[MCPController] log_request_failed failed for #{request_id}: #{inspect(e)}")
        :ok
    end
  end

  defp emit_telemetry(start_time, %Sanctum.Context{} = context, metadata) do
    duration = System.monotonic_time() - start_time
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    # Carry the tenant so Prism.TelemetryBridge routes the broadcast to this
    # tenant's dashboard subscribers (and not, e.g., the local sentinel).
    metadata =
      Map.merge(metadata, %{org_id: context.org_id, project_id: context.project_id})

    :telemetry.execute(
      [:cyfr, :emissary, :request],
      %{duration: duration, duration_ms: duration_ms},
      metadata
    )
  end
end
