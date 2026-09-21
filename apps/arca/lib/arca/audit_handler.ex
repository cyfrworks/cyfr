# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.AuditHandler do
  @moduledoc """
  Telemetry consumer that dispatches security-relevant events to audit sinks.

  Attaches to existing telemetry events at startup and forwards them to
  all configured `Arca.AuditSink` implementations. Each sink is wrapped
  in try/rescue for fault isolation — a failing sink cannot break other
  sinks or the telemetry pipeline.

  ## Configuration

      # config.exs (default):
      config :arca, :audit_sinks, [Arca.AuditSinks.Console]

      # With an additional SIEM sink configured:
      # config :arca, :audit_sinks, [Arca.AuditSinks.Console, Arca.AuditSinks.SIEM]

  ## Monitored Events

  - `[:cyfr, :sanctum, :auth]` — login success/failure
  - `[:cyfr, :opus, :execute, :start]` — execution begins
  - `[:cyfr, :opus, :execute, :stop]` — execution completes
  - `[:cyfr, :opus, :execute, :exception]` — execution fails
  - `[:cyfr, :opus, :secret, :dispensed]` — CYFR handed a runner a vault
    field of its run's consented projection, at the attach that claimed
    the run's attempt: one entry per field, by name, never its value
  - `[:cyfr, :opus, :secret, :denied]` — a runner reported its guest was
    refused a field outside that projection, by the name the guest asked
    for

  Both carry the identity of the attempt CYFR verified (`athanor_id`,
  `user_id`, `execution_id`, `attempt`, `fence`, `component_ref`,
  `consent_id`, the claiming `runner`, the worker `service`) and the
  `field`; a guest's own reads happen inside its runner, where nothing of
  this VM's telemetry reaches, so the trail records what CYFR dispensed
  and what a runner reported, which is what CYFR can know.
  - `[:cyfr, :sanctum, :platform_context]` — the tenant-bypassing platform
    scope was constructed

  This list names the shapes, not every entry: the full roster is the one
  the boot hands `start_link/1`. Each event reaches the sinks as one
  `Arca.Audit.Event` with the emitter's metadata sanitized.

  ## The roster

  Which events are audited is not this module's to know. The telemetry
  catalog names each event's consumers, and an event is audited exactly
  when `:audit` is among them — so the boot reads the catalog and hands
  the answer here as the required `:events` option. The roster is
  settled at start rather than at compile time: the storage layer builds
  against the contracts alone and never names the catalog, and a restart
  re-reads it.

  `:events` is required, with no default. An empty roster attaches
  nothing and audits nothing, and it does so silently — exactly the
  shape of failure an audit trail must not have — so a boot that omits
  it fails to start instead.

  (The catalog's notes say why each entry earns its place, including why
  `:platform_context` is safe to subscribe: this handler constructs no
  context of its own, so the emit inside the platform-scope constructor
  cannot recurse through here.)
  """

  use GenServer
  require Logger

  @doc """
  Start the handler on the roster `opts[:events]` names. No default: the
  roster is the caller's to supply (see the moduledoc).
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    events = Keyword.fetch!(opts, :events)
    attach_handlers(events)
    {:ok, %{events: events}}
  end

  @doc "The roster this handler was started with, and is attached to."
  @spec events() :: [[atom()]]
  def events, do: GenServer.call(__MODULE__, :events)

  @impl true
  def handle_call(:events, _from, state), do: {:reply, state.events, state}

  defp attach_handlers(events) do
    for event <- events do
      event_id = "audit-" <> Enum.join(event, "-")

      # Detaching first makes the call idempotent across application restarts
      # in iex `:application.stop/start` cycles. Errors from detach when no
      # handler is attached are explicitly safe per :telemetry docs.
      _ = :telemetry.detach(event_id)

      :telemetry.attach(
        event_id,
        event,
        &__MODULE__.handle_event/4,
        nil
      )
    end
  end

  # `:telemetry` runs handlers in the emitting process and permanently
  # DETACHES any handler that fails — a raise, an exit (a store call timing
  # out arrives as one), a throw — so a failure anywhere in here ends
  # auditing for that event, for the life of the node, silently. The
  # per-sink rescue below covers the sinks; this covers everything else,
  # every class (context construction most of all, which validates and
  # can raise). `Cyfr.OtelTenantHandler` and `Prism.TelemetryBridge` take
  # the same precaution for the same reason.
  def handle_event(event_name, measurements, metadata, config) do
    do_handle_event(event_name, measurements, metadata, config)
  catch
    kind, reason ->
      Logger.error(
        "[AuditHandler] handler failed for #{inspect(event_name)}: " <>
          Exception.format_banner(kind, reason) <>
          " — the event was not audited; the handler stays attached"
      )

      :telemetry.execute(
        [:cyfr, :audit, :pipeline_failure],
        %{count: 1},
        %{event: event_name}
      )

      :ok
  end

  defp do_handle_event(event_name, measurements, metadata, _config) do
    sinks = Application.get_env(:arca, :audit_sinks, [Arca.AuditSinks.Console])

    # One struct per event, metadata sanitized on the way out — an
    # operator-added SIEM sink must never see a credential that rode an
    # emitter's metadata. Identity fields are audit content and survive.
    # No Sanctum context is constructed here (see the roster note on
    # :platform_context — doing so would recurse), and none is needed:
    # no sink read one.
    event = %Arca.Audit.Event{
      name: event_name,
      measurements: measurements,
      metadata: Cyfr.Sanitizer.sanitize(metadata),
      user_id: metadata[:user_id],
      athanor_id: metadata[:athanor_id]
    }

    failure_count =
      Enum.count(sinks, fn sink ->
        try do
          sink.handle_audit_event(event)
          false
        rescue
          e ->
            Logger.warning("[AuditHandler] Sink #{inspect(sink)} failed: #{Exception.message(e)}")
            true
        end
      end)

    if failure_count == length(sinks) and sinks != [] do
      Logger.error(
        "[AuditHandler] All #{failure_count} audit sinks failed for #{inspect(event_name)}"
      )

      :telemetry.execute(
        [:cyfr, :audit, :pipeline_failure],
        %{count: 1},
        %{event: event_name}
      )
    end

    :ok
  end

  @impl true
  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end
end
