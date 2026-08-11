# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.MCPController do
  @moduledoc """
  MCP HTTP controller implementing the Streamable HTTP transport.

  `POST /mcp` is the whole endpoint. `GET` and `DELETE` are routed only so they
  can answer `405` to clients written against the previous transport.

  ## Request

  One JSON-RPC 2.0 request or notification per POST — never a batch. Every
  request authenticates and declares its own protocol version and client
  capabilities in `params._meta`, so there is no handshake and nothing to
  establish. `EmissaryWeb.Plugs.MCPSession` enforces that before this controller
  runs.

  ## Response

  Two shapes, chosen by the client:

    * **`application/json`** — one object. The default.
    * **`text/event-stream`** — when the request carries `_meta.progressToken`:
      any `notifications/progress` the work produced, then the response, then
      close. This is what replaced the standalone `GET /mcp` stream; progress now
      belongs to the request that caused it rather than to a connection the
      client had to open separately and correlate by hand.

  Both carry `MCP-Protocol-Version` and `X-Request-Id`.

  ## Telemetry

  Emits `[:cyfr, :emissary, :request]` on every request with:
  - Measurements: `%{duration: native_time, duration_ms: integer}`
  - Metadata: `%{method: String.t(), tool: String.t() | nil, status: :success | :error, action: String.t() | nil, request_id: String.t(), session_id: String.t() | nil}`
  """

  use EmissaryWeb, :controller

  alias Emissary.MCP
  alias Emissary.MCP.{Message, Progress, RequestLog, Session, Subscriptions}
  require Logger
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

    # `subscriptions/listen` is answered here rather than through the dispatcher
    # for a reason the discovery branch above did not have: its response *is* an
    # open stream that outlives the call, so it cannot return a result for
    # someone else to encode. Everything else about it — auth, header validation
    # — has already happened in the pipeline, same as any other request.
    case params["method"] do
      "subscriptions/listen" -> listen(conn, session, params, request_id)
      _ -> handle_message(conn, session, params, request_id, start_time)
    end
  end

  @doc """
  Answer `GET` and `DELETE` on the MCP endpoint with `405`.

  Both were part of the previous transport — `GET` opened a standalone
  notification stream, `DELETE` terminated a session — and a client written
  against that revision will still try them. `405` tells it plainly that the verb
  is gone, which a route-miss `404` does not: `404` reads as "wrong URL", and
  sends the client looking for an endpoint elsewhere.
  """
  def method_not_allowed(conn, _params) do
    conn
    |> put_resp_header("mcp-protocol-version", @protocol_version)
    |> put_resp_header("allow", "POST, OPTIONS")
    |> EmissaryWeb.MCPError.send(
      405,
      :invalid_request,
      "#{conn.method} is not supported on the MCP endpoint. " <>
        "This revision uses POST only: a request's progress travels on its own " <>
        "response stream, and there is no session to terminate."
    )
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

    # A client opts into progress by sending `_meta.progressToken`. Registering
    # before dispatch, not after, is what makes it race-free: the work runs in a
    # task and can report before this process would otherwise get around to it.
    progress_token = progress_token(params)
    if progress_token, do: Progress.listen(request_id, progress_token)

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
        |> respond(MCP.encode_result(id, result), progress_token)

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
  # subscriptions/listen
  # ============================================================================

  # How long to wait before writing a keep-alive comment. Intermediaries and
  # client idle timeouts close a connection that says nothing; a quiet
  # subscription is the normal state, not a broken one.
  @keep_alive_ms :timer.seconds(15)

  # A subscription does not live forever. Nothing in the protocol requires a
  # bound, but an unbounded one means a client that vanishes without closing
  # cleanly holds a process and a socket until the VM restarts — and the
  # specification already defines how a server ends one on its own initiative,
  # so there is a correct way to do it. The client reconnects; that is what the
  # graceful-close response is for.
  defp max_stream_ms do
    Application.get_env(:cyfr, :mcp_subscription_max_ms, :timer.minutes(30))
  end

  defp listen(conn, session, params, request_id) do
    id = params["id"]
    filter = get_in(params, ["params", "notifications"]) || %{}

    {:ok, acknowledged} = Subscriptions.listen(session.context, filter)
    deadline = System.monotonic_time(:millisecond) + max_stream_ms()

    conn
    |> put_resp_header("mcp-protocol-version", @protocol_version)
    |> put_resp_header("x-request-id", request_id)
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("x-accel-buffering", "no")
    |> send_chunked(200)
    |> acknowledge(id, acknowledged)
    |> listen_loop(id, deadline)
  end

  # The acknowledgment must be the first message on the stream, and must carry
  # the subscription id — on stdio one channel multiplexes every subscription,
  # so without it a client cannot tell which stream a notification belongs to.
  defp acknowledge(conn, id, acknowledged) do
    sse_event(
      conn,
      Message.encode_notification("notifications/subscriptions/acknowledged", %{
        "_meta" => %{Subscriptions.subscription_id_key() => id},
        "notifications" => acknowledged
      })
    )
  end

  # A write failure ends the stream. `sse_event/2` swallows one because a dead
  # client must not crash a one-shot response, but here that would spin against
  # a closed socket forever — so the loop uses the reporting form.
  defp listen_loop(conn, id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      close_gracefully(conn, id)
    else
      receive do
        message ->
          case Subscriptions.notification_for(message) do
            {:ok, method, params} ->
              params = Map.put(params, "_meta", %{Subscriptions.subscription_id_key() => id})

              write(conn, Message.encode_notification(method, params), id, deadline)

            :ignore ->
              listen_loop(conn, id, deadline)
          end
      after
        min(@keep_alive_ms, remaining) ->
          # An SSE comment: the client must ignore it, and it costs one line to
          # keep the connection from being reaped during a quiet period.
          case chunk(conn, ":\n\n") do
            {:ok, conn} -> listen_loop(conn, id, deadline)
            {:error, _closed} -> conn
          end
      end
    end
  end

  # Ending on the server's own initiative means answering the original request.
  # A stream that just stops is indistinguishable from a dropped connection; the
  # response says "this ended cleanly", which is what tells a client to
  # reconnect rather than to report a fault.
  defp close_gracefully(conn, id) do
    sse_event(
      conn,
      MCP.encode_result(id, %{"_meta" => %{Subscriptions.subscription_id_key() => id}})
    )
  end

  defp write(conn, payload, id, deadline) do
    case Jason.encode(payload) do
      {:ok, encoded} ->
        case chunk(conn, "data: #{encoded}\n\n") do
          {:ok, conn} -> listen_loop(conn, id, deadline)
          # Closing the stream is this transport's cancellation signal, so a
          # disconnect is an ordinary end rather than a failure to report.
          {:error, _closed} -> conn
        end

      {:error, reason} ->
        Logger.error("[MCPController] subscription payload not encodable: #{inspect(reason)}")
        listen_loop(conn, id, deadline)
    end
  end

  # ============================================================================
  # Response modes
  # ============================================================================

  # `progressToken` is the client's opt-in. It is the only signal: a server that
  # streamed whenever it felt like it would break clients that asked for one JSON
  # object, and the specification makes the choice the client's to make.
  defp progress_token(%{"params" => %{"_meta" => %{"progressToken" => token}}})
       when not is_nil(token),
       do: token

  defp progress_token(_params), do: nil

  # Without a token, one JSON object — the ordinary case, and the cheap one.
  defp respond(conn, payload, nil), do: json(conn, payload)

  # With a token, an SSE stream carrying whatever progress arrived while the work
  # ran, then the response, then close. Everything queued in this process's
  # mailbox is drained first: the work has already finished by the time we get
  # here, so anything still in flight is progress that was reported before the
  # result and must be delivered before it.
  defp respond(conn, payload, _token) do
    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    # Reverse proxies buffer by default, which turns a progress stream into one
    # delivery at the end — the exact thing the client asked to avoid.
    |> put_resp_header("x-accel-buffering", "no")
    |> send_chunked(200)
    |> drain_progress()
    |> sse_event(payload)
  end

  defp drain_progress(conn) do
    receive do
      {:mcp_progress, notification} ->
        conn |> sse_event(notification) |> drain_progress()
    after
      0 -> conn
    end
  end

  defp sse_event(conn, payload) do
    case Jason.encode(payload) do
      {:ok, encoded} ->
        case chunk(conn, "data: #{encoded}\n\n") do
          {:ok, conn} -> conn
          # The client hung up mid-stream. Closing is the cancellation signal in
          # this transport, so there is nothing to report and nobody to report to.
          {:error, _reason} -> conn
        end

      {:error, reason} ->
        Logger.error("[MCPController] progress payload not encodable: #{inspect(reason)}")
        conn
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
