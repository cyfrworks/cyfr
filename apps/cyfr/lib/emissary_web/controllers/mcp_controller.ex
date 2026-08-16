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
  establish. `EmissaryWeb.Plugs.MCPRequestMetadata` enforces that before this
  controller
  runs.

  ## Response

  Two shapes:

    * **`application/json`** — one object. The default, and what a request that
      never reports progress gets even if it asked for it.
    * **`text/event-stream`** — opened the moment a request carrying
      `_meta.progressToken` produces its first `notifications/progress`, then
      carrying each notification as it happens, then the response, then close.
      This is what replaced the standalone `GET /mcp` stream; progress belongs
      to the request that caused it rather than to a connection the client had
      to open separately and correlate by hand.

  Both carry `MCP-Protocol-Version` and `X-Request-Id`.

  ## Cancellation

  Closing the response stream cancels the request — the only cancellation
  signal this transport has. It is noticed on the next write, which is either
  the next notification or the keep-alive comment, and it kills the tool task
  through `Emissary.MCP.RunningTasks` as well as the wrapper waiting on it.

  ## Telemetry

  Emits `[:cyfr, :emissary, :request]` on every request with:
  - Measurements: `%{duration: native_time, duration_ms: integer}`
  - Metadata: `%{method: String.t(), tool: String.t() | nil, status: :success | :error, action: String.t() | nil, request_id: String.t()}`
  """

  use EmissaryWeb, :controller

  alias Emissary.MCP
  alias Emissary.MCP.{Message, Progress, RequestLog, Subscriptions}
  require Logger
  alias Emissary.UUID7

  @protocol_version Emissary.MCP.Protocol.version()
  @protocol_version_header Emissary.MCP.Protocol.protocol_version_header()

  @doc """
  Handle MCP POST requests.

  Discovery answers before authentication; everything else needs a credential.
  """
  # "The body of the HTTP POST MUST be a single JSON-RPC request or
  # notification."
  # Plug.Parsers wraps a top-level JSON array as %{"_json" => [...]}, so this
  # is the shape a batch actually arrives in — a bare `is_list(params)` clause
  # would never match a request that went through the endpoint.
  def handle(conn, %{"_json" => batch}) when is_list(batch) do
    # A batch has no single id, so `nil` here is correct rather than lossy.
    conn
    |> put_resp_header(@protocol_version_header, @protocol_version)
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

    # One path for every method, including `server/discover`. It once had a
    # branch of its own so it could answer before authentication, which it did
    # not need: an anonymous caller reaches the public surface anyway and the
    # router gates per action. The branch bought nothing and skipped
    # `Message.decode/1`, so a discovery request with a null id — which the
    # specification forbids — was answered 200 instead of rejected.
    #
    # `Plugs.Authenticate` has already resolved a context, authenticated or
    # not; "not authenticated" is the tools' answer to give, not the
    # transport's. The request id is stamped on it here so everything the
    # request goes on to do — including a component's own tool calls, which
    # inherit this context through the guest closure — files under one key.
    ctx = %{conn.assigns.context | request_id: request_id}

    # `subscriptions/listen` is answered here rather than through the dispatcher
    # for a reason the discovery branch above did not have: its response *is* an
    # open stream that outlives the call, so it cannot return a result for
    # someone else to encode. Header validation happened in the pipeline like
    # any other request; the auth gate lives in `listen/4` itself, because the
    # dispatcher gate this method skips is where every other caller meets it.
    case params["method"] do
      "subscriptions/listen" -> listen(conn, ctx, params, request_id)
      _ -> handle_message(conn, ctx, params, request_id, start_time)
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
    |> put_resp_header(@protocol_version_header, @protocol_version)
    |> put_resp_header("allow", "POST, OPTIONS")
    |> EmissaryWeb.MCPError.send(
      405,
      :invalid_request,
      "#{conn.method} is not supported on the MCP endpoint. " <>
        "This revision uses POST only: a request's progress travels on its own " <>
        "response stream, and there is no session to terminate."
    )
  end

  defp handle_message(conn, context, params, request_id, start_time) do
    method = params["method"]
    tool = extract_tool(params)
    action = extract_action(params)

    # The transport's own row. Its call id is the request id: this call *is*
    # the request. Calls made beneath it get their own ids and point back here
    # through `request_id`.
    log_request_started(context, request_id, %{
      method: method,
      tool: tool,
      action: action,
      input: params["params"] || %{}
    })

    routed_to = determine_routed_to(tool, action)

    # Headers go on before anything can commit the response: once the stream
    # below is opened they can no longer be set.
    conn =
      conn
      |> put_resp_header(@protocol_version_header, @protocol_version)
      |> put_resp_header("x-request-id", request_id)

    {conn, outcome} = dispatch(conn, context, params, request_id)

    case outcome do
      :cancelled ->
        emit_telemetry(start_time, context, %{
          method: method,
          tool: tool,
          status: :cancelled,
          action: action,
          request_id: request_id
        })

        log_request_failed(
          context,
          request_id,
          "Client closed the response stream",
          Message.error_code(:request_cancelled),
          duration_ms(start_time),
          routed_to
        )

        conn

      {:ok, result, id} ->
        duration_ms = duration_ms(start_time)

        emit_telemetry(start_time, context, %{
          method: method,
          tool: tool,
          status: :success,
          action: action,
          request_id: request_id
        })

        log_request_completed(context, request_id, result, duration_ms, routed_to)

        respond(conn, Message.encode_result(id, result))

      :ok ->
        # Notification - no response needed
        duration_ms = duration_ms(start_time)

        emit_telemetry(start_time, context, %{
          method: method,
          tool: tool,
          status: :success,
          action: action,
          request_id: request_id
        })

        log_request_completed(context, request_id, %{}, duration_ms, "emissary")

        send_resp(conn, 202, "")

      {:error, code, message, id} ->
        duration_ms = duration_ms(start_time)

        emit_telemetry(start_time, context, %{
          method: method,
          tool: tool,
          status: :error,
          action: action,
          request_id: request_id
        })

        log_request_failed(
          context,
          request_id,
          message,
          Message.error_code(code),
          duration_ms,
          routed_to
        )

        respond_error(conn, code, Message.encode_error(id, code, message))

      {:error, code, message} ->
        duration_ms = duration_ms(start_time)

        emit_telemetry(start_time, context, %{
          method: method,
          tool: tool,
          status: :error,
          action: action,
          request_id: request_id
        })

        log_request_failed(
          context,
          request_id,
          message,
          Message.error_code(code),
          duration_ms,
          routed_to
        )

        respond_error(conn, code, Message.encode_error(nil, code, message))
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

  # An open stream pins a process and a socket for up to the full stream
  # window, and the dispatcher's auth gate never sees this method — the stream
  # is answered before it — so both bounds live here.
  #
  # A credential is required on every install, not only the ones with an auth
  # provider: an operator authenticates with an API key either way, so a
  # request carrying nothing at all is a stranger in both deployments.
  defp listen(conn, context, params, request_id) do
    id = params["id"]

    if not context.authenticated do
      listen_error(
        conn,
        request_id,
        id,
        :auth_required,
        "Unauthorized: subscriptions/listen requires authentication"
      )
    else
      case claim_stream_slot(context) do
        :ok ->
          open_stream(conn, context, params, request_id, id)

        {:error, :stream_limit} ->
          listen_error(
            conn,
            request_id,
            id,
            :rate_limited,
            "Too many concurrent subscription streams for this caller"
          )
      end
    end
  end

  defp open_stream(conn, context, params, request_id, id) do
    filter = get_in(params, ["params", "notifications"]) || %{}
    {:ok, acknowledged} = Subscriptions.listen(context, filter)
    deadline = System.monotonic_time(:millisecond) + max_stream_ms()

    conn
    |> put_resp_header(@protocol_version_header, @protocol_version)
    |> put_resp_header("x-request-id", request_id)
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("x-accel-buffering", "no")
    |> send_chunked(200)
    |> acknowledge(id, acknowledged)
    |> listen_loop(id, deadline)
  end

  defp listen_error(conn, request_id, id, code, message) do
    conn
    |> put_resp_header(@protocol_version_header, @protocol_version)
    |> put_resp_header("x-request-id", request_id)
    |> respond_error(code, Message.encode_error(id, code, message))
  end

  # One Registry entry per open stream, keyed by caller. The entry dies with
  # the conn process, so slots free themselves; the count is read under the
  # same key before registering. The window between count and register can
  # briefly overshoot under a burst — acceptable slack for a bound whose job
  # is stopping unbounded socket pinning.
  defp claim_stream_slot(context) do
    key = {context.athanor_id, context.user_id}
    limit = Application.get_env(:cyfr, :mcp_subscription_max_concurrent, 8)

    if length(Registry.lookup(Emissary.MCP.SubscriptionRegistry, key)) >= limit do
      {:error, :stream_limit}
    else
      {:ok, _} = Registry.register(Emissary.MCP.SubscriptionRegistry, key, :stream)
      :ok
    end
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
      Message.encode_result(id, %{"_meta" => %{Subscriptions.subscription_id_key() => id}})
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
  # Dispatch and response modes
  # ============================================================================

  # `progressToken` is the client's opt-in to receiving progress. It is the only
  # signal: a server that streamed whenever it felt like it would break clients
  # that asked for one JSON object.
  #
  # Only a *request* can stream. A notification is answered `202` with no body,
  # and a stream opened underneath it could not be taken back.
  defp progress_token(%{"id" => id, "params" => %{"_meta" => %{"progressToken" => token}}})
       when not is_nil(id) and not is_nil(token),
       do: token

  defp progress_token(_params), do: nil

  # Run the request and return `{conn, outcome}` — `MCP.handle_message/2`'s
  # result, or `:cancelled` when the caller hung up while it was still running.
  defp dispatch(conn, context, params, request_id) do
    case progress_token(params) do
      nil -> {conn, MCP.handle_message(context, params)}
      token -> streamed_dispatch(conn, context, params, request_id, token)
    end
  end

  # The work runs in a task so this process stays free to write progress as it
  # arrives. It used to run inline and the stream was opened afterwards, which
  # meant every notification sat in the mailbox until the work had finished and
  # then arrived in one burst — progress reported after the fact is not
  # progress. It also left nothing for a client to close, so the cancellation
  # rule below had no way to fire.
  #
  # `Progress.listen/2` registers *this* process before the task starts, so a
  # notification emitted immediately cannot be missed.
  defp streamed_dispatch(conn, context, params, request_id, token) do
    Progress.listen(request_id, token)

    task =
      Task.Supervisor.async_nolink(Emissary.TaskSupervisor, fn ->
        MCP.handle_message(context, params)
      end)

    pump(conn, task, request_id)
  end

  # The stream is opened on the first notification rather than up front, because
  # opening it commits `200` — and this revision makes the status load-bearing:
  # an unimplemented method MUST answer `404`, a rejected one `400`, and a
  # dual-era client reads the status to tell a modern server from a legacy one.
  # Those outcomes are decided in the first moments of dispatch, before any work
  # worth reporting on has happened, so waiting for something to report costs
  # nothing and keeps the status codes honest.
  defp pump(conn, %Task{ref: ref} = task, request_id) do
    receive do
      {:mcp_progress, notification} ->
        case conn |> open_stream() |> write_event(notification) do
          {:ok, conn} -> pump(conn, task, request_id)
          {:error, conn} -> {conn, cancel_work(task, request_id)}
        end

      {^ref, outcome} ->
        Process.demonitor(ref, [:flush])
        {conn, outcome}

      {:DOWN, ^ref, :process, _pid, reason} ->
        Logger.error("[MCPController] request handler exited: #{inspect(reason)}")
        {conn, {:error, :internal_error, "Request handler exited unexpectedly"}}
    after
      @keep_alive_ms ->
        case keep_alive(conn) do
          {:ok, conn} -> pump(conn, task, request_id)
          {:error, conn} -> {conn, cancel_work(task, request_id)}
        end
    end
  end

  # "Closing the SSE response stream MUST be treated by the server as
  # cancellation of that request." The tool task is killed through
  # `RunningTasks`, which is keyed on the same request id; the wrapper task is
  # killed after it, since killing the wrapper alone would leave the
  # `async_nolink`'d tool task running with nobody waiting on it.
  defp cancel_work(%Task{} = task, request_id) do
    Emissary.MCP.RunningTasks.cancel(request_id)
    Task.shutdown(task, :brutal_kill)
    :cancelled
  end

  defp open_stream(%Plug.Conn{state: :chunked} = conn), do: conn

  defp open_stream(conn) do
    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    # Reverse proxies buffer by default, which turns a progress stream into one
    # delivery at the end — the exact thing the client asked to avoid.
    |> put_resp_header("x-accel-buffering", "no")
    |> send_chunked(200)
  end

  # Nothing to keep alive until the stream exists. Once it does, the comment
  # line doubles as the disconnect probe: a quiet subscription and a dead client
  # look identical until something is written.
  defp keep_alive(%Plug.Conn{state: :chunked} = conn), do: chunk(conn, ":\n\n") |> tag(conn)
  defp keep_alive(conn), do: {:ok, conn}

  defp write_event(conn, payload) do
    case Jason.encode(payload) do
      {:ok, encoded} ->
        chunk(conn, "data: #{encoded}\n\n") |> tag(conn)

      {:error, reason} ->
        # Losing one notification must not fail the work it was reporting on.
        Logger.error("[MCPController] progress payload not encodable: #{inspect(reason)}")
        {:ok, conn}
    end
  end

  defp tag({:ok, conn}, _prev), do: {:ok, conn}
  defp tag({:error, _reason}, prev), do: {:error, prev}

  # A response on an open stream is its last frame; otherwise it is the body.
  defp respond(%Plug.Conn{state: :chunked} = conn, payload) do
    {_, conn} = write_event(conn, payload)
    conn
  end

  defp respond(conn, payload), do: json(conn, payload)

  # Once the stream is open the status has already been sent as `200`, and the
  # error travels as the last frame. That is only reachable for errors raised
  # after work had begun reporting; the status-bearing rejections all happen
  # before the first notification (see `pump/3`).
  defp respond_error(%Plug.Conn{state: :chunked} = conn, _code, payload),
    do: respond(conn, payload)

  defp respond_error(conn, code, payload) do
    conn
    |> put_status(http_status_for(code))
    |> json(payload)
  end

  defp sse_event(conn, payload) do
    {_, conn} = write_event(conn, payload)
    conn
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
  defp http_status_for(:auth_required), do: 401
  defp http_status_for(:rate_limited), do: 429
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

    # Carry the athanor so Prism.TelemetryBridge routes the broadcast to this
    # athanor's dashboard subscribers.
    metadata = Map.put(metadata, :athanor_id, context.athanor_id)

    :telemetry.execute(
      [:cyfr, :emissary, :request],
      %{duration: duration, duration_ms: duration_ms},
      metadata
    )
  end
end
