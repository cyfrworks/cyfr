defmodule Emissary.MCP.SSEBuffer do
  @moduledoc """
  Per-session event buffer for SSE resumption.

  Stores recent server-sent events so clients can resume from a specific
  event ID using the `Last-Event-ID` header per MCP 2025-11-25 spec.

  ## Design

  - Storage backed by Arca.Cache with TTL-based expiry
  - GenServer retained only for pub/sub (subscriber tracking + :DOWN monitoring)
  - Events auto-expire via Arca.Cache.Sweeper
  - Thread-safe for concurrent reads/writes

  ## Usage

      # Push an event to a session's buffer
      SSEBuffer.push(session_id, %{type: "notification", data: ...})

      # Get events since a specific ID (for resumption)
      {:ok, events} = SSEBuffer.since(session_id, last_event_id)

      # Get all pending events
      {:ok, events} = SSEBuffer.pending(session_id)

  """

  use GenServer
  require Logger

  @max_events_per_session 100
  # PRD 5.4: "buffers messages for 5 minutes"
  @event_ttl_ms :timer.minutes(5)

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Push an event to a session's buffer.

  Returns the event ID assigned to this event.
  """
  def push(session_id, event_data) when is_binary(session_id) do
    event_id = generate_event_id()
    event = %{
      id: event_id,
      data: event_data,
      timestamp: System.monotonic_time(:millisecond)
    }

    GenServer.call(__MODULE__, {:push, session_id, event})
    event_id
  end

  @doc """
  Get all events since a specific event ID.

  Used for SSE resumption with `Last-Event-ID` header.
  Returns `{:ok, events}` or `{:ok, []}` if session doesn't exist.
  """
  def since(session_id, last_event_id) when is_binary(session_id) do
    case Arca.Cache.get({:sse_events, session_id}) do
      {:ok, events} ->
        now = System.monotonic_time(:millisecond)

        # Find events after the given ID, filtering out expired ones
        filtered =
          events
          |> Enum.drop_while(fn e -> e.id != last_event_id end)
          |> Enum.drop(1)  # Drop the matching event itself
          |> Enum.filter(fn e -> now - e.timestamp < @event_ttl_ms end)

        {:ok, filtered}

      :miss ->
        {:ok, []}
    end
  end

  @doc """
  Get all pending events for a session.

  Returns `{:ok, events}` or `{:ok, []}` if no events.
  Events older than 5 minutes are filtered out per PRD 5.4.
  """
  def pending(session_id) when is_binary(session_id) do
    case Arca.Cache.get({:sse_events, session_id}) do
      {:ok, events} ->
        now = System.monotonic_time(:millisecond)
        valid_events = Enum.filter(events, fn e -> now - e.timestamp < @event_ttl_ms end)
        {:ok, valid_events}

      :miss ->
        {:ok, []}
    end
  end

  @doc """
  Clear all events for a session.

  Called when session is terminated.
  """
  def clear(session_id) when is_binary(session_id) do
    Arca.Cache.invalidate({:sse_events, session_id})
    :ok
  end

  @doc """
  Subscribe a process to receive events for a session.

  The process will receive `{:sse_event, event}` messages.
  """
  def subscribe(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:subscribe, session_id, self()})
  end

  @doc """
  Unsubscribe a process from session events.
  """
  def unsubscribe(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:unsubscribe, session_id, self()})
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Track subscribers: %{session_id => MapSet.new([pid])}
    {:ok, %{subscribers: %{}}}
  end

  @impl true
  def handle_call({:push, session_id, event}, _from, state) do
    # Get existing events or empty list
    events =
      case Arca.Cache.get({:sse_events, session_id}) do
        {:ok, existing} -> existing
        :miss -> []
      end

    # Append and trim to max size
    updated =
      (events ++ [event])
      |> Enum.take(-@max_events_per_session)

    Arca.Cache.put({:sse_events, session_id}, updated, @event_ttl_ms)

    # Notify subscribers
    subscribers = Map.get(state.subscribers, session_id, MapSet.new())
    for pid <- subscribers do
      send(pid, {:sse_event, event})
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:subscribe, session_id, pid}, _from, state) do
    Process.monitor(pid)

    subscribers =
      state.subscribers
      |> Map.update(session_id, MapSet.new([pid]), &MapSet.put(&1, pid))

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  @impl true
  def handle_call({:unsubscribe, session_id, pid}, _from, state) do
    subscribers =
      state.subscribers
      |> Map.update(session_id, MapSet.new(), &MapSet.delete(&1, pid))

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Remove dead process from all subscriptions
    subscribers =
      state.subscribers
      |> Enum.map(fn {session_id, pids} -> {session_id, MapSet.delete(pids, pid)} end)
      |> Enum.into(%{})

    {:noreply, %{state | subscribers: subscribers}}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp generate_event_id do
    :crypto.strong_rand_bytes(12)
    |> Base.url_encode64(padding: false)
  end
end
