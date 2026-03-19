defmodule Opus.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    pool_size = Application.get_env(:cyfr, :http_pool_size, 25)

    children = [
      # HTTP connection pool for catalyst host-function requests
      {Finch,
       name: Opus.Finch, pools: %{default: [size: pool_size, count: 1, protocols: [:http1]]}},
      # Sliding window rate limiter for policy enforcement
      Opus.RateLimiter,
      # Shared Wasmex engine for compile-once/instantiate-many
      Opus.SharedEngine,
      # Counting semaphore to guard concurrent WASM execution memory
      {Opus.ExecutionSemaphore, max: Application.get_env(:cyfr, :max_concurrent_executions, 128)},
      # Process registry mapping execution_id -> task PID for cancellation
      {Registry, keys: :unique, name: Opus.ExecutionRegistry},
      # Registry + DynamicSupervisor for per-execution event buffer serialization
      {Registry, keys: :unique, name: Opus.ExecutionEventBuffer.Registry},
      {DynamicSupervisor, name: Opus.ExecutionEventBuffer.Supervisor, strategy: :one_for_one},
      # Supervised fire-and-forget tasks (run_stream, cron execution spawns)
      Supervisor.child_spec({Task.Supervisor, name: Opus.TaskSupervisor}, shutdown: 30_000),
      # Cron scheduler for recurring component executions
      Opus.CronScheduler
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Opus.Supervisor, max_restarts: 10, max_seconds: 60]
    result = Supervisor.start_link(children, opts)

    # One-time startup sweep to clean up stale "running" records from previous BEAM crashes.
    # Runs after supervisor is up so Arca.Repo (in cyfr app) is available.
    Task.start(fn ->
      Process.sleep(5_000)
      Opus.Executor.sweep_stale_on_startup()
    end)

    result
  end
end
