# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.TelemetryBridge do
  @moduledoc """
  Bridges CYFR telemetry events to PubSub for LiveView consumption.

  Attaches to existing telemetry events and broadcasts to PubSub topics
  that LiveViews can subscribe to for real-time updates.

  The topics and the messages each one carries are named in `Cyfr.Bus`;
  each is scoped to the athanor the event's metadata names, so a server with
  many athanors isolates broadcasts to each athanor's subscribers.

  Telemetry metadata is by convention whatever the emitter felt like
  attaching, and this module forwards it verbatim to browser sessions. That
  is a trust boundary, so every message goes through `Cyfr.Sanitizer`
  on the way out: today's emitters carry only identifiers and outcomes, and
  the next one to carry a credential name should not be the thing that finds
  out.

  ## The identity domain's standing changes

  A foundation below the host emits `:telemetry` and never broadcasts, so
  every announcement `Sanctum.Telemetry` makes — a tray notification, a
  session minted or revoked, a dropped caller memo, a membership, a vault
  entry, an archive, the API key and webhook rosters — becomes its bus
  message here. The topic
  strings are still the domain's own (`Cyfr.Bus` delegates to them), and
  the message shapes are unchanged from when Sanctum broadcast them
  itself; what moved is who puts them on the bus.
  """

  use GenServer
  require Logger

  alias Cyfr.Bus

  @pubsub Emissary.PubSub

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    attach_handlers()
    {:ok, %{}}
  end

  # Handlers are global to the node, not owned by this process, so a restart
  # would otherwise leave the pre-restart attach in place and `attach/4`
  # would answer `{:error, :already_exists}` — silently, since nothing read
  # the return value. Detaching first makes the attach mean what it says.
  @impl true
  def terminate(_reason, _state) do
    for {_event, id} <- events(), do: :telemetry.detach(handler_id(id))
    :ok
  end

  defp handler_id(id), do: "prism-#{id}"

  defp attach_handlers do
    for {event, id} <- events() do
      handler = handler_id(id)
      :telemetry.detach(handler)

      case :telemetry.attach(handler, event, &__MODULE__.handle_event/4, nil) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "[TelemetryBridge] could not attach #{handler}: #{inspect(reason)} — " <>
              "console updates for this event will not arrive"
          )
      end
    end

    :ok
  end

  defp events do
    [
      {[:cyfr, :opus, :execute, :start], :execution_start},
      {[:cyfr, :opus, :execute, :stop], :execution_stop},
      {[:cyfr, :opus, :execute, :exception], :execution_exception},
      {[:cyfr, :emissary, :request], :request},
      {[:cyfr, :sanctum, :policy, :decision], :policy_decision},
      {[:cyfr, :locus, :build, :start], :build_start},
      {[:cyfr, :locus, :build, :progress], :build_progress},
      {[:cyfr, :locus, :build, :stop], :build_stop},
      {[:cyfr, :schedules, :fired], :schedule_fired},
      {[:cyfr, :schedules, :failed], :schedule_failed},
      {[:cyfr, :compendium, :component, :install], :component_install},
      {[:cyfr, :compendium, :component, :remove], :component_remove},
      {[:cyfr, :compendium, :component, :push], :component_push},
      {[:cyfr, :emissary, :tincture, :invoke, :start], :tincture_invoke_start},
      {[:cyfr, :emissary, :tincture, :invoke, :stop], :tincture_invoke_stop},
      {[:cyfr, :sanctum, :notify], :sanctum_notify},
      {[:cyfr, :sanctum, :caller, :invalidated], :sanctum_caller_invalidated},
      {[:cyfr, :sanctum, :session, :created], :sanctum_session_created},
      {[:cyfr, :sanctum, :sessions, :revoked], :sanctum_sessions_revoked},
      {[:cyfr, :sanctum, :membership, :changed], :sanctum_membership_changed},
      {[:cyfr, :sanctum, :vault, :entry_changed], :sanctum_vault_entry_changed},
      {[:cyfr, :sanctum, :athanor, :archived], :sanctum_athanor_archived},
      {[:cyfr, :sanctum, :api_keys, :changed], :sanctum_api_keys_changed},
      {[:cyfr, :sanctum, :webhooks, :changed], :sanctum_webhooks_changed}
    ]
  end

  def handle_event([:cyfr, :opus, :execute, :start], measurements, metadata, _config) do
    safe_broadcast(&Bus.executions/1, metadata, {:execution_started, metadata, measurements})
  end

  def handle_event([:cyfr, :opus, :execute, :stop], measurements, metadata, _config) do
    safe_broadcast(&Bus.executions/1, metadata, {:execution_completed, metadata, measurements})
    safe_notify(metadata, :execution_finished)
  end

  def handle_event([:cyfr, :opus, :execute, :exception], measurements, metadata, _config) do
    safe_broadcast(&Bus.executions/1, metadata, {:execution_failed, metadata, measurements})
    safe_notify(metadata, :execution_failed)
  end

  def handle_event([:cyfr, :emissary, :request], measurements, metadata, _config) do
    safe_broadcast(&Bus.requests/1, metadata, {:request, metadata, measurements})
  end

  def handle_event([:cyfr, :sanctum, :policy, :decision], measurements, metadata, _config) do
    safe_broadcast(&Bus.enforcement/1, metadata, {:policy_decision, metadata, measurements})
  end

  def handle_event([:cyfr, :locus, :build, :start], measurements, metadata, _config) do
    safe_broadcast(&Bus.builds/1, metadata, {:build_started, metadata, measurements})
  end

  def handle_event([:cyfr, :locus, :build, :progress], measurements, metadata, _config) do
    safe_broadcast(&Bus.builds/1, metadata, {:build_progress, metadata, measurements})
  end

  def handle_event([:cyfr, :locus, :build, :stop], measurements, metadata, _config) do
    safe_broadcast(&Bus.builds/1, metadata, {:build_stopped, metadata, measurements})
  end

  def handle_event([:cyfr, :schedules, :fired], measurements, metadata, _config) do
    safe_broadcast(&Bus.schedule_runs/1, metadata, {:schedule_fired, metadata, measurements})
  end

  # A schedule that could not run, or ran and failed — the one silent loss
  # the tray must show. The event always names the athanor.
  def handle_event([:cyfr, :schedules, :failed], measurements, metadata, _config) do
    safe_broadcast(&Bus.schedule_runs/1, metadata, {:schedule_failed, metadata, measurements})

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
    safe_broadcast(&Bus.components/1, metadata, {:component_installed, metadata, measurements})
  end

  def handle_event([:cyfr, :compendium, :component, :remove], measurements, metadata, _config) do
    safe_broadcast(&Bus.components/1, metadata, {:component_removed, metadata, measurements})
  end

  def handle_event([:cyfr, :compendium, :component, :push], measurements, metadata, _config) do
    safe_broadcast(&Bus.components/1, metadata, {:component_pushed, metadata, measurements})
  end

  def handle_event(
        [:cyfr, :emissary, :tincture, :invoke, :start],
        measurements,
        metadata,
        _config
      ) do
    safe_broadcast(
      &Bus.tinctures/1,
      metadata,
      {:tincture_invoke_started, metadata, measurements}
    )
  end

  def handle_event([:cyfr, :emissary, :tincture, :invoke, :stop], measurements, metadata, _config) do
    safe_broadcast(
      &Bus.tinctures/1,
      metadata,
      {:tincture_invoke_stopped, metadata, measurements}
    )
  end

  # --- the identity domain's standing changes -----------------------------

  def handle_event([:cyfr, :sanctum, :notify], _measurements, metadata, _config) do
    kind = metadata[:kind]
    payload = metadata[:payload] || %{}

    case metadata[:athanor_id] do
      athanor_id when is_binary(athanor_id) and athanor_id != "" ->
        safe_topic_broadcast(Bus.notify(athanor_id), {:notify, athanor_id, kind, payload})

      _platform ->
        safe_topic_broadcast(Bus.platform_notify(), {:notify, :platform, kind, payload})
    end
  end

  # The memo is a cached authorization decision held in each member's own
  # table, so the announcement is global: every member drops what it holds
  # for that session row key. The member that announced dropped its own
  # before the event fired; this is what reaches the rest.
  def handle_event([:cyfr, :sanctum, :caller, :invalidated], _measurements, metadata, _config) do
    safe_topic_broadcast(
      Bus.caller_invalidated_global(),
      {:caller_invalidated, metadata[:hash]}
    )
  end

  def handle_event([:cyfr, :sanctum, :session, :created], _measurements, _metadata, _config) do
    safe_topic_broadcast(Bus.sessions(), {:session_created, :notification})
  end

  def handle_event([:cyfr, :sanctum, :sessions, :revoked], _measurements, metadata, _config) do
    safe_topic_broadcast(Bus.sessions(), {:sessions_revoked, metadata[:user_id]})
  end

  def handle_event([:cyfr, :sanctum, :membership, :changed], _measurements, metadata, _config) do
    safe_topic_broadcast(
      Bus.memberships(metadata[:user_id]),
      {:membership_changed,
       %{
         user_id: metadata[:user_id],
         athanor_id: metadata[:athanor_id],
         change: metadata[:change]
       }}
    )
  end

  # Two topics, one announcement: the athanor's own, and the deliberately
  # global one the external-MCP reconciler reads because it cannot know
  # every tenant topic.
  def handle_event([:cyfr, :sanctum, :vault, :entry_changed], _measurements, metadata, _config) do
    athanor_id = metadata[:athanor_id]
    entry_id = metadata[:entry_id]
    verb = metadata[:verb]

    safe_broadcast(&Bus.vault_changed/1, metadata, {:vault_entry_changed, entry_id, verb})

    safe_topic_broadcast(
      Bus.vault_changed_global(),
      {:vault_entry_changed_global, athanor_id, entry_id, verb, metadata[:meta] || %{}}
    )
  end

  def handle_event([:cyfr, :sanctum, :athanor, :archived], _measurements, metadata, _config) do
    safe_topic_broadcast(
      Bus.athanor_archived_global(),
      {:athanor_archived_global, metadata[:athanor_id]}
    )
  end

  def handle_event([:cyfr, :sanctum, :api_keys, :changed], _measurements, metadata, _config) do
    safe_broadcast(&Bus.api_keys/1, metadata, :api_keys_changed)
  end

  def handle_event([:cyfr, :sanctum, :webhooks, :changed], _measurements, metadata, _config) do
    safe_broadcast(&Bus.webhooks/1, metadata, :webhooks_changed)
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  @impl true
  def handle_info(msg, state) do
    Cyfr.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  # Wrap PubSub broadcast so that a failure never propagates to the caller.
  # This is critical inside :telemetry handler callbacks — if the handler
  # raises, the telemetry library permanently detaches it and all Prism
  # dashboard live updates silently stop.
  defp safe_broadcast(topic_fun, metadata, message) do
    case scoped_topic(topic_fun, metadata) do
      {:ok, topic} ->
        case Phoenix.PubSub.broadcast(@pubsub, topic, Cyfr.Sanitizer.sanitize(message)) do
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

  # A topic the caller already built — an unscoped one, or a tenant topic
  # from a metadata field this handler read itself. Same containment as
  # `safe_broadcast/3`: a raising handler is permanently detached by the
  # telemetry library, and every console update stops with it.
  defp safe_topic_broadcast(topic, message) do
    case Phoenix.PubSub.broadcast(@pubsub, topic, Cyfr.Sanitizer.sanitize(message)) do
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
