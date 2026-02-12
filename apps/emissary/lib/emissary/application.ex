defmodule Emissary.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      EmissaryWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:emissary, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Emissary.PubSub},
      # MCP tool registry (discovers and caches tool providers)
      Emissary.MCP.ToolRegistry,
      # MCP resource registry (discovers resource providers)
      Emissary.MCP.ResourceRegistry,
      # SSE event buffer (pub/sub for live event delivery)
      Emissary.MCP.SSEBuffer,
      # Start to serve requests, typically the last entry
      EmissaryWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Emissary.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EmissaryWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
