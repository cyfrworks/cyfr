defmodule Compendium.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Finch, name: Compendium.Finch}
      # AutoIndexer is not started automatically — registration is manual
      # via the component.register MCP action or Compendium.AutoIndexer.rescan/1
    ]

    # Initialize OCI auth token cache
    Compendium.OCI.Auth.init_cache()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Compendium.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
