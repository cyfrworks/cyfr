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
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ] ++ maybe_console_reporter()

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp maybe_console_reporter do
    if Application.get_env(:emissary, :telemetry_console_enabled, false) do
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
      summary("cyfr.emissary.request.duration",
        tags: [:method, :tool, :status],
        unit: {:native, :millisecond},
        description: "MCP request processing duration"
      ),

      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
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
