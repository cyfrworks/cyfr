defmodule Prism.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PrismWeb.Telemetry,
      Prism.TelemetryBridge,
      Prism.SessionBridge.Store,
      PrismWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Prism.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    PrismWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
