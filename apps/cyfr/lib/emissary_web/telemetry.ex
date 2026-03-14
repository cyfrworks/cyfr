defmodule EmissaryWeb.Telemetry do
  @moduledoc """
  Telemetry metrics for Emissary MCP service.

  ## MCP Metrics

  - `cyfr.emissary.session.count` - Session lifecycle events
    - Tags: `:transport`, `:lifecycle` (created/terminated)

  - `cyfr.emissary.request.duration` - Request processing time
    - Tags: `:method`, `:tool`, `:status` (success/error)
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
    if Application.get_env(:cyfr, :prometheus_metrics_enabled, true) do
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
      counter("cyfr.emissary.session.count",
        tags: [:transport, :lifecycle],
        description: "MCP session lifecycle events (created/terminated)"
      ),
      distribution("cyfr.emissary.request.duration",
        tags: [:method, :tool, :status],
        unit: {:native, :millisecond},
        reporter_options: [buckets: [10, 50, 100, 250, 500, 1000, 2500, 5000]],
        description: "MCP request processing duration"
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
