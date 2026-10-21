# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Events do
  @moduledoc """
  An execution's event stream: what is published to its subscribers,
  and the short-lived replay window a late client catches up from.

  Two kinds of event ride one stream. A durable event is a row of
  `execution_events` — the lifecycle (`execution.started`, `.completed`,
  `.failed`, `.cancelled`, `.lapsed`, `.result_lost`) and a turn's own
  rows — numbered by the execution's counter; `publish/5` broadcasts it
  after its transaction committed, so seq order is commit order. A delta
  (`emit`, the events a guest streams while it runs) never takes a
  durable number: `push/4` numbers it `<durable>.<n>` under the last
  durable event the stream saw, and it is never replayed after a restart.

  `since/3` is the replay a client resumes from: the durable rows after
  its cursor in order, each followed by the deltas still buffered under
  it. Cache keys and topics are scoped by the owning
  athanor; a producer without a resolved athanor has nowhere to route
  to and its event is dropped, loudly.
  """

  # Restart on crashes, but allow normal idle-timeout exits to reap the buffer.
  use GenServer, restart: :transient

  require Logger

  alias Cyfr.Bus.ExecutionEvent
  alias Opus.Events.Sequence

  @max_events 50
  @buffer_ttl_ms :timer.minutes(10)
  @idle_timeout :timer.minutes(2)

  @terminal Arca.ExecutionEvents.terminal_types()

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Publish a durable event after its row committed: `seq` is the row's
  number (`executions.event_seq` at the write), `ctx` anything carrying
  the owning `athanor_id` — the execution record itself at a terminal
  site. A terminal type retires the stream's delta counters.
  """
  @spec publish(String.t(), term(), String.t(), non_neg_integer(), map()) ::
          :ok | {:error, :missing_athanor}
  def publish(execution_id, ctx, type, seq, data)
      when is_binary(type) and is_integer(seq) and is_map(data) do
    event = %{
      type: type,
      execution_id: execution_id,
      sequence: Integer.to_string(seq),
      durable: seq,
      delta: nil,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: data,
      origin: "host"
    }

    result = deliver(execution_id, ctx, event)
    if type in @terminal, do: Sequence.forget(execution_id)
    result
  end

  @doc """
  Push a delta — an intermediate event from a guest's `emit` host
  function, or one the host emits on a guest's behalf. Numbered under
  the last durable event of the stream; answers the id it was given.

  `opts`: `:origin` (required) — `"guest"` (with `:node`, the emitting
  component) for guest-authored events on the authority path, `"host"`
  for events the host itself emits. A consumer still treats an
  origin-less event as untrusted.

  A delta is numbered and buffered by the stream's buffer process before
  it is broadcast. A delta whose buffer cannot be started, or whose
  replay window cannot be written to the cache, is dropped, logged and
  counted, and answers `{:error, :unavailable}`: a delta is never
  broadcast unnumbered or outside the replay window.
  """
  @spec push(String.t(), map(), term(), keyword()) ::
          {:ok, String.t()} | {:error, :missing_athanor | :unavailable}
  def push(execution_id, data, ctx, opts) do
    origin = Keyword.fetch!(opts, :origin)

    with {:ok, athanor_id} <- athanor(execution_id, ctx, "emit"),
         {:ok, {durable, n}} <- call_buffer(execution_id, athanor_id, :next_delta),
         event =
           %{
             type: "emit",
             execution_id: execution_id,
             sequence: "#{durable}.#{n}",
             durable: durable,
             delta: n,
             timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
             data: data,
             origin: origin
           }
           |> maybe_put_node(opts),
         :ok <- call_buffer(execution_id, athanor_id, {:buffer, event}) do
      broadcast(execution_id, athanor_id, event)
      {:ok, event.sequence}
    else
      {:error, :missing_athanor} -> {:error, :missing_athanor}
      {:error, reason} -> unavailable(execution_id, "emit", reason)
    end
  end

  defp athanor(execution_id, ctx, type) do
    case extract_athanor_id(ctx) do
      {:ok, athanor_id} -> {:ok, athanor_id}
      :error -> dropped(execution_id, type)
    end
  end

  defp durable_seq(execution_id, athanor_id) do
    case Arca.Execution.event_seq(Prima.Actor.in_athanor(athanor_id), execution_id) do
      {:ok, seq} when is_integer(seq) -> seq
      _ -> 0
    end
  end

  defp maybe_put_node(event, opts) do
    case Keyword.get(opts, :node) do
      nil -> event
      node -> Map.put(event, :node, node)
    end
  end

  # Write to the athanor's buffer synchronously before broadcasting.
  # Drop and log events without an athanor; never use a default tenant. A
  # durable event's row is its replay (`since/3`), so a buffer that cannot
  # be reached, or a window that cannot be written, is logged and counted
  # and the event is still broadcast.
  defp deliver(execution_id, ctx, event) do
    with {:ok, athanor_id} <- athanor(execution_id, ctx, event.type) do
      case call_buffer(execution_id, athanor_id, {:buffer, event}) do
        :ok -> :ok
        {:error, reason} -> unavailable(execution_id, event.type, reason)
      end

      broadcast(execution_id, athanor_id, event)
      :ok
    end
  end

  defp dropped(execution_id, type) do
    Logger.error(
      "[Opus.Events] dropping #{type} event for #{execution_id}: " <>
        "producer carries no athanor_id"
    )

    :telemetry.execute([:cyfr, :opus, :execution_events, :broadcast_failure], %{count: 1}, %{
      execution_id: execution_id,
      type: type,
      reason: :missing_athanor
    })

    {:error, :missing_athanor}
  end

  defp unavailable(execution_id, type, reason) do
    Logger.error(
      "[Opus.Events] #{type} event for #{execution_id} not buffered: " <>
        "its replay window is unavailable (#{inspect(reason)})"
    )

    :telemetry.execute([:cyfr, :opus, :execution_events, :broadcast_failure], %{count: 1}, %{
      execution_id: execution_id,
      type: type,
      reason: :buffer_unavailable
    })

    {:error, :unavailable}
  end

  # The stream's own map goes on the bus as its struct; a subscriber that
  # needs the stream's fields reads them back with
  # `Cyfr.Bus.ExecutionEvent.event/1`, so live and replayed events agree.
  defp broadcast(execution_id, athanor_id, event) do
    actor = Prima.Actor.in_athanor(athanor_id)
    payload = ExecutionEvent.new(actor, ExecutionEvent.kind(event), event)

    case Cyfr.Bus.broadcast(actor, Cyfr.Bus.execution_events(actor, execution_id), payload) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[Opus.Events] PubSub broadcast failed for #{execution_id}: #{inspect(reason)}"
        )

        :telemetry.execute([:cyfr, :opus, :execution_events, :broadcast_failure], %{count: 1}, %{
          execution_id: execution_id,
          type: event.type
        })
    end
  end

  @doc """
  What a client at `{durable, n}` has yet to see, in order: the buffered
  deltas after `n` under `durable`, then each durable row of the
  execution after `durable` followed by the deltas still buffered under
  it. The athanor is required: the rows and the buffer are keyed by it
  and there is no default to read from.
  """
  @spec since(String.t(), {non_neg_integer(), non_neg_integer()}, String.t()) :: [map()]
  def since(execution_id, {durable, n}, athanor_id)
      when is_binary(athanor_id) and athanor_id != "" and is_integer(durable) and is_integer(n) do
    rows =
      case Arca.ExecutionEvents.since(Prima.Actor.in_athanor(athanor_id), execution_id, durable) do
        {:ok, rows} -> Enum.map(rows, &row_event/1)
        {:error, _} -> []
      end

    deltas =
      execution_id
      |> buffered(athanor_id)
      |> Enum.filter(&(&1.delta != nil))
      |> Enum.group_by(& &1.durable)

    under = fn prefix, after_n ->
      deltas
      |> Map.get(prefix, [])
      |> Enum.filter(&(&1.delta > after_n))
      |> Enum.sort_by(& &1.delta)
    end

    under.(durable, n) ++ Enum.flat_map(rows, fn row -> [row | under.(row.durable, 0)] end)
  end

  def since(_execution_id, _cursor, athanor_id) do
    raise ArgumentError,
          "Opus.Events.since/3: a resolved athanor_id is required, " <>
            "got #{Prima.LoggerContext.shape(athanor_id)}"
  end

  # A durable row as the stream carries it.
  defp row_event(row) do
    %{
      type: row.type,
      execution_id: row.execution_id,
      sequence: Integer.to_string(row.seq),
      durable: row.seq,
      delta: nil,
      timestamp: DateTime.to_iso8601(row.inserted_at),
      data: Arca.ExecutionEvents.data(row),
      origin: "host"
    }
  end

  defp buffered(execution_id, athanor_id) do
    case Arca.Cache.get(
           Arca.Cache.Keys.exec_events(Prima.Actor.in_athanor(athanor_id), execution_id)
         ) do
      {:ok, events} -> events
      :miss -> []
    end
  end

  @doc """
  Subscribe the calling process to live events for an execution of the
  context's athanor.
  """
  def subscribe(execution_id, ctx) do
    actor = actor!(execution_id, ctx)
    Cyfr.Bus.subscribe(actor, Cyfr.Bus.execution_events(actor, execution_id))
  end

  @doc "Unsubscribe the calling process from execution events."
  def unsubscribe(execution_id, ctx) do
    actor = actor!(execution_id, ctx)
    # The topic is the scope's own, so the bus's prefix check always holds.
    _ = Cyfr.Bus.unsubscribe(actor, Cyfr.Bus.execution_events(actor, execution_id))
    :ok
  end

  # The actor of the athanor owning the stream. `ctx` may be a full
  # `Sanctum.Context` or anything carrying `:athanor_id` (an
  # `Arca.Execution` record — the natural source at terminal-event sites).
  # A caller without a resolved athanor raises: there is no default tenant
  # to route to.
  defp actor!(_execution_id, ctx) do
    case extract_athanor_id(ctx) do
      {:ok, athanor_id} ->
        Prima.Actor.in_athanor(athanor_id)

      :error ->
        raise ArgumentError,
              "Opus.Events: a resolved athanor_id is required, " <>
                "got #{Prima.LoggerContext.shape(ctx)}"
    end
  end

  # ============================================================================
  # GenServer - Per-execution buffer serialization
  # ============================================================================

  def start_link({execution_id, athanor_id}) do
    GenServer.start_link(__MODULE__, {execution_id, athanor_id}, name: via(execution_id))
  end

  defp via(execution_id) do
    {:via, Registry, {Opus.Events.Registry, execution_id}}
  end

  @impl true
  def init({execution_id, athanor_id}) do
    # Restore cached events after an idle restart so reconnecting clients
    # retain their replay window, and the durable prefix the stream is at:
    # the row's counter, or what the cache saw last.
    events =
      case Arca.Cache.get(
             Arca.Cache.Keys.exec_events(Prima.Actor.in_athanor(athanor_id), execution_id)
           ) do
        {:ok, cached} -> cached
        :miss -> []
      end

    cached_durable = events |> Enum.map(& &1.durable) |> Enum.max(fn -> 0 end)
    last_durable = max(cached_durable, durable_seq(execution_id, athanor_id))

    # If the counter table restarted while the cache survived, a fresh
    # counter would re-number under deltas already in the replay window.
    # Floor the prefix the cache last numbered to its highest delta.
    max_delta =
      events
      |> Enum.filter(&(&1.durable == last_durable and &1.delta != nil))
      |> Enum.map(& &1.delta)
      |> Enum.max(fn -> 0 end)

    if max_delta > 0, do: Sequence.reseed(execution_id, last_durable, max_delta)

    {:ok,
     %{
       execution_id: execution_id,
       athanor_id: athanor_id,
       events: events,
       last_durable: last_durable
     }, @idle_timeout}
  end

  @impl true
  def handle_call(:next_delta, _from, state) do
    durable = state.last_durable
    {:reply, {:ok, {durable, Sequence.next(state.execution_id, durable)}}, state, @idle_timeout}
  end

  # A call, not a cast: the producer broadcasts only after this returns, so
  # the replay buffer can never lag the live stream. The emit path is
  # rate-limited; the round-trip is fine.
  #
  # The window holds an event once, by its sequence: a request repeated
  # after the buffer that took it stopped before answering (`call_buffer/4`)
  # finds the event in the window this buffer restored from the cache, and
  # answers it landed. A delta whose window cannot be written stays out of
  # it, refused, so it is neither broadcast nor replayed later. A durable
  # event is kept whatever the cache answers, since its row is its replay
  # and the deltas after it are numbered under it, and its refusal is
  # answered all the same.
  def handle_call({:buffer, %{sequence: sequence} = event}, _from, state) do
    if Enum.any?(state.events, &(&1.sequence == sequence)) do
      {:reply, :ok, state, @idle_timeout}
    else
      events = (state.events ++ [event]) |> Enum.take(-@max_events)

      case {write(state, events), event} do
        {:ok, _event} -> {:reply, :ok, took(state, events, event), @idle_timeout}
        {refused, %{delta: nil}} -> {:reply, refused, took(state, events, event), @idle_timeout}
        {refused, _delta} -> {:reply, refused, state, @idle_timeout}
      end
    end
  end

  defp write(state, events) do
    Arca.Cache.put(
      Arca.Cache.Keys.exec_events(Prima.Actor.in_athanor(state.athanor_id), state.execution_id),
      events,
      @buffer_ttl_ms
    )
  end

  defp took(state, events, %{delta: nil, durable: seq}),
    do: %{state | events: events, last_durable: max(state.last_durable, seq)}

  defp took(state, events, _delta), do: %{state | events: events}

  @impl true
  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state, @idle_timeout}
  end

  # ============================================================================
  # Private
  # ============================================================================

  # Every buffer read and write goes through the stream's own process, which
  # serializes them. Synchronous: the caller broadcasts only after the write
  # landed. Answers the buffer's own reply. A buffer that stops between the
  # lookup and the call, or before it answers the call, exits the call; the
  # next attempt finds the name free (a dead registration resolves to
  # nothing) and starts a fresh buffer, which restores the window from the
  # cache. A repeated write lands once, the window holding an event once by
  # its sequence; a repeated numbering takes the next number, leaving the
  # one the stopped buffer took unused. A call that timed out may still be
  # in the buffer's queue, so it is not repeated.
  @buffer_attempts 3

  defp call_buffer(execution_id, athanor_id, request, attempt \\ 1) do
    case ensure_buffer(execution_id, athanor_id) do
      {:ok, pid} ->
        try do
          GenServer.call(pid, request)
        catch
          :exit, {:timeout, _} = reason ->
            {:error, {:exit, reason}}

          :exit, reason when attempt >= @buffer_attempts ->
            {:error, {:exit, reason}}

          :exit, _gone ->
            call_buffer(execution_id, athanor_id, request, attempt + 1)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_buffer(execution_id, athanor_id) do
    case GenServer.whereis(via(execution_id)) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        case DynamicSupervisor.start_child(
               Opus.Events.Supervisor,
               {__MODULE__, {execution_id, athanor_id}}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, {:start_failed, reason}}
        end
    end
  end

  defp extract_athanor_id(%{athanor_id: athanor_id})
       when is_binary(athanor_id) and athanor_id != "",
       do: {:ok, athanor_id}

  defp extract_athanor_id(_), do: :error
end
