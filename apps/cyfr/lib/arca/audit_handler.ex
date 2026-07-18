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
  - `[:cyfr, :sanctum, :policy]` — policy changes
  - `[:cyfr, :opus, :execute, :start]` — execution begins
  - `[:cyfr, :opus, :execute, :stop]` — execution completes
  - `[:cyfr, :opus, :execute, :exception]` — execution fails
  """

  use GenServer
  require Logger

  @audit_events [
    [:cyfr, :sanctum, :auth],
    [:cyfr, :sanctum, :policy],
    [:cyfr, :opus, :execute, :start],
    [:cyfr, :opus, :execute, :stop],
    [:cyfr, :opus, :execute, :exception]
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

      :telemetry.attach(
        event_id,
        event,
        &__MODULE__.handle_event/4,
        nil
      )
    end
  end

  def handle_event(event_name, measurements, metadata, _config) do
    sinks = Application.get_env(:cyfr, :audit_sinks, [Arca.AuditSinks.Console])

    # Inject tenant context into metadata for downstream sinks
    metadata =
      if metadata[:context] do
        metadata
      else
        ctx =
          Sanctum.Context.for_scheduled(
            metadata[:user_id] || "system",
            org_id: metadata[:org_id],
            project_id: metadata[:project_id]
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
