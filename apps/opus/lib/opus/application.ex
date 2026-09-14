# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # The execution implementation is configured before boot; this application manages readiness.
    children = [
      # Shared Wasmex engine for compile-once/instantiate-many. The engine
      # admits work only once it is up (`Opus.ready?/0`).
      Opus.SharedEngine,
      # Supervised fire-and-forget tasks (run_stream)
      Supervisor.child_spec({Task.Supervisor, name: Opus.TaskSupervisor}, shutdown: 30_000),
      # Periodic sweep that marks stale "running" executions failed.
      Opus.ExecutionSweeper,
      # Owns the :protected ETS table of OAuth tokens dispensed to guests (for
      # SecretMasker); sweeps tokens from runs that never drained.
      Opus.OAuthTokenTracker
    ]

    opts = [strategy: :one_for_one, name: Opus.Supervisor, max_restarts: 10, max_seconds: 60]
    Supervisor.start_link(children, opts)
  end
end
