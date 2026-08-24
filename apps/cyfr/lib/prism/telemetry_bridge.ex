# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.TelemetryBridge do
  @moduledoc """
  Bridges CYFR telemetry events to PubSub for LiveView consumption.

  Attaches to existing telemetry events and broadcasts to PubSub topics
  that LiveViews can subscribe to for real-time updates.

  The topics and the messages each one carries are named in `Prism.Topics`;
  each is scoped to the athanor the event's metadata names, so a server with
  many athanors isolates broadcasts to each athanor's subscribers.
  """

  use GenServer
  require Logger

  alias Prism.Topics

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
      {[:cyfr, :sanctum, :policy, :decision], :policy_decision},
      {[:cyfr, :locus, :build, :start], :build_start},
      {[:cyfr, :locus, :build, :progress], :build_progress},
      {[:cyfr, :locus, :build, :stop], :build_stop},
      {[:cyfr, :opus, :schedule, :fired], :schedule_fired},
      {[:cyfr, :opus, :schedule, :failed], :schedule_failed},
      {[:cyfr, :compendium, :component, :install], :component_install},
      {[:cyfr, :compendium, :component, :remove], :component_remove},
      {[:cyfr, :emissary, :tincture, :invoke, :start], :tincture_invoke_start},
      {[:cyfr, :emissary, :tincture, :invoke, :stop], :tincture_invoke_stop}
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
    safe_broadcast(&Topics.executions/1, metadata, {:execution_started, metadata, measurements})
  end

  def handle_event([:cyfr, :opus, :execute, :stop], measurements, metadata, _config) do
    safe_broadcast(&Topics.executions/1, metadata, {:execution_completed, metadata, measurements})
    safe_notify(metadata, :execution_finished)
  end

  def handle_event([:cyfr, :opus, :execute, :exception], measurements, metadata, _config) do
    safe_broadcast(&Topics.executions/1, metadata, {:execution_failed, metadata, measurements})
    safe_notify(metadata, :execution_failed)
  end

  def handle_event([:cyfr, :emissary, :request], measurements, metadata, _config) do
    safe_broadcast(&Topics.requests/1, metadata, {:request, metadata, measurements})
  end

  def handle_event([:cyfr, :sanctum, :policy, :decision], measurements, metadata, _config) do
    safe_broadcast(&Topics.enforcement/1, metadata, {:policy_decision, metadata, measurements})
  end

  def handle_event([:cyfr, :locus, :build, :start], measurements, metadata, _config) do
    safe_broadcast(&Topics.builds/1, metadata, {:build_started, metadata, measurements})
  end

  def handle_event([:cyfr, :locus, :build, :progress], measurements, metadata, _config) do
    safe_broadcast(&Topics.builds/1, metadata, {:build_progress, metadata, measurements})
  end

  def handle_event([:cyfr, :locus, :build, :stop], measurements, metadata, _config) do
    safe_broadcast(&Topics.builds/1, metadata, {:build_stopped, metadata, measurements})
  end

  def handle_event([:cyfr, :opus, :schedule, :fired], measurements, metadata, _config) do
    safe_broadcast(&Topics.schedule_runs/1, metadata, {:schedule_fired, metadata, measurements})
  end

  # A schedule that could not run, or ran and failed — the one silent loss
  # the tray must show. The event always names the athanor.
  def handle_event([:cyfr, :opus, :schedule, :failed], measurements, metadata, _config) do
    safe_broadcast(&Topics.schedule_runs/1, metadata, {:schedule_failed, metadata, measurements})

    with athanor_id when is_binary(athanor_id) and athanor_id != "" <- metadata[:athanor_id] do
      Sanctum.Notify.broadcast(athanor_id, :schedule_failed, %{
        schedule_id: metadata[:schedule_id],
        execution_id: metadata[:execution_id],
        reason: metadata[:reason]
      })
    end

    :ok
  end

  def handle_event([:cyfr, :compendium, :component, :install], measurements, metadata, _config) do
    safe_broadcast(&Topics.components/1, metadata, {:component_installed, metadata, measurements})
  end

  def handle_event([:cyfr, :compendium, :component, :remove], measurements, metadata, _config) do
    safe_broadcast(&Topics.components/1, metadata, {:component_removed, metadata, measurements})
  end

  def handle_event(
        [:cyfr, :emissary, :tincture, :invoke, :start],
        measurements,
        metadata,
        _config
      ) do
    safe_broadcast(
      &Topics.tinctures/1,
      metadata,
      {:tincture_invoke_started, metadata, measurements}
    )
  end

  def handle_event([:cyfr, :emissary, :tincture, :invoke, :stop], measurements, metadata, _config) do
    safe_broadcast(
      &Topics.tinctures/1,
      metadata,
      {:tincture_invoke_stopped, metadata, measurements}
    )
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
  defp safe_broadcast(topic_fun, metadata, message) do
    case scoped_topic(topic_fun, metadata) do
      {:ok, topic} ->
        case Phoenix.PubSub.broadcast(@pubsub, topic, message) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("[TelemetryBridge] PubSub broadcast failed: #{inspect(reason)}")
            :ok
        end

      :skip ->
        :ok
    end
  rescue
    e ->
      Logger.warning("[TelemetryBridge] PubSub broadcast error: #{Exception.message(e)}")
      :ok
  end

  # The athanor's fan-in notify topic (the tray badges): only root executions
  # count — a chain's children are the same piece of work.
  defp safe_notify(metadata, kind) do
    with athanor_id when is_binary(athanor_id) and athanor_id != "" <- metadata[:athanor_id],
         nil <- metadata[:parent_execution_id] do
      Sanctum.Notify.broadcast(athanor_id, kind, %{
        execution_id: metadata[:execution_id],
        reference: metadata[:reference]
      })
    end

    :ok
  rescue
    e ->
      Logger.warning("[TelemetryBridge] notify error: #{Exception.message(e)}")
      :ok
  end

  # An event whose metadata carries no athanor has no subscribers to reach and
  # is dropped — there is no default athanor to route it to.
  defp scoped_topic(topic_fun, metadata) do
    case metadata[:athanor_id] do
      athanor_id when is_binary(athanor_id) and athanor_id != "" ->
        {:ok, topic_fun.(athanor_id)}

      _ ->
        :skip
    end
  end
end
