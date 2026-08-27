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
      config :cyfr, :audit_sinks, [Arca.AuditSinks.Console]

      # With an additional SIEM sink configured:
      # config :cyfr, :audit_sinks, [Arca.AuditSinks.Console, Arca.AuditSinks.SIEM]

  ## Monitored Events

  - `[:cyfr, :sanctum, :auth]` — login success/failure
  - `[:cyfr, :opus, :execute, :start]` — execution begins
  - `[:cyfr, :opus, :execute, :stop]` — execution completes
  - `[:cyfr, :opus, :execute, :exception]` — execution fails
  - `[:cyfr, :opus, :secret, :accessed]` — a component read a credential
  - `[:cyfr, :opus, :secret, :denied]` — a component was refused one

  The full roster is `@audit_events`; this list names the shapes, not every
  entry.
  """

  use GenServer
  require Logger

  @audit_events [
    [:cyfr, :sanctum, :auth],
    # A release digest that no longer re-derives from its row is a tamper
    # signal — it belongs in the audit sinks, not only in the server log.
    [:cyfr, :sanctum, :consent, :integrity_alarm],
    # The widest grant in the system, and its only input is an email address —
    # under a generic OIDC issuer `email_verified` may legitimately be absent,
    # so the address is asserted rather than proven. Minting it must not be
    # silent.
    [:cyfr, :sanctum, :tenancy, :platform_admin_bootstrap],
    # The door: a refused sign-in and an operator's deny are both events an
    # operator wants to find later.
    [:cyfr, :sanctum, :door, :refused],
    [:cyfr, :sanctum, :door, :denied],
    [:cyfr, :opus, :execute, :start],
    [:cyfr, :opus, :execute, :stop],
    [:cyfr, :opus, :execute, :exception],
    # A component reaching an operator's credential — and being refused one —
    # is the event this product exists to make accountable. It was emitted
    # from `Opus.Runtime`'s vault import and consumed by nothing.
    [:cyfr, :opus, :secret, :accessed],
    [:cyfr, :opus, :secret, :denied]
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    attach_handlers()
    {:ok, %{}}
  end

  defp attach_handlers do
    for event <- @audit_events do
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
  # DETACHES any handler that raises — so an exception anywhere in here ends
  # auditing for that event, for the life of the node, silently. The
  # per-sink rescue below covers the sinks; this covers everything else
  # (context construction most of all, which validates and can raise).
  # `Cyfr.OtelTenantHandler` and `Prism.TelemetryBridge` take the same
  # precaution for the same reason.
  def handle_event(event_name, measurements, metadata, config) do
    do_handle_event(event_name, measurements, metadata, config)
  rescue
    e ->
      Logger.error(
        "[AuditHandler] handler raised for #{inspect(event_name)}: #{Exception.message(e)} — " <>
          "the event was not audited; the handler stays attached"
      )

      :telemetry.execute(
        [:cyfr, :audit, :pipeline_failure],
        %{count: 1},
        %{event: event_name}
      )

      :ok
  end

  defp do_handle_event(event_name, measurements, metadata, _config) do
    sinks = Application.get_env(:cyfr, :audit_sinks, [Arca.AuditSinks.Console])

    # Inject tenant context into metadata for downstream sinks
    metadata =
      if metadata[:context] do
        metadata
      else
        # An event that names its athanor is handled inside it; one that
        # doesn't (a platform-level event) gets a platform context.
        athanor_id = metadata[:athanor_id]

        ctx =
          Sanctum.internal_context(
            user_id: metadata[:user_id] || "system",
            athanor_id: athanor_id,
            scope: if(is_binary(athanor_id), do: :athanor, else: :platform)
          )

        Map.put(metadata, :context, ctx)
      end

    failure_count =
      Enum.count(sinks, fn sink ->
        try do
          sink.handle_audit_event(event_name, measurements, metadata)
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
    Logger.warning("#{__MODULE__}: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end
end
