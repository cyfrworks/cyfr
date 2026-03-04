defmodule Prism.TelemetryBridge do
  @moduledoc """
  Bridges CYFR telemetry events to PubSub for LiveView consumption.

  Attaches to existing telemetry events and broadcasts to PubSub topics
  that LiveViews can subscribe to for real-time updates.

  ## Topics

  - `prism:executions` — Execution lifecycle events
  - `prism:system` — System status changes
  - `prism:requests` — MCP request events
  - `prism:components` — Component/policy change events
  """

  use GenServer
  require Logger

  @pubsub Emissary.PubSub

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    attach_handlers()
    {:ok, %{}}
  end

  defp attach_handlers do
    events = [
      {[:cyfr, :opus, :execute, :start], :execution_start},
      {[:cyfr, :opus, :execute, :stop], :execution_stop},
      {[:cyfr, :opus, :execute, :exception], :execution_exception},
      {[:cyfr, :emissary, :request], :request},
      {[:cyfr, :sanctum, :auth], :auth},
      {[:cyfr, :sanctum, :policy], :policy}
    ]

    for {event, id} <- events do
      :telemetry.attach(
        "prism-#{id}",
        event,
        &__MODULE__.handle_event/4,
        nil
      )
    end
  end

  def handle_event([:cyfr, :opus, :execute, :start], measurements, metadata, _config) do
    Phoenix.PubSub.broadcast(@pubsub, "prism:executions", {:execution_started, metadata, measurements})
  end

  def handle_event([:cyfr, :opus, :execute, :stop], measurements, metadata, _config) do
    Phoenix.PubSub.broadcast(@pubsub, "prism:executions", {:execution_completed, metadata, measurements})
  end

  def handle_event([:cyfr, :opus, :execute, :exception], measurements, metadata, _config) do
    Phoenix.PubSub.broadcast(@pubsub, "prism:executions", {:execution_failed, metadata, measurements})
  end

  def handle_event([:cyfr, :emissary, :request], measurements, metadata, _config) do
    Phoenix.PubSub.broadcast(@pubsub, "prism:requests", {:request, metadata, measurements})
  end

  def handle_event([:cyfr, :sanctum, :auth], measurements, metadata, _config) do
    Phoenix.PubSub.broadcast(@pubsub, "prism:system", {:auth_event, metadata, measurements})
  end

  def handle_event([:cyfr, :sanctum, :policy], measurements, metadata, _config) do
    Phoenix.PubSub.broadcast(@pubsub, "prism:components", {:policy_changed, metadata, measurements})
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok
end
