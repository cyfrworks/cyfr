# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Telemetry do
  @moduledoc """
  Telemetry metrics for Emissary MCP service.

  ## MCP Metrics

    - Tags: `:transport`, `:lifecycle` (created/terminated)

  - `cyfr.emissary.request.duration` - Request processing time
    - Tags: `:method`, `:tool`, `:status` (success/error/cancelled)
    - Unit: milliseconds

  """

  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children =
      [
        # Telemetry poller will execute the given period measurements
        # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
        {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      ] ++ maybe_prometheus_reporter() ++ maybe_console_reporter()

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp maybe_prometheus_reporter do
    if Application.get_env(:cyfr, :prometheus_metrics_enabled, false) do
      [{TelemetryMetricsPrometheus.Core, metrics: metrics(), name: :cyfr_prometheus}]
    else
      []
    end
  end

  defp maybe_console_reporter do
    if Application.get_env(:cyfr, :telemetry_console_enabled, false) do
      [{Telemetry.Metrics.ConsoleReporter, metrics: metrics()}]
    else
      []
    end
  end

  def metrics do
    [
      # MCP Metrics
      distribution("cyfr.emissary.request.duration",
        tags: [:method, :tool, :status],
        unit: {:native, :millisecond},
        reporter_options: [buckets: [10, 50, 100, 250, 500, 1000, 2500, 5000]],
        description: "MCP request processing duration"
      ),

      # Execution ingresses. Both were emitted and consumed by nothing —
      # two of the three credentialed run surfaces were un-metered.
      distribution("cyfr.emissary.webhook.invoke.stop.duration_ms",
        event_name: [:cyfr, :emissary, :webhook, :invoke, :stop],
        measurement: :duration_ms,
        tags: [:status],
        unit: :millisecond,
        reporter_options: [buckets: [10, 50, 100, 250, 500, 1000, 2500, 5000]],
        description: "Webhook invoke duration"
      ),
      counter("cyfr.emissary.webhook.verify_failed.count",
        event_name: [:cyfr, :emissary, :webhook, :verify_failed],
        tags: [:reason],
        description: "Webhook signature verification failures"
      ),
      distribution("cyfr.emissary.tincture.invoke.stop.duration_ms",
        event_name: [:cyfr, :emissary, :tincture, :invoke, :stop],
        measurement: :duration_ms,
        tags: [:status],
        unit: :millisecond,
        reporter_options: [buckets: [10, 50, 100, 250, 500, 1000, 2500, 5000]],
        description: "Tincture invoke duration (HTTP and console surfaces)"
      ),
      counter("cyfr.sanctum.policy.decision.count",
        event_name: [:cyfr, :sanctum, :policy, :decision],
        tags: [:decision],
        description: "Policy decisions"
      ),

      # Phoenix Metrics
      distribution("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [10, 50, 100, 250, 500, 1000]],
        description: "Phoenix endpoint request duration"
      ),
      distribution("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond},
        reporter_options: [buckets: [10, 50, 100, 250, 500, 1000]],
        description: "Phoenix router dispatch duration"
      ),
      # The Prism LiveViews mount on this endpoint.
      distribution("phoenix.live_view.mount.stop.duration",
        tags: [:view],
        unit: {:native, :millisecond},
        reporter_options: [buckets: [10, 50, 100, 250, 500, 1000]],
        description: "LiveView mount duration"
      ),
      distribution("phoenix.live_view.handle_event.stop.duration",
        tags: [:view, :event],
        unit: {:native, :millisecond},
        reporter_options: [buckets: [10, 50, 100, 250, 500, 1000]],
        description: "LiveView event duration"
      ),
      counter("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        description: "Phoenix router dispatch exceptions"
      ),
      sum("phoenix.socket_drain.count"),

      # VM Metrics
      last_value("vm.memory.total", unit: {:byte, :kilobyte}),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {EmissaryWeb, :count_users, []}
    ]
  end
end
