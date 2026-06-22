# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # NOTE: catalyst host-function HTTP (cyfr:http/fetch + /stream) no longer
      # uses a dedicated Finch pool. To pin the connection to the SSRF-validated
      # IP while preserving the original hostname for TLS SNI, the handlers pass
      # Req `connect_options: [hostname: ..., protocols: [:http1]]`, which is
      # mutually exclusive with a named Finch pool — Req manages per-host pools.
      # Guest HTTP concurrency is bounded by the execution semaphore and the
      # per-component rate limiter, not by a global pool size.
      #
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
      Opus.CronScheduler,
      # Periodic sweep to mark stale "running" executions as failed (replaces one-shot startup sweep)
      Opus.ExecutionSweeper
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    # ETS table for tracking OAuth tokens dispensed during execution (for SecretMasker)
    Opus.OAuthHandler.init_table()

    opts = [strategy: :one_for_one, name: Opus.Supervisor, max_restarts: 10, max_seconds: 60]
    Supervisor.start_link(children, opts)
  end
end