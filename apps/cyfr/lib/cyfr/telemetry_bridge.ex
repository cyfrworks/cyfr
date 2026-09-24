# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.TelemetryBridge do
  @moduledoc """
  The one place a telemetry event becomes a bus message.

  A foundation below the host emits `:telemetry` and never broadcasts, so
  every announcement the identity domain makes — a tray entry, a session
  minted or revoked, a dropped caller memo, a membership, a vault entry,
  an archive, the API key and webhook rosters — and every lifecycle event
  the console follows reaches `Cyfr.Bus` here. The events it attaches are
  exactly `Cyfr.Telemetry.Catalog.consumed_by(:bridge)`; there is no
  second list.

  Each event maps to one payload constructor, which takes only the
  metadata fields it names: telemetry metadata is whatever its emitter
  attached, and the console is a trust boundary. A reason or an error is
  bounded (`Cyfr.Bus.bounded_reason/1`), never an arbitrary term. A tenant
  event that names no athanor has nowhere to go: it is dropped and counted
  as `[:cyfr, :bus, :bridge_dropped]`.

  The handlers run in the emitting process, and `:telemetry` detaches a
  handler that fails in any way for the life of the node. Every failure —
  a refused publish, a raising PubSub, an exit — is caught and logged
  here, so one bad event costs one message and not every update after it.
  """

  use GenServer

  require Logger

  alias Cyfr.Bus

  alias Cyfr.Bus.{
    ApiKeys,
    AthanorArchived,
    Build,
    CallerInvalidated,
    Components,
    Execution,
    Membership,
    Notify,
    PolicyDecision,
    Request,
    ScheduleRun,
    Session,
    Tinctures,
    VaultEntryChanged,
    Webhooks
  }

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The events the bridge attaches: the catalog's `:bridge` roster."
  @spec events() :: [[atom(), ...]]
  def events, do: Cyfr.Telemetry.Catalog.consumed_by(:bridge)

  @doc "The handler id the bridge attaches `event` under."
  @spec handler_id([atom(), ...]) :: {module(), [atom(), ...]}
  def handler_id(event), do: {__MODULE__, event}

  @impl true
  def init(_opts) do
    attach()
    {:ok, %{}}
  end

  # Handlers are global to the node, not owned by this process: a restart
  # would otherwise find the pre-restart attach in place. Detaching first
  # makes the attach mean what it says.
  @impl true
  def terminate(_reason, _state) do
    Enum.each(events(), &:telemetry.detach(handler_id(&1)))
  end

  @impl true
  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  defp attach do
    for event <- events() do
      id = handler_id(event)
      _ = :telemetry.detach(id)

      case :telemetry.attach(id, event, &__MODULE__.handle_event/4, nil) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "[Cyfr.TelemetryBridge] could not attach #{inspect(event)}: #{inspect(reason)} — " <>
              "console updates for this event will not arrive"
          )
      end
    end

    :ok
  end

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    for message <- messages(event, measurements, metadata), do: deliver(event, message)
    :ok
  catch
    kind, reason ->
      Logger.warning(
        "[Cyfr.TelemetryBridge] #{inspect(event)} not bridged: " <>
          Exception.format_banner(kind, reason)
      )

      :ok
  end

  # ---------------------------------------------------------------------------
  # One constructor per event
  # ---------------------------------------------------------------------------

  # What an event becomes: `{:tenant, athanor_id, topic_fun, build}` for a
  # tenant topic, `{:global, topic, payload}` for a global one. A tenant
  # message is built only once its athanor is known.
  defp messages([:cyfr, :opus, :execute, :start], _measurements, meta),
    do: [tenant(meta, &Bus.executions/1, &Execution.new(&1, :started, execution(meta)))]

  defp messages([:cyfr, :opus, :execute, :stop], _measurements, meta) do
    [
      tenant(meta, &Bus.executions/1, &Execution.new(&1, :completed, execution(meta)))
      | root_notify(meta, :execution_finished)
    ]
  end

  # A cancel ends the row as the caller asked; it is not a failure the
  # tray announces.
  defp messages(
         [:cyfr, :opus, :execute, :exception],
         _measurements,
         %{status: :cancelled} = meta
       ),
       do: [tenant(meta, &Bus.executions/1, &Execution.new(&1, :cancelled, execution(meta)))]

  defp messages([:cyfr, :opus, :execute, :exception], _measurements, meta) do
    [
      tenant(meta, &Bus.executions/1, &Execution.new(&1, :failed, execution(meta)))
      | root_notify(meta, :execution_failed)
    ]
  end

  defp messages([:cyfr, :emissary, :request], measurements, meta) do
    fields =
      meta
      |> Map.take([:request_id, :method, :tool, :action, :status])
      |> Map.put(:duration_ms, measurements[:duration_ms])

    [tenant(meta, &Bus.requests/1, &Request.new(&1, :logged, fields))]
  end

  defp messages([:cyfr, :sanctum, :policy, :decision], _measurements, meta) do
    fields = Map.take(meta, [:event_type, :decision, :component_ref])
    [tenant(meta, &Bus.enforcement/1, &PolicyDecision.new(&1, :changed, fields))]
  end

  defp messages([:cyfr, :locus, :build, stage], _measurements, meta)
       when stage in [:start, :progress, :stop] do
    kind = %{start: :started, progress: :progress, stop: :stopped}[stage]
    fields = Map.take(meta, [:build_id, :reference, :phase, :message, :status, :error])
    [tenant(meta, &Bus.builds/1, &Build.new(&1, kind, fields))]
  end

  defp messages([:cyfr, :schedules, :fired], _measurements, meta),
    do: [tenant(meta, &Bus.schedule_runs/1, &ScheduleRun.new(&1, :fired, schedule_run(meta)))]

  # A schedule that could not run, or ran and failed: the one silent loss
  # the tray must show.
  defp messages([:cyfr, :schedules, :failed], _measurements, meta) do
    [
      tenant(meta, &Bus.schedule_runs/1, &ScheduleRun.new(&1, :failed, schedule_run(meta))),
      tenant(meta, &Bus.notify/1, fn actor ->
        Notify.new(
          actor,
          :schedule_failed,
          Map.take(meta, [:schedule_id, :execution_id, :reason])
        )
      end)
    ]
  end

  defp messages([:cyfr, :compendium, :component, action], _measurements, meta)
       when action in [:install, :remove, :push] do
    kind = %{install: :installed, remove: :removed, push: :pushed}[action]
    fields = Map.take(meta, [:name, :version, :publisher, :component_type])
    [tenant(meta, &Bus.components/1, &Components.new(&1, kind, fields))]
  end

  defp messages([:cyfr, :emissary, :tincture, :invoke, stage], _measurements, meta)
       when stage in [:start, :stop] do
    kind = if stage == :start, do: :invoke_started, else: :invoke_stopped
    fields = Map.take(meta, [:request_id, :tincture_ref, :reference, :status, :error])
    [tenant(meta, &Bus.tinctures/1, &Tinctures.new(&1, kind, fields))]
  end

  # The tray: an athanor's own, or — naming none — the operators'.
  defp messages([:cyfr, :sanctum, :notify], _measurements, %{athanor_id: nil} = meta),
    do: [{:global, Bus.platform_notify(), Notify.platform(meta[:kind], meta[:payload] || %{})}]

  defp messages([:cyfr, :sanctum, :notify], _measurements, meta) do
    [
      tenant(meta, &Bus.notify/1, fn actor ->
        Notify.new(actor, meta[:kind], meta[:payload] || %{})
      end)
    ]
  end

  # The memo is a cached authorization decision held in each member's own
  # table, so the announcement is global: every member drops what it holds
  # for that session row key. The member that announced dropped its own
  # before the event fired.
  defp messages([:cyfr, :sanctum, :caller, :invalidated], _measurements, %{hash: key})
       when is_binary(key),
       do: [{:global, Bus.caller_invalidated_global(), CallerInvalidated.new(key)}]

  defp messages([:cyfr, :sanctum, :session, :created], _measurements, _meta),
    do: [{:global, Bus.sessions(), Session.new(:created)}]

  defp messages([:cyfr, :sanctum, :sessions, :revoked], _measurements, %{user_id: user_id})
       when is_binary(user_id),
       do: [{:global, Bus.sessions(), Session.new(:revoked, user_id)}]

  defp messages(
         [:cyfr, :sanctum, :membership, :changed],
         _measurements,
         %{user_id: user_id} = meta
       )
       when is_binary(user_id) and user_id != "" do
    membership = Membership.new(:changed, user_id, meta[:athanor_id], meta[:change])
    [{:global, Bus.memberships(user_id), membership}]
  end

  # Two topics, one announcement: the athanor's own, and the deliberately
  # global one the external-server reconciler reads because it cannot know
  # every tenant topic.
  defp messages([:cyfr, :sanctum, :vault, :entry_changed], _measurements, meta) do
    build = fn actor ->
      meta_fields = Map.take(meta[:meta] || %{}, [:name, :old_name])
      VaultEntryChanged.new(actor, meta[:verb], Map.put(meta_fields, :entry_id, meta[:entry_id]))
    end

    [
      tenant(meta, &Bus.vault_changed/1, build),
      tenant(meta, fn _actor -> Bus.vault_changed_global() end, build, :global)
    ]
  end

  defp messages([:cyfr, :sanctum, :athanor, :archived], _measurements, %{athanor_id: id})
       when is_binary(id) and id != "",
       do: [{:global, Bus.athanor_archived_global(), AthanorArchived.new(id)}]

  defp messages([:cyfr, :sanctum, :api_keys, :changed], _measurements, meta),
    do: [tenant(meta, &Bus.api_keys/1, &ApiKeys.new(&1, :changed))]

  defp messages([:cyfr, :sanctum, :webhooks, :changed], _measurements, meta),
    do: [tenant(meta, &Bus.webhooks/1, &Webhooks.new(&1, :changed))]

  # An event the roster names whose metadata lacks what its message needs.
  defp messages(_event, _measurements, _meta), do: [:dropped]

  defp execution(meta) do
    %{
      execution_id: meta[:execution_id],
      request_id: meta[:request_id],
      parent_execution_id: meta[:parent_execution_id],
      reference: meta[:reference] || meta[:component],
      component_type: meta[:component_type],
      duration_ms: meta[:duration_ms],
      error: meta[:error]
    }
  end

  defp schedule_run(meta),
    do: Map.take(meta, [:schedule_id, :occurrence_id, :execution_id, :reference, :reason])

  # The tray counts only root executions: a chain's children are the same
  # piece of work.
  defp root_notify(%{parent_execution_id: parent}, _kind) when not is_nil(parent), do: []

  defp root_notify(meta, kind) do
    [
      tenant(meta, &Bus.notify/1, fn actor ->
        Notify.new(actor, kind, Map.take(meta, [:execution_id, :reference]))
      end)
    ]
  end

  defp tenant(meta, topic, build, scope \\ :tenant) do
    case meta[:athanor_id] do
      athanor_id when is_binary(athanor_id) and athanor_id != "" ->
        actor = Prima.Actor.in_athanor(athanor_id)
        {scope, actor, topic.(actor), build}

      _none ->
        :dropped
    end
  end

  # ---------------------------------------------------------------------------
  # Delivery
  # ---------------------------------------------------------------------------

  defp deliver(event, :dropped) do
    :telemetry.execute([:cyfr, :bus, :bridge_dropped], %{count: 1}, %{event: event})
  end

  defp deliver(event, {:tenant, actor, topic, build}),
    do: publish(event, fn -> Bus.broadcast(actor, topic, build.(actor)) end)

  defp deliver(event, {:global, actor, topic, build}),
    do: publish(event, fn -> Bus.broadcast_global(topic, build.(actor)) end)

  defp deliver(event, {:global, topic, payload}),
    do: publish(event, fn -> Bus.broadcast_global(topic, payload) end)

  # A publish that fails — refused, or the PubSub raising — is logged and
  # contained here, one message at a time.
  defp publish(event, fun) do
    case fun.() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Cyfr.TelemetryBridge] #{inspect(event)} not published: #{inspect(reason)}"
        )
    end
  catch
    kind, reason ->
      Logger.warning(
        "[Cyfr.TelemetryBridge] #{inspect(event)} not published: " <>
          Exception.format_banner(kind, reason)
      )
  end
end
