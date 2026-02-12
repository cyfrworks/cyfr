defmodule Emissary.MCP.SSEBufferTest do
  use ExUnit.Case, async: true

  alias Emissary.MCP.{Session, SSEBuffer}
  alias Sanctum.Context

  setup do
    Arca.Cache.init()

    # Ensure the SSEBuffer GenServer is running
    case GenServer.whereis(SSEBuffer) do
      nil -> start_supervised!(SSEBuffer)
      _pid -> :ok
    end

    # Create a test session
    ctx = Context.local()
    {:ok, session} = Session.create(ctx)

    on_exit(fn ->
      Session.terminate(session.id)
      SSEBuffer.clear(session.id)
    end)

    {:ok, session: session}
  end

  describe "push and pending" do
    test "initially returns empty list", %{session: session} do
      {:ok, events} = SSEBuffer.pending(session.id)
      assert events == []
    end

    test "push returns event ID", %{session: session} do
      event_id = SSEBuffer.push(session.id, %{type: "test", data: "hello"})
      assert is_binary(event_id)
      assert String.length(event_id) > 0
    end

    test "pending returns pushed events", %{session: session} do
      SSEBuffer.push(session.id, %{type: "test", data: "hello"})

      {:ok, events} = SSEBuffer.pending(session.id)
      assert length(events) == 1
      assert hd(events).data == %{type: "test", data: "hello"}
    end

    test "events have id, data, and timestamp", %{session: session} do
      event_id = SSEBuffer.push(session.id, %{n: 1})

      {:ok, [event]} = SSEBuffer.pending(session.id)
      assert event.id == event_id
      assert event.data == %{n: 1}
      assert is_integer(event.timestamp)
    end
  end

  describe "since/2 - resumption" do
    test "returns events after given ID", %{session: session} do
      id1 = SSEBuffer.push(session.id, %{n: 1})
      id2 = SSEBuffer.push(session.id, %{n: 2})
      _id3 = SSEBuffer.push(session.id, %{n: 3})

      # Get events since id1 (should return 2 and 3)
      {:ok, events} = SSEBuffer.since(session.id, id1)
      assert length(events) == 2
      assert Enum.at(events, 0).data == %{n: 2}
      assert Enum.at(events, 1).data == %{n: 3}

      # Get events since id2 (should return only 3)
      {:ok, events} = SSEBuffer.since(session.id, id2)
      assert length(events) == 1
      assert hd(events).data == %{n: 3}
    end

    test "returns empty list for last event ID", %{session: session} do
      _id1 = SSEBuffer.push(session.id, %{n: 1})
      id2 = SSEBuffer.push(session.id, %{n: 2})

      {:ok, events} = SSEBuffer.since(session.id, id2)
      assert events == []
    end

    test "returns empty list for unknown session", %{session: _session} do
      {:ok, events} = SSEBuffer.since("sess_unknown", "some_id")
      assert events == []
    end

    test "returns empty list for unknown event ID", %{session: session} do
      SSEBuffer.push(session.id, %{n: 1})

      {:ok, events} = SSEBuffer.since(session.id, "unknown_event_id")
      assert events == []
    end
  end

  describe "clear/1" do
    test "removes all events for session", %{session: session} do
      SSEBuffer.push(session.id, %{n: 1})
      SSEBuffer.push(session.id, %{n: 2})

      {:ok, events} = SSEBuffer.pending(session.id)
      assert length(events) == 2

      SSEBuffer.clear(session.id)

      {:ok, events} = SSEBuffer.pending(session.id)
      assert events == []
    end
  end

  describe "max events limit" do
    test "respects max events per session (100)", %{session: session} do
      # Push more than the max (100)
      for i <- 1..110 do
        SSEBuffer.push(session.id, %{n: i})
      end

      {:ok, events} = SSEBuffer.pending(session.id)
      # Should only keep the last 100
      assert length(events) == 100
      # First event should be n: 11 (oldest 10 were dropped)
      assert hd(events).data == %{n: 11}
    end

    test "buffer overflow with 150 events keeps only last 100", %{session: session} do
      # Push 150 events - should overflow significantly
      for i <- 1..150 do
        SSEBuffer.push(session.id, %{n: i})
      end

      {:ok, events} = SSEBuffer.pending(session.id)
      # Should only keep the last 100
      assert length(events) == 100
      # First event should be n: 51 (oldest 50 were dropped)
      assert hd(events).data == %{n: 51}
      # Last event should be n: 150
      assert List.last(events).data == %{n: 150}
    end

    test "since/2 works correctly after buffer overflow", %{session: session} do
      # Push 150 events
      ids = for i <- 1..150, do: SSEBuffer.push(session.id, %{n: i})

      # Try to get events since an ID that was dropped
      dropped_id = Enum.at(ids, 10)
      {:ok, events} = SSEBuffer.since(session.id, dropped_id)
      # Should return empty since the marker event was dropped
      assert events == []

      # Get events since a recent ID (one that still exists)
      recent_id = Enum.at(ids, 100)
      {:ok, events} = SSEBuffer.since(session.id, recent_id)
      # Should return events after that ID
      assert length(events) > 0
    end
  end

  describe "concurrent operations" do
    test "concurrent push operations are safe", %{session: session} do
      # Spawn 10 tasks each pushing 20 events
      tasks =
        for batch <- 1..10 do
          Task.async(fn ->
            for i <- 1..20 do
              SSEBuffer.push(session.id, %{batch: batch, index: i})
            end
          end)
        end

      Task.await_many(tasks, 5000)

      {:ok, events} = SSEBuffer.pending(session.id)
      # Should have exactly 100 events (max limit)
      assert length(events) == 100
      # All events should have valid data
      for event <- events do
        assert Map.has_key?(event.data, :batch)
        assert Map.has_key?(event.data, :index)
      end
    end

    test "concurrent push and since operations are safe", %{session: session} do
      # Pre-fill buffer with some events
      initial_ids =
        for i <- 1..50 do
          SSEBuffer.push(session.id, %{n: i})
        end

      marker_id = Enum.at(initial_ids, 25)

      # Concurrent push and since operations
      push_task =
        Task.async(fn ->
          for i <- 51..100 do
            SSEBuffer.push(session.id, %{n: i})
          end
        end)

      since_task =
        Task.async(fn ->
          # Try multiple since calls during pushes
          for _ <- 1..10 do
            SSEBuffer.since(session.id, marker_id)
            Process.sleep(10)
          end

          SSEBuffer.since(session.id, marker_id)
        end)

      Task.await(push_task, 5000)
      {:ok, final_events} = Task.await(since_task, 5000)

      # Should complete without error
      # final_events might be empty if marker was dropped, or have events if not
      assert is_list(final_events)
    end

    test "concurrent pending operations return consistent state", %{session: session} do
      # Push 50 events
      for i <- 1..50 do
        SSEBuffer.push(session.id, %{n: i})
      end

      # Concurrent pending calls
      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            SSEBuffer.pending(session.id)
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should succeed and return same length
      for {:ok, events} <- results do
        assert length(events) == 50
      end
    end
  end

  describe "subscribe/unsubscribe" do
    test "subscriber receives events", %{session: session} do
      :ok = SSEBuffer.subscribe(session.id)

      SSEBuffer.push(session.id, %{type: "notification", data: "test"})

      assert_receive {:sse_event, event}
      assert event.data == %{type: "notification", data: "test"}

      SSEBuffer.unsubscribe(session.id)
    end

    test "unsubscribed process does not receive events", %{session: session} do
      :ok = SSEBuffer.subscribe(session.id)
      :ok = SSEBuffer.unsubscribe(session.id)

      SSEBuffer.push(session.id, %{type: "notification", data: "test"})

      refute_receive {:sse_event, _event}, 100
    end

    test "multiple subscribers receive events", %{session: session} do
      parent = self()

      task1 =
        Task.async(fn ->
          SSEBuffer.subscribe(session.id)
          send(parent, :subscribed)

          receive do
            {:sse_event, event} -> event.data
          after
            1000 -> :timeout
          end
        end)

      task2 =
        Task.async(fn ->
          SSEBuffer.subscribe(session.id)
          send(parent, :subscribed)

          receive do
            {:sse_event, event} -> event.data
          after
            1000 -> :timeout
          end
        end)

      # Wait for both to subscribe
      assert_receive :subscribed
      assert_receive :subscribed

      # Push event
      SSEBuffer.push(session.id, %{n: 42})

      # Both should receive
      assert Task.await(task1) == %{n: 42}
      assert Task.await(task2) == %{n: 42}
    end
  end

  describe "event TTL - 5 minute expiration" do
    @tag :slow
    test "events expire after 5 minutes", %{session: session} do
      # Push an event normally
      SSEBuffer.push(session.id, %{n: 1})

      # Get the events and manually insert an old event via Arca.Cache
      {:ok, [current_event]} = SSEBuffer.pending(session.id)

      # Create an expired event (timestamp older than 5 minutes)
      old_timestamp = System.monotonic_time(:millisecond) - :timer.minutes(6)
      expired_event = %{id: "old_event", data: %{n: 0}, timestamp: old_timestamp}

      # Insert directly into Arca.Cache with both events
      Arca.Cache.put({:sse_events, session.id}, [expired_event, current_event], :timer.minutes(5))

      # pending/1 should filter out the expired event
      {:ok, events} = SSEBuffer.pending(session.id)
      assert length(events) == 1
      assert hd(events).data == %{n: 1}
    end

    test "since/2 filters expired events during resumption", %{session: session} do
      # Push a current event
      current_id = SSEBuffer.push(session.id, %{n: 2})

      # Create expired and valid events manually
      old_timestamp = System.monotonic_time(:millisecond) - :timer.minutes(6)
      current_timestamp = System.monotonic_time(:millisecond)

      expired_event = %{id: "old_event", data: %{n: 0}, timestamp: old_timestamp}
      marker_event = %{id: "marker", data: %{n: 1}, timestamp: old_timestamp + 1}
      current_event = %{id: current_id, data: %{n: 2}, timestamp: current_timestamp}

      # Insert into Arca.Cache
      Arca.Cache.put({:sse_events, session.id}, [expired_event, marker_event, current_event], :timer.minutes(5))

      # Since marker event - should only return current (non-expired) event
      {:ok, events} = SSEBuffer.since(session.id, "marker")
      assert length(events) == 1
      assert hd(events).data == %{n: 2}
    end
  end
end
