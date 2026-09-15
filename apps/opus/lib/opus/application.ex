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
      # Supervised fire-and-forget tasks: an in-chain streamed child
      # (`execution.run_stream` from a formula) and a guest's streaming HTTP
      # request.
      Supervisor.child_spec({Task.Supervisor, name: Opus.TaskSupervisor}, shutdown: 30_000),
      # The worker service and the runners it starts. They restart together:
      # a restarted service has a new boot id and monitors none of the old
      # runners, so they go with it.
      %{
        id: Opus.WorkerService.Tree,
        type: :supervisor,
        start:
          {Supervisor, :start_link,
           [
             [
               {DynamicSupervisor, name: Opus.WorkerService.Runners, strategy: :one_for_one},
               Opus.WorkerService
             ],
             [strategy: :one_for_all, name: Opus.WorkerService.Tree]
           ]}
      }
    ]

    opts = [strategy: :one_for_one, name: Opus.Supervisor, max_restarts: 10, max_seconds: 60]
    Supervisor.start_link(children, opts)
  end
end
