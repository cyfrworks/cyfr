# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.ExecutionEventsController do
  @moduledoc """
  SSE endpoint for streaming execution events.

  `GET /api/executions/:id/events` — subscribes to the execution's
  stream, replays what a client at its cursor has yet to see, and streams
  SSE until a terminal lifecycle event (`execution.completed`, `.failed`,
  `.cancelled`, `.lapsed`, `.result_lost`).

  An event's `id` is its number: a durable row's `<seq>`, a delta's
  `<durable>.<n>`. `Last-Event-ID` resumes from either; the durable rows
  after it are replayed in order, then the deltas still buffered under
  the last of them. Delivery is in commit order whatever order
  publications arrive in: a live event that does not immediately follow
  the cursor is a trigger to read the rows again.

  An open stream holds the caller's standing to the same rule the
  console does (`CyfrWeb.ContextGuard.watch/1`): it revalidates on every
  standing announcement about its caller and at least every thirty
  seconds, and a refusal ends it as the deadline does — the client's
  reconnect is then answered by the authentication plug.
  """

  use EmissaryWeb, :controller

  require CyfrWeb.ContextGuard

  alias CyfrWeb.ContextGuard

  @keep_alive_interval_ms EmissaryWeb.SSE.keep_alive_ms()
  @terminal_types Arca.ExecutionEvents.terminal_types()

  def stream(conn, %{"id" => execution_id}) do
    cond do
      not Crucible.available?() ->
        EmissaryWeb.ApiError.send(
          conn,
          503,
          :execution_unavailable,
          "Execution event streaming unavailable — the engine is starting"
        )

      true ->
        ctx = conn.assigns[:context]

        with {:auth, %Sanctum.Context{authenticated: true} = ctx} <- {:auth, ctx},
             {:exec, %{id: _} = exec} <-
               {:exec, Arca.Execution.get_tenant(Sanctum.Context.actor(ctx), execution_id)},
             :ok <- authorize_execution_read(ctx, exec),
             :ok <- EmissaryWeb.SSE.claim_slot(:sse_slot, ctx, :crucible_events_max_concurrent) do
          cursor = parse_last_event_id(conn)

          conn
          |> EmissaryWeb.SSE.open()
          |> stream_events(ctx, execution_id, cursor, exec)
        else
          {:auth, _} ->
            EmissaryWeb.ApiError.send(conn, 401, :unauthenticated, nil)

          # Non-existent and not-yours both return 404 to avoid leaking which
          # execution IDs exist in the system via 403/404 distinction.
          {:exec, nil} ->
            EmissaryWeb.ApiError.send(conn, 404, :not_found, "Execution not found")

          # The lookup is `with_db_rescue`-wrapped, so a store that cannot
          # answer arrives here rather than raising. It is neither "no such
          # execution" nor "not yours" — saying 404 would tell a caller their
          # execution is gone during a blip — so it answers the same 503 the
          # engine-unavailable branch above does.
          {:exec, {:error, :database_error}} ->
            EmissaryWeb.ApiError.send(conn, 503, :unavailable, "Try again shortly")

          {:error, :forbidden} ->
            EmissaryWeb.ApiError.send(conn, 404, :not_found, "Execution not found")

          {:error, :stream_limit} ->
            EmissaryWeb.ApiError.send(
              conn,
              429,
              :stream_limit,
              "Concurrent event-stream limit reached"
            )
        end
    end
  end

  # Single authorization chokepoint: `Sanctum.Context.authorize/3` with the
  # `{:execution, record}` resource performs require_permission(:storage_read)
  # + per-record verify_tenant + owner/admin/wildcard — replacing the former
  # hand-rolled owner-or-admin check (which skipped the permission and tenant
  # checks). The chokepoint returns `{:error, String.t()}`; collapse it to the
  # controller's `:forbidden` so both not-found and not-authorized stay 404
  # (no execution-id existence disclosure).
  defp authorize_execution_read(%Sanctum.Context{} = ctx, %{id: _} = exec) do
    case Sanctum.Context.authorize(ctx, :storage_read, {:execution, exec}) do
      :ok -> :ok
      {:error, _reason} -> {:error, :forbidden}
    end
  end

  # `exec` rides along so unsubscribe targets the SAME tenant-scoped topic
  # subscribe used, and a platform-scoped viewer may carry a different
  # athanor than the record it was authorized to read. The subscription
  # comes first and the replay once, so replay and live never overlap.
  defp stream_events(conn, ctx, execution_id, cursor, exec) do
    Crucible.subscribe_events(execution_id, exec)
    watch = ContextGuard.watch(ctx)

    case drain(conn, execution_id, exec, cursor) do
      {conn, _cursor, true} ->
        close(conn, execution_id, exec, watch)

      {conn, cursor, false} ->
        deadline = EmissaryWeb.SSE.deadline(:crucible_events_max_ms)
        event_loop(conn, {execution_id, exec, watch}, cursor, deadline)
    end
  end

  defp close(conn, execution_id, exec, watch) do
    Crucible.unsubscribe_events(execution_id, exec)
    ContextGuard.unwatch(watch)
    conn
  end

  # Everything after the cursor, in order: the durable
  # rows first, then the deltas under the last of them. Answers the
  # cursor delivered to, and whether a terminal event ended the stream.
  defp drain(conn, execution_id, exec, cursor) do
    execution_id
    |> Crucible.events_since(cursor, exec.athanor_id)
    |> Enum.reduce_while({conn, cursor, false}, fn event, {acc_conn, acc_cursor, _} ->
      case send_sse_event(acc_conn, event) do
        {:ok, new_conn} ->
          cursor = cursor_after(event, acc_cursor)

          if terminal_event?(event),
            do: {:halt, {new_conn, cursor, true}},
            else: {:cont, {new_conn, cursor, false}}

        {:error, _} ->
          {:halt, {acc_conn, acc_cursor, true}}
      end
    end)
  end

  # A live event is a trigger. The one that immediately follows the
  # cursor goes straight out; anything else means rows the notification
  # overtook, or a prefix this client has not reached, and everything
  # after the cursor is read instead — so delivery is in
  # commit order whatever order publications arrive in, and nothing is
  # sent twice. The deadline bounds a stream whose execution never
  # reaches a terminal event — the client reconnects with Last-Event-ID
  # and misses nothing.
  #
  # The caller's standing is watched the whole time: a standing
  # announcement about them, or the watch's periodic recheck, revalidates,
  # and a refusal ends the stream the way the deadline does.
  defp event_loop(conn, {execution_id, exec, watch} = stream, cursor, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      close(conn, execution_id, exec, watch)
    else
      receive do
        %Cyfr.Bus.ExecutionEvent{} = live ->
          case forward(conn, execution_id, exec, cursor, Cyfr.Bus.ExecutionEvent.event(live)) do
            {conn, _cursor, true} ->
              close(conn, execution_id, exec, watch)

            {conn, cursor, false} ->
              event_loop(conn, stream, cursor, deadline)
          end

        message when ContextGuard.standing_message(message) ->
          case ContextGuard.standing(message, watch) do
            {:ok, watch} -> event_loop(conn, {execution_id, exec, watch}, cursor, deadline)
            {:refused, _reason} -> close(conn, execution_id, exec, watch)
            :ignore -> event_loop(conn, stream, cursor, deadline)
          end
      after
        @keep_alive_interval_ms ->
          case chunk(conn, EmissaryWeb.SSE.keep_alive_comment()) do
            {:ok, conn} ->
              event_loop(conn, stream, cursor, deadline)

            {:error, _} ->
              close(conn, execution_id, exec, watch)
          end
      end
    end
  end

  defp forward(conn, execution_id, exec, {durable, n} = cursor, event) do
    cond do
      # Already delivered: an older prefix, or a delta the replay covered.
      behind?(event, cursor) ->
        {conn, cursor, false}

      # The next durable row, or the next delta under the current prefix.
      next?(event, durable, n) ->
        case send_sse_event(conn, event) do
          {:ok, conn} -> {conn, cursor_after(event, cursor), terminal_event?(event)}
          {:error, _} -> {conn, cursor, true}
        end

      true ->
        drain(conn, execution_id, exec, cursor)
    end
  end

  defp behind?(%{durable: d, delta: nil}, {durable, _n}), do: d <= durable

  defp behind?(%{durable: d, delta: delta}, {durable, n}),
    do: d < durable or (d == durable and delta <= n)

  defp behind?(_event, _cursor), do: false

  defp next?(%{durable: d, delta: nil}, durable, _n), do: d == durable + 1
  defp next?(%{durable: d, delta: delta}, durable, n), do: d == durable and delta == n + 1
  defp next?(_event, _durable, _n), do: false

  defp cursor_after(%{durable: d, delta: nil}, _cursor), do: {d, 0}
  defp cursor_after(%{durable: d, delta: delta}, _cursor), do: {d, delta}
  defp cursor_after(_event, cursor), do: cursor

  defp terminal_event?(%{type: type}), do: type in @terminal_types

  defp send_sse_event(conn, event) do
    data =
      case Jason.encode(event.data) do
        {:ok, encoded} -> encoded
        {:error, _} -> ~s({"error":"Event data not serializable"})
      end

    sse_message = "id: #{event.sequence}\nevent: #{event.type}\ndata: #{data}\n\n"
    chunk(conn, sse_message)
  end

  # `Last-Event-ID` is `<durable>` or `<durable>.<n>`: the last durable
  # event delivered and, under it, the last delta. Anything else resumes
  # from the start.
  defp parse_last_event_id(conn) do
    case get_req_header(conn, "last-event-id") do
      [val | _] -> parse_cursor(val)
      [] -> {0, 0}
    end
  end

  @doc false
  @spec parse_cursor(String.t()) :: {non_neg_integer(), non_neg_integer()}
  def parse_cursor(value) when is_binary(value) do
    case String.split(value, ".", parts: 2) do
      [durable] -> {parse_int(durable), 0}
      [durable, n] -> {parse_int(durable), parse_int(n)}
    end
  end

  defp parse_int(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> n
      _ -> 0
    end
  end
end
