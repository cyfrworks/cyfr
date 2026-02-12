defmodule EmissaryWeb.SSEController do
  @moduledoc """
  SSE (Server-Sent Events) controller for MCP server→client notifications.

  Implements `GET /mcp/sse` per MCP 2025-11-25 specification.

  ## Usage

  1. Client initializes session via `POST /mcp` (gets `Mcp-Session-Id` header)
  2. Client opens SSE stream via `GET /mcp/sse` with `Mcp-Session-Id` header
  3. Server sends events as they occur
  4. Client can resume via `Last-Event-ID` header after reconnection

  ## Event Format

  ```
  id: <event-id>
  event: message
  data: {"jsonrpc":"2.0","method":"notifications/...","params":{...}}

  ```

  ## Headers

  Request:
  - `Mcp-Session-Id: <session-id>` (required)
  - `Last-Event-ID: <event-id>` (optional, for resumption)
  - `Accept: text/event-stream`

  Response:
  - `Content-Type: text/event-stream`
  - `Cache-Control: no-cache`
  - `Connection: keep-alive`

  """

  use EmissaryWeb, :controller

  alias Emissary.MCP.{Session, SSEBuffer}

  @keep_alive_interval_ms 15_000

  @doc """
  Open an SSE stream for the given session.

  Requires a valid session (established via POST /mcp initialize).
  """
  def stream(conn, _params) do
    case conn.assigns[:mcp_session] do
      nil ->
        conn
        |> put_status(400)
        |> json(%{
          "error" => "Session required. Initialize via POST /mcp first.",
          "code" => -32600
        })

      session ->
        # Check for Last-Event-ID for resumption
        last_event_id = get_req_header(conn, "last-event-id") |> List.first()

        conn
        |> put_resp_header("content-type", "text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("connection", "keep-alive")
        |> put_resp_header("x-accel-buffering", "no")  # Disable nginx buffering
        |> send_chunked(200)
        |> stream_events(session, last_event_id)
    end
  end

  defp stream_events(conn, session, last_event_id) do
    # Subscribe to real-time events
    SSEBuffer.subscribe(session.id)

    # Send any buffered events since last_event_id (for resumption)
    conn =
      if last_event_id do
        {:ok, events} = SSEBuffer.since(session.id, last_event_id)

        Enum.reduce_while(events, conn, fn event, acc_conn ->
          case send_sse_event(acc_conn, event) do
            {:ok, new_conn} -> {:cont, new_conn}
            {:error, _reason} -> {:halt, acc_conn}
          end
        end)
      else
        conn
      end

    # Enter the event loop
    event_loop(conn, session.id)
  end

  defp event_loop(conn, session_id) do
    receive do
      {:sse_event, event} ->
        case send_sse_event(conn, event) do
          {:ok, conn} ->
            event_loop(conn, session_id)

          {:error, _reason} ->
            # Client disconnected
            SSEBuffer.unsubscribe(session_id)
            conn
        end

    after
      @keep_alive_interval_ms ->
        # Send keep-alive comment to prevent connection timeout
        case chunk(conn, ": keep-alive\n\n") do
          {:ok, conn} ->
            # Check if session still exists
            if Session.exists?(session_id) do
              event_loop(conn, session_id)
            else
              # Session expired, close connection
              SSEBuffer.unsubscribe(session_id)
              conn
            end

          {:error, _reason} ->
            # Client disconnected
            SSEBuffer.unsubscribe(session_id)
            conn
        end
    end
  end

  defp send_sse_event(conn, event) do
    data = Jason.encode!(event.data)

    sse_message = """
    id: #{event.id}
    event: message
    data: #{data}

    """

    chunk(conn, sse_message)
  end
end
