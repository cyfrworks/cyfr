defmodule Opus.ExecutionEventBuffer do
  @moduledoc """
  Thin event buffer for formula execution streaming.

  Broadcasts events via PubSub and maintains a short-lived replay buffer
  in Arca.Cache so that late-joining SSE clients can catch up.

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

  @max_events 50
  @buffer_ttl_ms :timer.minutes(10)
  @pubsub Emissary.PubSub

  @doc """
  Push an intermediate event from a formula's `emit` host function.
  """
  def push(execution_id, data, sequence) do
    event = %{
      type: "emit",
      execution_id: execution_id,
      sequence: sequence,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: data
    }

    Phoenix.PubSub.broadcast(@pubsub, topic(execution_id), {:execution_event, event})
    buffer_event(execution_id, event)
    :ok
  end

  @doc """
  Push a terminal event (complete/error) from the Executor.
  """
  def push_terminal(execution_id, type, data, sequence) do
    event = %{
      type: type,
      execution_id: execution_id,
      sequence: sequence,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: data
    }

    Phoenix.PubSub.broadcast(@pubsub, topic(execution_id), {:execution_event, event})
    buffer_event(execution_id, event)
    :ok
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
  def subscribe(execution_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(execution_id))
  end

  @doc """
  Unsubscribe the calling process from execution events.
  """
  def unsubscribe(execution_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, topic(execution_id))
  end

  @doc """
  PubSub topic for a given execution.
  """
  def topic(execution_id), do: "execution:events:#{execution_id}"

  # Append event to the Arca.Cache replay buffer, capping at @max_events.
  defp buffer_event(execution_id, event) do
    key = {:exec_events, execution_id}

    events =
      case Arca.Cache.get(key) do
        {:ok, existing} -> existing
        :miss -> []
      end

    Arca.Cache.put(key, (events ++ [event]) |> Enum.take(-@max_events), @buffer_ttl_ms)
  end
end
