defmodule Opus.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Sliding window rate limiter for policy enforcement
      Opus.RateLimiter,
      # Counting semaphore to prevent dirty scheduler exhaustion from concurrent WASM executions
      {Opus.ExecutionSemaphore, max: Application.get_env(:opus, :max_concurrent_executions, System.schedulers_online() * 2)}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Opus.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
