defmodule Opus.ExecutionEventBuffer do
  @moduledoc """
  Thin event buffer for formula execution streaming.

  Broadcasts events via PubSub and maintains a short-lived replay buffer
  in Arca.Cache so that late-joining SSE clients can catch up.

  Uses a per-execution GenServer to serialize buffer writes, preventing the
  race condition where concurrent events could be lost in a non-atomic
  read-modify-write cycle.

  ## Usage

      # Formula host function pushes events:
      Opus.ExecutionEventBuffer.push(execution_id, data, sequence)

      # Executor pushes terminal events:
      Opus.ExecutionEventBuffer.push_terminal(execution_id, "complete", data, seq)

      # SSE controller replays on connect:
      events = Opus.ExecutionEventBuffer.since(execution_id, last_sequence)

      # Subscribe/unsubscribe to live events:
      Opus.ExecutionEventBuffer.subscribe(execution_id)
      Opus.ExecutionEventBuffer.unsubscribe(execution_id)
  """

  use GenServer

  @max_events 50
  @buffer_ttl_ms :timer.minutes(10)
  @idle_timeout :timer.minutes(2)

  defp pubsub, do: Application.get_env(:cyfr, :pubsub, Emissary.PubSub)

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Push an intermediate event from a formula's `emit` host function.
  """
  def push(execution_id, data, sequence, ctx \\ nil) do
    event = %{
      type: "emit",
      execution_id: execution_id,
      sequence: sequence,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: data
    }

    Phoenix.PubSub.broadcast(pubsub(), topic(execution_id, ctx), {:execution_event, event})
    buffer_event(execution_id, event)
    :ok
  end

  @doc """
  Push a terminal event (complete/error) from the Executor.
  """
  def push_terminal(execution_id, type, data, sequence, ctx \\ nil) do
    event = %{
      type: type,
      execution_id: execution_id,
      sequence: sequence,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: data
    }

    Phoenix.PubSub.broadcast(pubsub(), topic(execution_id, ctx), {:execution_event, event})
    buffer_event(execution_id, event)
    :ok
  end

  @doc """
  Flush pending buffer writes for a given execution. Forces all prior casts
  to be processed before returning. For test use.
  """
  def flush(execution_id) do
    case Registry.lookup(Opus.ExecutionEventBuffer.Registry, execution_id) do
      [{pid, _}] -> GenServer.call(pid, :flush)
      [] -> :ok
    end
  rescue
    _e in [ArgumentError, RuntimeError] -> :ok
  end

  @doc """
  Retrieve buffered events with sequence > `last_sequence`.
  Used for SSE reconnection replay.
  """
  def since(execution_id, last_sequence) do
    case Arca.Cache.get({:exec_events, execution_id}) do
      {:ok, events} -> Enum.filter(events, fn e -> e.sequence > last_sequence end)
      :miss -> []
    end
  end

  @doc """
  Subscribe the calling process to live events for an execution.
  """
  def subscribe(execution_id, ctx \\ nil) do
    Phoenix.PubSub.subscribe(pubsub(), topic(execution_id, ctx))
  end

  @doc """
  Unsubscribe the calling process from execution events.
  """
  def unsubscribe(execution_id, ctx \\ nil) do
    Phoenix.PubSub.unsubscribe(pubsub(), topic(execution_id, ctx))
  end

  @doc """
  PubSub topic for a given execution, scoped by tenant context.
  """
  def topic(execution_id, ctx \\ nil) do
    Sanctum.PubSub.topic("execution:events:#{execution_id}", ctx)
  end

  # ============================================================================
  # GenServer - Per-execution buffer serialization
  # ============================================================================

  def start_link(execution_id) do
    GenServer.start_link(__MODULE__, execution_id, name: via(execution_id))
  end

  defp via(execution_id) do
    {:via, Registry, {Opus.ExecutionEventBuffer.Registry, execution_id}}
  end

  @impl true
  def init(execution_id) do
    Process.flag(:trap_exit, true)
    {:ok, %{execution_id: execution_id, events: []}, @idle_timeout}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {:reply, :ok, state, @idle_timeout}
  end

  @impl true
  def handle_cast({:buffer, event}, state) do
    events = (state.events ++ [event]) |> Enum.take(-@max_events)
    Arca.Cache.put({:exec_events, state.execution_id}, events, @buffer_ttl_ms)
    {:noreply, %{state | events: events}, @idle_timeout}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.events != [] do
      Arca.Cache.put({:exec_events, state.execution_id}, state.events, @buffer_ttl_ms)
    end

    :ok
  end

  # ============================================================================
  # Private
  # ============================================================================

  # Route buffer writes through a per-execution GenServer to serialize them.
  # Falls back to direct cache write if the GenServer can't be started
  # (e.g., Registry not available in tests).
  defp buffer_event(execution_id, event) do
    case ensure_buffer(execution_id) do
      {:ok, pid} ->
        GenServer.cast(pid, {:buffer, event})

      :error ->
        # Fallback: direct write (non-atomic but functional)
        buffer_event_direct(execution_id, event)
    end
  end

  defp ensure_buffer(execution_id) do
    case Registry.lookup(Opus.ExecutionEventBuffer.Registry, execution_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               Opus.ExecutionEventBuffer.Supervisor,
               {__MODULE__, execution_id}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          _ -> :error
        end
    end
  rescue
    # Registry/Supervisor not started (e.g., in tests)
    _e in [ArgumentError, RuntimeError] -> :error
  end

  # Direct fallback for when GenServer infrastructure isn't available
  defp buffer_event_direct(execution_id, event) do
    key = {:exec_events, execution_id}

    events =
      case Arca.Cache.get(key) do
        {:ok, existing} -> existing
        :miss -> []
      end

    Arca.Cache.put(key, (events ++ [event]) |> Enum.take(-@max_events), @buffer_ttl_ms)
  end
end
