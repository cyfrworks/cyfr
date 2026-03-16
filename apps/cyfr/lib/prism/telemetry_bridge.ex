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
    safe_broadcast("prism:executions", metadata, {:execution_started, metadata, measurements})
  end

  def handle_event([:cyfr, :opus, :execute, :stop], measurements, metadata, _config) do
    safe_broadcast("prism:executions", metadata, {:execution_completed, metadata, measurements})
  end

  def handle_event([:cyfr, :opus, :execute, :exception], measurements, metadata, _config) do
    safe_broadcast("prism:executions", metadata, {:execution_failed, metadata, measurements})
  end

  def handle_event([:cyfr, :emissary, :request], measurements, metadata, _config) do
    safe_broadcast("prism:requests", metadata, {:request, metadata, measurements})
  end

  def handle_event([:cyfr, :sanctum, :auth], measurements, metadata, _config) do
    safe_broadcast("prism:system", metadata, {:auth_event, metadata, measurements})
  end

  def handle_event([:cyfr, :sanctum, :policy], measurements, metadata, _config) do
    safe_broadcast("prism:components", metadata, {:policy_changed, metadata, measurements})
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  @impl true
  def handle_info(msg, state) do
    Logger.warning("#{__MODULE__}: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Wrap PubSub broadcast so that a failure never propagates to the caller.
  # This is critical inside :telemetry handler callbacks — if the handler
  # raises, the telemetry library permanently detaches it and all Prism
  # dashboard live updates silently stop.
  defp safe_broadcast(base_topic, metadata, message) do
    topic = scoped_topic(base_topic, metadata)

    case Phoenix.PubSub.broadcast(@pubsub, topic, message) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[TelemetryBridge] PubSub broadcast failed: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.warning("[TelemetryBridge] PubSub broadcast error: #{Exception.message(e)}")
      :ok
  end

  # Build a tenant-scoped topic from telemetry metadata.
  # Falls back to the base topic when no org_id is present (Core mode).
  defp scoped_topic(base, metadata) do
    org_id = metadata[:org_id]

    if org_id do
      Sanctum.PubSub.topic(base, %Sanctum.Context{
        org_id: org_id,
        project_id: metadata[:project_id]
      })
    else
      base
    end
  end
end
