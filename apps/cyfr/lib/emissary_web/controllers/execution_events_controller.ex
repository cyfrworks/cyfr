defmodule EmissaryWeb.ExecutionEventsController do
  @moduledoc """
  SSE endpoint for streaming execution events.

  `GET /api/executions/:id/events` — subscribes to PubSub for the given
  execution, replays buffered events on connect, and streams SSE until
  a terminal event (`complete` or `error`) is received.

  Supports reconnection via the `Last-Event-ID` header (replays from
  the given sequence number).
  """

  @compile {:no_warn_undefined, [Opus.ExecutionEventBuffer]}

  use EmissaryWeb, :controller

  @keep_alive_interval_ms 15_000

  def stream(conn, %{"id" => execution_id}) do
    if Code.ensure_loaded?(Opus.ExecutionEventBuffer) do
      last_seq = parse_last_event_id(conn)
      ctx = conn.assigns[:mcp_context]
      org_id = (ctx && ctx.org_id) || ""

      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)
      |> stream_events(execution_id, last_seq, org_id)
    else
      conn
      |> put_status(503)
      |> json(%{"error" => "Execution event streaming unavailable (Opus not loaded)"})
    end
  end

  defp stream_events(conn, execution_id, last_seq, org_id) do
    Opus.ExecutionEventBuffer.subscribe(execution_id)

    # Replay buffered events since last_seq
    buffered = Opus.ExecutionEventBuffer.since(execution_id, last_seq, org_id)

    {conn, terminal?} =
      Enum.reduce_while(buffered, {conn, false}, fn event, {acc_conn, _} ->
        case send_sse_event(acc_conn, event) do
          {:ok, new_conn} ->
            if terminal_event?(event),
              do: {:halt, {new_conn, true}},
              else: {:cont, {new_conn, false}}

          {:error, _} ->
            {:halt, {acc_conn, true}}
        end
      end)

    if terminal? do
      Opus.ExecutionEventBuffer.unsubscribe(execution_id)
      conn
    else
      event_loop(conn, execution_id)
    end
  end

  defp event_loop(conn, execution_id) do
    receive do
      {:execution_event, event} ->
        case send_sse_event(conn, event) do
          {:ok, conn} ->
            if terminal_event?(event) do
              Opus.ExecutionEventBuffer.unsubscribe(execution_id)
              conn
            else
              event_loop(conn, execution_id)
            end

          {:error, _} ->
            Opus.ExecutionEventBuffer.unsubscribe(execution_id)
            conn
        end
    after
      @keep_alive_interval_ms ->
        case chunk(conn, ": keep-alive\n\n") do
          {:ok, conn} ->
            event_loop(conn, execution_id)

          {:error, _} ->
            Opus.ExecutionEventBuffer.unsubscribe(execution_id)
            conn
        end
    end
  end

  defp terminal_event?(%{type: type}) when type in ["complete", "error"], do: true
  defp terminal_event?(_), do: false

  defp send_sse_event(conn, event) do
    data =
      case Jason.encode(event.data) do
        {:ok, encoded} -> encoded
        {:error, _} -> ~s({"error":"Event data not serializable"})
      end

    sse_message = "id: #{event.sequence}\nevent: #{event.type}\ndata: #{data}\n\n"
    chunk(conn, sse_message)
  end

  defp parse_last_event_id(conn) do
    case get_req_header(conn, "last-event-id") do
      [val | _] ->
        case Integer.parse(val) do
          {n, _} -> n
          :error -> 0
        end

      [] ->
        0
    end
  end
end
