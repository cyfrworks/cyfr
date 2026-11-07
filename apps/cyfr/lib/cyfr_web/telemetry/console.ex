# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Telemetry.Console do
  @moduledoc """
  The console reporter development runs (`:telemetry_console_enabled`):
  `Telemetry.Metrics.ConsoleReporter`'s report of each event, with the
  event's metadata passed through the redaction vocabulary every log
  shares (`Prima.Sanitizer.sanitize/1`) first. The reporter prints the
  metadata whole, and the endpoint's and LiveView's carry the connection
  and the session, the person's session token and cookie among them.

  The report is the reporter's own handler's, which is public but
  undocumented (`@doc false`); a `telemetry_metrics` that changes it fails
  `CyfrWeb.TelemetryTest`.
  """

  use GenServer

  alias Telemetry.Metrics.ConsoleReporter

  def start_link(opts) do
    GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :metrics))
  end

  @impl true
  def init(metrics) do
    Process.flag(:trap_exit, true)

    events =
      for {event, metrics} <- Enum.group_by(metrics, & &1.event_name) do
        :ok =
          :telemetry.attach(
            {__MODULE__, event, self()},
            event,
            &__MODULE__.handle_event/4,
            {metrics, :stdio}
          )

        event
      end

    {:ok, events}
  end

  @impl true
  def terminate(_reason, events) do
    for event <- events, do: :telemetry.detach({__MODULE__, event, self()})
    :ok
  end

  @doc false
  def handle_event(event, measurements, metadata, config) do
    metadata = Prima.Sanitizer.sanitize(metadata)
    ConsoleReporter.handle_event(event, measurements, metadata, config)
  end
end
