# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Events do
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

  alias Cyfr.Execution.Events.Sequence

  @max_events 50
  @buffer_ttl_ms :timer.minutes(10)
  @idle_timeout :timer.minutes(2)

  @terminal Arca.ExecutionEvents.terminal_types()

  @doc "Whether an event ends the stream it is on."
  @spec terminal?(map()) :: boolean()
  def terminal?(%{type: type}), do: type in @terminal
  def terminal?(_), do: false

  # Use the application's supervised PubSub instance.
  defp pubsub, do: Emissary.PubSub

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Publish a durable event after its row committed: `seq` is the row's
  number (`executions.event_seq` at the write), `ctx` anything carrying
  the owning `athanor_id` — the execution record itself at a terminal
  site. A terminal type retires the stream's delta counters.
  """
  @spec publish(String.t(), term(), String.t(), non_neg_integer(), map() | nil) ::
          :ok | {:error, :missing_athanor}
  def publish(execution_id, ctx, type, seq, data) when is_binary(type) and is_integer(seq) do
    event = %{
      type: type,
      execution_id: execution_id,
      sequence: Integer.to_string(seq),
      durable: seq,
      delta: nil,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: data || %{},
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

  `opts`: `:origin` — `"guest"` (with `:node`, the emitting component)
  for guest-authored events on the authority path, `"host"` for events
  the host itself emits. Every producer stamps one; a consumer must
  still treat an origin-less event as untrusted.
  """
  @spec push(String.t(), map(), term(), keyword()) ::
          {:ok, String.t()} | {:error, :missing_athanor}
  def push(execution_id, data, ctx, opts \\ []) do
    case extract_athanor_id(ctx) do
      {:ok, athanor_id} ->
        {durable, n} = next_delta(execution_id, athanor_id)

        event =
          %{
            type: "emit",
            execution_id: execution_id,
            sequence: "#{durable}.#{n}",
            durable: durable,
            delta: n,
            timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
            data: data
          }
          |> put_provenance(opts)

        buffer_event(execution_id, athanor_id, event)
        broadcast(execution_id, athanor_id, event)
        {:ok, event.sequence}

      :error ->
        dropped(execution_id, "emit")
    end
  end

  # The durable prefix and the delta number: from the buffer process when
  # it answers, else from the row and the counter table directly.
  defp next_delta(execution_id, athanor_id) do
    case ensure_buffer(execution_id, athanor_id) do
      {:ok, pid} ->
        try do
          GenServer.call(pid, :next_delta)
        catch
          :exit, _ -> next_delta_direct(execution_id, athanor_id)
        end

      :error ->
        next_delta_direct(execution_id, athanor_id)
    end
  end

  defp next_delta_direct(execution_id, athanor_id) do
    durable = durable_seq(execution_id, athanor_id)
    {durable, Sequence.next(execution_id, durable)}
  end

  defp durable_seq(execution_id, athanor_id) do
    case Arca.Execution.event_seq(athanor_id, execution_id) do
      {:ok, seq} when is_integer(seq) -> seq
      _ -> 0
    end
  end

  defp put_provenance(event, opts) do
    case Keyword.get(opts, :origin) do
      nil -> event
      origin -> event |> Map.put(:origin, origin) |> maybe_put_node(opts)
    end
  end

  defp maybe_put_node(event, opts) do
    case Keyword.get(opts, :node) do
      nil -> event
      node -> Map.put(event, :node, node)
    end
  end

  # Write to the athanor's buffer synchronously before broadcasting.
  # Drop and log events without an athanor; never use a default tenant.
  defp deliver(execution_id, ctx, event) do
    case extract_athanor_id(ctx) do
      {:ok, athanor_id} ->
        buffer_event(execution_id, athanor_id, event)
        broadcast(execution_id, athanor_id, event)
        :ok

      :error ->
        dropped(execution_id, event.type)
    end
  end

  defp dropped(execution_id, type) do
    Logger.error(
      "[Cyfr.Execution.Events] dropping #{type} event for #{execution_id}: " <>
        "producer carries no athanor_id"
    )

    :telemetry.execute([:cyfr, :opus, :execution_events, :broadcast_failure], %{count: 1}, %{
      execution_id: execution_id,
      type: type,
      reason: :missing_athanor
    })

    {:error, :missing_athanor}
  end

  defp broadcast(execution_id, athanor_id, event) do
    topic = Cyfr.Bus.execution_events(execution_id, athanor_id)

    case Phoenix.PubSub.broadcast(pubsub(), topic, {:execution_event, event}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[Cyfr.Execution.Events] PubSub broadcast failed for #{execution_id}: #{inspect(reason)}"
        )

        :telemetry.execute([:cyfr, :opus, :execution_events, :broadcast_failure], %{count: 1}, %{
          execution_id: execution_id,
          type: event.type
        })
    end
  end

  @doc """
  Flush pending buffer writes for a given execution. Buffer writes are
  synchronous calls, so this is a round-trip that proves the queue is
  drained; kept for test use.
  """
  def flush(execution_id) do
    case Registry.lookup(Cyfr.Execution.Events.Registry, execution_id) do
      [{pid, _}] -> GenServer.call(pid, :flush)
      [] -> :ok
    end
  rescue
    _e in [ArgumentError, RuntimeError] -> :ok
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
      case Arca.ExecutionEvents.since(athanor_id, execution_id, durable) do
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

  def since(execution_id, _cursor, athanor_id) do
    raise ArgumentError,
          "Cyfr.Execution.Events.since/3: a resolved athanor_id is required " <>
            "for #{execution_id}, got #{inspect(athanor_id)}"
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
    case Arca.Cache.get(Arca.Cache.Keys.exec_events(execution_id, athanor_id)) do
      {:ok, events} -> events
      :miss -> []
    end
  end

  @doc """
  Subscribe the calling process to live events for an execution of the
  context's athanor.
  """
  def subscribe(execution_id, ctx) do
    Phoenix.PubSub.subscribe(pubsub(), topic(execution_id, ctx))
  end

  @doc "Unsubscribe the calling process from execution events."
  def unsubscribe(execution_id, ctx) do
    Phoenix.PubSub.unsubscribe(pubsub(), topic(execution_id, ctx))
  end

  @doc """
  PubSub topic for a given execution, scoped by the owning athanor.

  `ctx` may be a full `Sanctum.Context` or anything carrying `:athanor_id`
  (an `Arca.Execution` record — the natural source at terminal-event sites).
  A caller without a resolved athanor raises: there is no default tenant to
  route to.
  """
  def topic(execution_id, ctx) do
    case extract_athanor_id(ctx) do
      {:ok, athanor_id} ->
        Cyfr.Bus.execution_events(execution_id, athanor_id)

      :error ->
        raise ArgumentError,
              "Cyfr.Execution.Events.topic/2: a resolved athanor_id is required " <>
                "for #{execution_id}, got #{inspect(ctx)}"
    end
  end

  # ============================================================================
  # GenServer - Per-execution buffer serialization
  # ============================================================================

  def start_link({execution_id, athanor_id}) do
    GenServer.start_link(__MODULE__, {execution_id, athanor_id}, name: via(execution_id))
  end

  defp via(execution_id) do
    {:via, Registry, {Cyfr.Execution.Events.Registry, execution_id}}
  end

  @impl true
  def init({execution_id, athanor_id}) do
    Process.flag(:trap_exit, true)

    # Restore cached events after an idle restart so reconnecting clients
    # retain their replay window, and the durable prefix the stream is at:
    # the row's counter, or what the cache saw last.
    events =
      case Arca.Cache.get(Arca.Cache.Keys.exec_events(execution_id, athanor_id)) do
        {:ok, cached} when is_list(cached) -> cached
        _ -> []
      end

    cached_durable = events |> Enum.map(&Map.get(&1, :durable, 0)) |> Enum.max(fn -> 0 end)
    last_durable = max(cached_durable, durable_seq(execution_id, athanor_id))

    # If the counter table restarted while the cache survived, a fresh
    # counter would re-number under deltas already in the replay window.
    # Floor the prefix the cache last numbered to its highest delta.
    max_delta =
      events
      |> Enum.filter(&(Map.get(&1, :durable) == last_durable and Map.get(&1, :delta)))
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
  def handle_call(:flush, _from, state) do
    {:reply, :ok, state, @idle_timeout}
  end

  def handle_call(:next_delta, _from, state) do
    durable = state.last_durable
    {:reply, {durable, Sequence.next(state.execution_id, durable)}, state, @idle_timeout}
  end

  # A call, not a cast: the producer broadcasts only after this returns, so
  # the replay buffer can never lag the live stream. The emit path is
  # rate-limited; the round-trip is fine.
  def handle_call({:buffer, event}, _from, state) do
    events = (state.events ++ [event]) |> Enum.take(-@max_events)

    Arca.Cache.put(
      Arca.Cache.Keys.exec_events(state.execution_id, state.athanor_id),
      events,
      @buffer_ttl_ms
    )

    last_durable =
      case event do
        %{delta: nil, durable: seq} when is_integer(seq) -> max(state.last_durable, seq)
        _ -> state.last_durable
      end

    {:reply, :ok, %{state | events: events, last_durable: last_durable}, @idle_timeout}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state, @idle_timeout}
  end

  @impl true
  def terminate(_reason, state) do
    # Preserve the replay window across an idle shutdown: replay entries and
    # executions may outlive this process. Merge with (never clobber)
    # anything the direct-write fallback put in the cache while this
    # process existed — a wholesale put would erase those events. Order
    # can interleave; losing events cannot.
    if state.events != [] do
      key = Arca.Cache.Keys.exec_events(state.execution_id, state.athanor_id)

      cached =
        case Arca.Cache.get(key) do
          {:ok, existing} when is_list(existing) -> existing
          _ -> []
        end

      merged = Enum.uniq(cached ++ state.events) |> Enum.take(-@max_events)
      Arca.Cache.put(key, merged, @buffer_ttl_ms)
    end

    :ok
  end

  # ============================================================================
  # Private
  # ============================================================================

  # Route buffer writes through a per-execution GenServer to serialize them.
  # Synchronous: the caller broadcasts only after the write landed. Falls
  # back to a direct cache write if the GenServer can't be started (e.g.,
  # Registry not available in tests) or dies between lookup and call —
  # non-atomic, but the event is never lost.
  defp buffer_event(execution_id, athanor_id, event) do
    case ensure_buffer(execution_id, athanor_id) do
      {:ok, pid} ->
        try do
          GenServer.call(pid, {:buffer, event})
        catch
          :exit, _reason -> buffer_event_direct(execution_id, athanor_id, event)
        end

      :error ->
        buffer_event_direct(execution_id, athanor_id, event)
    end
  end

  defp ensure_buffer(execution_id, athanor_id) do
    case Registry.lookup(Cyfr.Execution.Events.Registry, execution_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               Cyfr.Execution.Events.Supervisor,
               {__MODULE__, {execution_id, athanor_id}}
             ) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          {:error, reason} ->
            # Not the "infrastructure absent" case — the supervisor is up
            # and refused. Log it: the direct-write fallback masks the
            # failure otherwise.
            Logger.warning(
              "#{__MODULE__}: start_child failed for #{execution_id}: #{inspect(reason)}"
            )

            :error
        end
    end
  rescue
    # Registry/Supervisor not started (e.g., in tests)
    _e in [ArgumentError, RuntimeError] -> :error
  end

  # Direct fallback for when GenServer infrastructure isn't available
  defp buffer_event_direct(execution_id, athanor_id, event) do
    key = Arca.Cache.Keys.exec_events(execution_id, athanor_id)

    events =
      case Arca.Cache.get(key) do
        {:ok, existing} -> existing
        :miss -> []
      end

    Arca.Cache.put(key, (events ++ [event]) |> Enum.take(-@max_events), @buffer_ttl_ms)
  end

  defp extract_athanor_id(%{athanor_id: athanor_id})
       when is_binary(athanor_id) and athanor_id != "",
       do: {:ok, athanor_id}

  defp extract_athanor_id(_), do: :error
end
