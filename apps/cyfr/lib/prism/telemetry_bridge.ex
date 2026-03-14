defmodule Prism.TelemetryBridge do
  @moduledoc """
  Bridges CYFR telemetry events to PubSub for LiveView consumption.

  Attaches to existing telemetry events and broadcasts to PubSub topics
  that LiveViews can subscribe to for real-time updates.

  Topics are scoped per-tenant via `Sanctum.PubSub.topic/2` so that
  Arx mode isolates broadcasts per org. Core mode passes topics through
  unchanged.

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
    topic = scoped_topic("prism:executions", metadata)
    Phoenix.PubSub.broadcast(@pubsub, topic, {:execution_started, metadata, measurements})
  end

  def handle_event([:cyfr, :opus, :execute, :stop], measurements, metadata, _config) do
    topic = scoped_topic("prism:executions", metadata)
    Phoenix.PubSub.broadcast(@pubsub, topic, {:execution_completed, metadata, measurements})
  end

  def handle_event([:cyfr, :opus, :execute, :exception], measurements, metadata, _config) do
    topic = scoped_topic("prism:executions", metadata)
    Phoenix.PubSub.broadcast(@pubsub, topic, {:execution_failed, metadata, measurements})
  end

  def handle_event([:cyfr, :emissary, :request], measurements, metadata, _config) do
    topic = scoped_topic("prism:requests", metadata)
    Phoenix.PubSub.broadcast(@pubsub, topic, {:request, metadata, measurements})
  end

  def handle_event([:cyfr, :sanctum, :auth], measurements, metadata, _config) do
    topic = scoped_topic("prism:system", metadata)
    Phoenix.PubSub.broadcast(@pubsub, topic, {:auth_event, metadata, measurements})
  end

  def handle_event([:cyfr, :sanctum, :policy], measurements, metadata, _config) do
    topic = scoped_topic("prism:components", metadata)
    Phoenix.PubSub.broadcast(@pubsub, topic, {:policy_changed, metadata, measurements})
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  # Build a tenant-scoped topic from telemetry metadata.
  # Falls back to the base topic when no org_id is present (Core mode).
  defp scoped_topic(base, metadata) do
    org_id = metadata[:org_id]

    if org_id do
      Sanctum.PubSub.topic(base, %Sanctum.Context{org_id: org_id, project_id: metadata[:project_id]})
    else
      base
    end
  end
end
