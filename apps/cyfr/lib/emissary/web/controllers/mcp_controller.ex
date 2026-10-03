# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.MCPController do
  @moduledoc """
  MCP HTTP controller implementing the Streamable HTTP transport.

  `POST /mcp` accepts requests. `GET` and `DELETE` return `405`.

  ## Request

  One JSON-RPC 2.0 request or notification per POST — never a batch. Every
  request authenticates and declares its own protocol version and client
  capabilities in `params._meta`, so there is no handshake and nothing to
  establish. `Emissary.Web.Plugs.MCPRequestMetadata` enforces that before this
  controller
  runs.

  A `tools/call` repeating a sensitive change carries the confirmation's
  secret id in `params._meta["cyfr/confirmationId"]`; the call runs with it
  as its context's `confirmation_id`, and no other method reads it.

  ## Response

  Two shapes:

      * **`application/json`** — one response object, including requests that
        opt into progress but emit no notifications.
      * **`text/event-stream`** — opens on the first progress notification for
        a request with `_meta.progressToken`, streams subsequent notifications,
        then sends the response and closes.

  Both carry `MCP-Protocol-Version` and `X-Request-Id`.

  ## Audit

  The transport records no row of its own. A `tools/call` or
  `resources/read` is an operation call, recorded by the gate as one
  admission decision with its request-log row (`Grimoire.Decisions`),
  correlated to this request by its `X-Request-Id`; discovery is not
  recorded.

  ## Cancellation

  Closing the response stream cancels the request — the only cancellation
  signal this transport has. It is noticed on the next write, which is either
  the next notification or the keep-alive comment, and it kills the tool task
  through the gate (`Grimoire.cancel_request/1`) as well as the wrapper
  waiting on it. A call whose wrapper is killed that way records no
  completion: its decision stays admitted with an unknown outcome.

  ## Telemetry

  Emits `[:cyfr, :emissary, :request]` on every request with:
  - Measurements: `%{duration: native_time, duration_ms: integer}`
  - Metadata: `%{method: String.t(), tool: String.t() | nil, status: :success | :error | :cancelled, action: String.t() | nil, request_id: String.t()}`
  """

  use Emissary.Web, :controller

  alias Emissary.MCP
  alias Emissary.MCP.{Progress, Subscriptions}
  alias Prima.MCP.Message
  alias CyfrWeb.ContextGuard
  require CyfrWeb.ContextGuard
  require Logger

  @protocol_version Prima.MCP.Protocol.version()
  @protocol_version_header Prima.MCP.Protocol.protocol_version_header()

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
    |> Emissary.Web.MCPError.send(
      400,
      :invalid_request,
      "Batch requests not supported. Send one message per request."
    )
  end

  def handle(conn, params) do
    # The request's identity was minted at the pipeline's head
    # (`CyfrWeb.Plugs.CallIdentity`) and stamped on the context by
    # `Authenticate`: nested component calls retain the root request's
    # correlation id, and the gate takes the call id as its own.
    request_id = conn.assigns.request_id
    start_time = System.monotonic_time()

    # Decode every method through Message.decode/1. Authenticate has resolved
    # the caller; the router authorizes each action.
    ctx = conn.assigns.context

    # `subscriptions/listen` is answered here rather than through the dispatcher
    # for a reason the discovery branch above did not have: its response *is* an
    # open stream that outlives the call, so it cannot return a result for
    # someone else to encode. Header validation happened in the pipeline like
    # any other request; the auth gate lives in `listen/4` itself, because the
    # dispatcher gate this method skips is where every other caller meets it.
    case params["method"] do
      "subscriptions/listen" -> listen(conn, ctx, params, request_id)
      _ -> handle_message(conn, confirming(ctx, conn, params), params, request_id, start_time)
    end
  rescue
    # An authorization refusal that raised in the request process itself
    # (outside the tool-task boundary, which converts its own) — answered
    # in the JSON-RPC envelope as the auth error it is, never as a 500.
    e in Sanctum.UnauthorizedError ->
      # The reason's class picks the code: absent identity is
      # `:auth_required`, which is what a client retries on. Answering
      # every refusal `:insufficient_permissions` told an unauthenticated
      # caller their permissions were the problem.
      refusal = Grimoire.classify(e.reason)
      code = Message.refusal_code(refusal, :transport, Grimoire.code_override(refusal))

      # Re-rendered from the reason rather than `Exception.message/1`: the
      # struct bakes its prose at raise time without the auth method, and
      # only the vocabulary can add the API-key remediation hint. Rendered
      # through the renderer, which records it as the request's refusal;
      # on a stream already open the refusal is its last frame.
      message = Sanctum.Unauthorized.message(e.reason, conn.assigns.context.auth_method)

      case conn.state do
        :chunked ->
          conn
          |> CyfrWeb.Plugs.CallIdentity.refused(e.reason)
          |> respond_error(code, Message.encode_error(params["id"], code, message))

        _unsent ->
          Emissary.Web.MCPError.send(conn, http_status_for(code), e.reason, message)
      end
  end

  @doc """
  Answer `GET` and `DELETE` on the MCP endpoint with `405`.

  `GET` and `DELETE` return `405 Method Not Allowed`.
  """
  def method_not_allowed(conn, _params) do
    conn
    |> put_resp_header(@protocol_version_header, @protocol_version)
    |> put_resp_header("allow", "POST, OPTIONS")
    |> Emissary.Web.MCPError.send(
      405,
      :invalid_request,
      "#{conn.method} is not supported on the MCP endpoint. " <>
        "This revision uses POST only: a request's progress travels on its own " <>
        "response stream, and there is no session to terminate."
    )
  end

  # A `tools/call` that repeats a sensitive change names the confirmation it
  # repeats under, which `Emissary.Web.Plugs.MCPRequestMetadata` read from
  # `params._meta` and checked for its spelling. It rides this call's own
  # context, as `PrismWeb.Ops` and the device channel carry it, where the
  # deciding site consumes it (`Sanctum.Consent.Authz`). Every other method,
  # and a call that names none, carries none.
  defp confirming(context, %Plug.Conn{assigns: %{mcp_confirmation_id: id}}, %{
         "method" => "tools/call"
       })
       when is_binary(id),
       do: %{context | confirmation_id: id}

  defp confirming(context, _conn, _params), do: %{context | confirmation_id: nil}

  defp handle_message(conn, context, params, request_id, start_time) do
    method = params["method"]
    tool = extract_tool(params)
    action = extract_action(params)

    # Headers go on before anything can commit the response: once the stream
    # below is opened they can no longer be set. `x-request-id` is the
    # pipeline's (`CyfrWeb.Plugs.CallIdentity`).
    conn = put_resp_header(conn, @protocol_version_header, @protocol_version)

    {conn, outcome} = dispatch(conn, context, params, request_id)

    telemetry = %{method: method, tool: tool, action: action, request_id: request_id}

    case outcome do
      :cancelled ->
        emit_telemetry(start_time, context, Map.put(telemetry, :status, :cancelled))
        conn

      {:ok, result, id} ->
        emit_telemetry(start_time, context, Map.put(telemetry, :status, :success))
        respond(conn, Message.encode_result(id, result))

      :ok ->
        # Notification - no response needed
        emit_telemetry(start_time, context, Map.put(telemetry, :status, :success))
        send_resp(conn, 202, "")

      {:error, code, message, data, id} ->
        emit_telemetry(start_time, context, Map.put(telemetry, :status, :error))
        respond_error(conn, code, Message.encode_error(id, code, message, data))

      {:error, code, message, id} ->
        emit_telemetry(start_time, context, Map.put(telemetry, :status, :error))
        respond_error(conn, code, Message.encode_error(id, code, message))

      {:error, code, message} ->
        emit_telemetry(start_time, context, Map.put(telemetry, :status, :error))
        respond_error(conn, code, Message.encode_error(nil, code, message))
    end
  end

  # ============================================================================
  # subscriptions/listen
  # ============================================================================

  # The per-caller stream bounds live in CyfrWeb.SSE, shared with the
  # execution-events surface under per-surface tags and budgets.
  @keep_alive_ms CyfrWeb.SSE.keep_alive_ms()

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
        :unauthenticated,
        "Unauthorized: subscriptions/listen requires authentication"
      )
    else
      case CyfrWeb.SSE.claim_slot(:mcp_listen, context, :mcp_subscription_max_concurrent) do
        :ok ->
          open_subscription_stream(conn, context, params, request_id, id)

        {:error, :stream_limit} ->
          listen_error(
            conn,
            request_id,
            :stream_limit,
            "Too many concurrent subscription streams for this caller"
          )
      end
    end
  end

  # Distinct name from `open_stream/1` below (the bare SSE open): this one
  # opens the SUBSCRIPTION stream and adds the two MCP-specific headers;
  # the four SSE mechanics belong to `CyfrWeb.SSE.open/1`.
  #
  # Each acknowledged type is admitted by the gate first
  # (`Subscriptions.listen/2`), which records its own decision; a refusal
  # there is answered without a second one. The stream ends at the earlier
  # of the operator's window and the grants' own deadline.
  defp open_subscription_stream(conn, context, params, request_id, id) do
    filter = get_in(params, ["params", "notifications"]) || %{}

    case Subscriptions.listen(context, filter) do
      {:ok, acknowledged, grants} ->
        watch = ContextGuard.watch(context)
        deadline = stream_deadline(grants)

        conn
        |> put_resp_header(@protocol_version_header, @protocol_version)
        |> put_resp_header("x-request-id", request_id)
        |> CyfrWeb.SSE.open()
        |> acknowledge(id, acknowledged)
        |> listen_loop(id, deadline, watch)
        |> tap(fn _conn -> Subscriptions.close(context, grants) end)

      {:error, %Prima.Refusal{} = refusal} ->
        conn
        |> CyfrWeb.Plugs.CallIdentity.decided()
        |> listen_error(request_id, refusal, refusal.message)
    end
  end

  defp stream_deadline(grants) do
    window = CyfrWeb.SSE.deadline(:mcp_subscription_max_ms)

    case Subscriptions.remaining_ms(grants) do
      :infinity -> window
      remaining -> min(window, System.monotonic_time(:millisecond) + remaining)
    end
  end

  # A refusal of the listen itself, before any stream opens: rendered
  # through the renderer, which records it once as the request's refused
  # decision and echoes the request's JSON-RPC id. `reason` is the
  # refusal's term; its class picks the code and the HTTP status.
  defp listen_error(conn, request_id, reason, message) do
    refusal = Grimoire.classify(reason)
    code = Message.refusal_code(refusal, :transport, Grimoire.code_override(refusal))

    conn
    |> put_resp_header("x-request-id", request_id)
    |> Emissary.Web.MCPError.send(http_status_for(code), reason, message)
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
  #
  # The caller's standing is watched the whole time
  # (`CyfrWeb.ContextGuard.watch/1`): a standing announcement about them, or
  # the watch's periodic recheck, revalidates, and a refusal answers the
  # listen request with its error — the stream does not outlive its credential.
  defp listen_loop(conn, id, deadline, watch) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      ContextGuard.unwatch(watch)
      close_gracefully(conn, id)
    else
      receive do
        message when ContextGuard.standing_message(message) ->
          case ContextGuard.standing(message, watch) do
            {:ok, watch} ->
              listen_loop(conn, id, deadline, watch)

            {:refused, reason} ->
              ContextGuard.unwatch(watch)
              refuse_stream(conn, id, reason)

            :ignore ->
              listen_loop(conn, id, deadline, watch)
          end

        message ->
          # A listener that fell too far behind ends its stream with the
          # typed refusal rather than delivering some of what it owes.
          with :ok <- Subscriptions.backlog(),
               {:ok, method, params} <- Subscriptions.notification_for(message) do
            params = Map.put(params, "_meta", %{Subscriptions.subscription_id_key() => id})

            write(conn, Message.encode_notification(method, params), id, deadline, watch)
          else
            :ignore ->
              listen_loop(conn, id, deadline, watch)

            {:error, %Prima.Refusal{} = refusal} ->
              ContextGuard.unwatch(watch)
              refuse_stream(conn, id, refusal)
          end
      after
        min(@keep_alive_ms, remaining) ->
          # An SSE comment: the client must ignore it, and it costs one line to
          # keep the connection from being reaped during a quiet period.
          case chunk(conn, ":\n\n") do
            {:ok, conn} ->
              listen_loop(conn, id, deadline, watch)

            {:error, _closed} ->
              ContextGuard.unwatch(watch)
              conn
          end
      end
    end
  end

  # The listen request answered with the refusal its credential now earns:
  # retryable when the store could not answer or a remote person's identity
  # could not be confirmed fresh, a sign-in otherwise.
  defp refuse_stream(conn, id, :identity_stale),
    do: refuse_stream(conn, id, Grimoire.classify(:identity_stale))

  defp refuse_stream(conn, id, :unavailable) do
    refusal = Grimoire.classify(:auth_provider_error)

    sse_event(
      conn,
      Message.encode_error(
        id,
        Message.refusal_code(refusal, :transport, Grimoire.code_override(refusal)),
        refusal.message
      )
    )
  end

  defp refuse_stream(conn, id, %Prima.Refusal{} = refusal) do
    sse_event(
      conn,
      Message.encode_error(
        id,
        Message.refusal_code(refusal, :transport, Grimoire.code_override(refusal)),
        refusal.message
      )
    )
  end

  defp refuse_stream(conn, id, _refused) do
    sse_event(
      conn,
      Message.encode_error(
        id,
        :auth_required,
        "Unauthorized: the credential behind this subscription no longer stands"
      )
    )
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

  defp write(conn, payload, id, deadline, watch) do
    case Jason.encode(payload) do
      {:ok, encoded} ->
        case chunk(conn, "data: #{encoded}\n\n") do
          {:ok, conn} ->
            listen_loop(conn, id, deadline, watch)

          # Closing the stream is this transport's cancellation signal, so a
          # disconnect is an ordinary end rather than a failure to report.
          {:error, _closed} ->
            ContextGuard.unwatch(watch)
            conn
        end

      {:error, reason} ->
        Logger.error("[MCPController] subscription payload not encodable: #{inspect(reason)}")
        listen_loop(conn, id, deadline, watch)
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

  # Run work in a task while this process streams progress and handles
  # client disconnection. The request's progress topic is subscribed and
  # its token bound before the task starts, so immediate notifications are
  # received; on completion or cancel the subscription ends and whatever
  # progress was already queued is discarded, so nothing is written after.
  defp streamed_dispatch(conn, context, params, request_id, token) do
    topic = progress_topic(context, request_id)
    :ok = Progress.listen(request_id, token)

    logger_metadata = Prima.LoggerContext.capture()

    task =
      Task.Supervisor.async_nolink(Emissary.TaskSupervisor, fn ->
        Prima.LoggerContext.restore(logger_metadata)
        MCP.handle_message(context, params)
      end)

    result = pump(conn, task, request_id)
    stop_progress(topic, request_id)
    result
  end

  # A caller with no athanor runs nothing that reports progress: nothing is
  # subscribed, and the request answers as one JSON object.
  defp progress_topic(%Sanctum.Context{athanor_id: athanor_id} = context, request_id)
       when is_binary(athanor_id) and athanor_id != "" do
    actor = Sanctum.Context.actor(context)
    topic = Cyfr.Bus.progress(actor, {:request, request_id})
    :ok = Cyfr.Bus.subscribe(actor, topic)
    {actor, topic}
  end

  defp progress_topic(_context, _request_id), do: nil

  defp stop_progress(nil, request_id), do: Progress.forget(request_id)

  defp stop_progress({actor, topic}, request_id) do
    Cyfr.Bus.unsubscribe(actor, topic)
    drain_progress(request_id)
    Progress.forget(request_id)
  end

  defp drain_progress(request_id) do
    receive do
      %Cyfr.Bus.Progress{request_id: ^request_id} -> drain_progress(request_id)
    after
      0 -> :ok
    end
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
      %Cyfr.Bus.Progress{request_id: ^request_id} = step ->
        case Progress.notification(step) do
          {:ok, notification} ->
            case conn |> open_stream() |> write_event(notification) do
              {:ok, conn} -> pump(conn, task, request_id)
              {:error, conn} -> {conn, cancel_work(task, request_id)}
            end

          :ignore ->
            pump(conn, task, request_id)
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
  # cancellation of that request." The tool task is killed through the
  # gate, which tracks it under the same request id; the wrapper task is
  # killed after it, since killing the wrapper alone would leave the
  # `async_nolink`'d tool task running with nobody waiting on it.
  defp cancel_work(%Task{} = task, request_id) do
    Grimoire.cancel_request(request_id)
    Task.shutdown(task, :brutal_kill)
    :cancelled
  end

  defp open_stream(conn), do: CyfrWeb.SSE.open(conn)

  # Nothing to keep alive until the stream exists. Once it does, the comment
  # line doubles as the disconnect probe: a quiet subscription and a dead client
  # look identical until something is written.
  defp keep_alive(%Plug.Conn{state: :chunked} = conn),
    do: chunk(conn, CyfrWeb.SSE.keep_alive_comment()) |> tag(conn)

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

  # Return 404 with -32601 for an unimplemented method. Clients use the
  # status and body to distinguish a missing method from a missing endpoint.
  defp http_status_for(:method_not_found), do: 404
  defp http_status_for(:auth_required), do: 401
  defp http_status_for(:insufficient_permissions), do: 403
  defp http_status_for(:rate_limited), do: 429
  # A server fault is 5xx on the wire, not 400: intermediaries, retry
  # policies and alerting read the status, not the JSON-RPC body, and a
  # store outage disguised as Bad Request never trips a 5xx alarm.
  defp http_status_for(:internal_error), do: 500
  defp http_status_for(:unavailable), do: 503
  defp http_status_for(:timeout), do: 504
  defp http_status_for(code) when code in [:internal, :corrupt, :uncertain], do: 500
  defp http_status_for(_code), do: 400

  defp extract_tool(%{"method" => "tools/call", "params" => %{"name" => name}}), do: name
  defp extract_tool(%{"method" => "resources/read"}), do: "resources"
  defp extract_tool(_), do: nil

  defp extract_action(%{"params" => %{"arguments" => %{"action" => action}}}), do: action
  defp extract_action(_), do: nil

  defp emit_telemetry(start_time, %Sanctum.Context{} = context, metadata) do
    duration = System.monotonic_time() - start_time
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    # Carry the athanor so the host's bridge (`Cyfr.TelemetryBridge`) routes
    # the message to this athanor's dashboard subscribers.
    metadata = Map.put(metadata, :athanor_id, context.athanor_id)

    :telemetry.execute(
      [:cyfr, :emissary, :request],
      %{duration: duration, duration_ms: duration_ms},
      metadata
    )
  end
end
