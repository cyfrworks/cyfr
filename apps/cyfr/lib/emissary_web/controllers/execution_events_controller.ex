# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.ExecutionEventsController do
  @moduledoc """
  SSE endpoint for streaming execution events.

  `GET /api/executions/:id/events` — subscribes to PubSub for the given
  execution, replays buffered events on connect, and streams SSE until
  a terminal event (`complete` or `error`) is received.

  Supports reconnection via the `Last-Event-ID` header (replays from
  the given sequence number).
  """

  @compile {:no_warn_undefined, [Opus]}

  use EmissaryWeb, :controller

  @keep_alive_interval_ms 15_000

  def stream(conn, %{"id" => execution_id}) do
    cond do
      not Code.ensure_loaded?(Opus) ->
        conn
        |> put_status(503)
        |> json(%{"error" => "Execution event streaming unavailable (Opus not loaded)"})

      true ->
        ctx = conn.assigns[:context]

        with {:auth, %Sanctum.Context{authenticated: true} = ctx} <- {:auth, ctx},
             {:exec, %Arca.Execution{} = exec} <-
               {:exec, Arca.Execution.get_tenant(ctx, execution_id)},
             :ok <- authorize_execution_read(ctx, exec),
             :ok <- claim_stream_slot(ctx) do
          last_seq = parse_last_event_id(conn)

          conn
          |> put_resp_header("content-type", "text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          |> put_resp_header("x-accel-buffering", "no")
          |> send_chunked(200)
          |> stream_events(execution_id, last_seq, exec)
        else
          {:auth, _} ->
            EmissaryWeb.ApiError.send(conn, 401, :auth_required, "Authentication required")

          # Non-existent and not-yours both return 404 to avoid leaking which
          # execution IDs exist in the system via 403/404 distinction.
          {:exec, nil} ->
            EmissaryWeb.ApiError.send(conn, 404, :not_found, "Execution not found")

          {:error, :forbidden} ->
            EmissaryWeb.ApiError.send(conn, 404, :not_found, "Execution not found")

          {:error, :stream_limit} ->
            EmissaryWeb.ApiError.send(
              conn,
              429,
              :too_many_streams,
              "Concurrent event-stream limit reached"
            )
        end
    end
  end

  # Same leash as `subscriptions/listen`: a per-user cap on concurrent
  # streams and a hard deadline on each. The slot is a SubscriptionRegistry
  # entry under a TAGGED key with its own budget — sharing the listen key
  # would let one surface starve the other. Registry entries die with this
  # process, so a vanished client frees its slot without bookkeeping.
  defp claim_stream_slot(ctx) do
    key = {:exec_events, ctx.org_id, ctx.user_id}
    limit = Application.get_env(:cyfr, :execution_events_max_concurrent, 8)

    if length(Registry.lookup(Emissary.MCP.SubscriptionRegistry, key)) >= limit do
      {:error, :stream_limit}
    else
      {:ok, _} = Registry.register(Emissary.MCP.SubscriptionRegistry, key, :stream)
      :ok
    end
  end

  defp max_stream_ms,
    do: Application.get_env(:cyfr, :execution_events_max_ms, :timer.minutes(30))

  # Single authorization chokepoint: `Sanctum.Context.authorize/3` with the
  # `{:execution, record}` resource performs require_permission(:storage_read)
  # + per-record verify_tenant + owner/admin/wildcard — replacing the former
  # hand-rolled owner-or-admin check (which skipped the permission and tenant
  # checks). The chokepoint returns `{:error, String.t()}`; collapse it to the
  # controller's `:forbidden` so both not-found and not-authorized stay 404
  # (no execution-id existence disclosure).
  defp authorize_execution_read(%Sanctum.Context{} = ctx, %Arca.Execution{} = exec) do
    case Sanctum.Context.authorize(ctx, :storage_read, {:execution, exec}) do
      :ok -> :ok
      {:error, _reason} -> {:error, :forbidden}
    end
  end

  # Subscribe and replay with the RECORD's tenant coordinates, not the
  # viewer's context: producers publish/buffer under the execution's own
  # org/project, and an org- or platform-scoped viewer may carry different
  # coordinates than the record it was authorized to read.
  defp stream_events(conn, execution_id, last_seq, exec) do
    Opus.subscribe_events(execution_id, exec)

    # Replay buffered events since last_seq
    buffered = Opus.events_since(execution_id, last_seq, exec.org_id)

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
      Opus.unsubscribe_events(execution_id, exec)
      conn
    else
      deadline = System.monotonic_time(:millisecond) + max_stream_ms()
      event_loop(conn, execution_id, exec, deadline)
    end
  end

  # `exec` rides along so unsubscribe targets the SAME tenant-scoped topic
  # subscribe used — dropping it resolves to the local/default sentinel and
  # silently leaves the process subscribed for any other org. The deadline
  # bounds a stream whose execution never reaches a terminal event — the
  # client reconnects with Last-Event-ID and misses nothing.
  defp event_loop(conn, execution_id, exec, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      Opus.unsubscribe_events(execution_id, exec)
      conn
    else
      receive do
        {:execution_event, event} ->
          case send_sse_event(conn, event) do
            {:ok, conn} ->
              if terminal_event?(event) do
                Opus.unsubscribe_events(execution_id, exec)
                conn
              else
                event_loop(conn, execution_id, exec, deadline)
              end

            {:error, _} ->
              Opus.unsubscribe_events(execution_id, exec)
              conn
          end
      after
        @keep_alive_interval_ms ->
          case chunk(conn, ": keep-alive\n\n") do
            {:ok, conn} ->
              event_loop(conn, execution_id, exec, deadline)

            {:error, _} ->
              Opus.unsubscribe_events(execution_id, exec)
              conn
          end
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
