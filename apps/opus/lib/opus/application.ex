# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # The nonces the worker listener has seen, owned by the application so
    # a listener or service restart forgets none within the header window.
    :ok = Opus.WorkerListener.init_nonces()

    children = [
      # Shared Wasmex engine for compile-once/instantiate-many.
      Opus.SharedEngine,
      # The engine's disposable state: compiled components and open streams.
      Opus.Cache,
      # Supervised fire-and-forget tasks: a guest's streaming HTTP request.
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
      },
      # Where CYFR reaches the worker service, on the address its
      # credentials name. Started after the service, so a request never
      # finds it absent.
      listener()
    ]

    opts = [strategy: :one_for_one, name: Opus.Supervisor, max_restarts: 10, max_seconds: 60]
    Supervisor.start_link(children, opts)
  end

  # The credentials are loaded by the worker service, which refuses the
  # boot when they are missing or malformed; the listener reads the same.
  defp listener do
    %Opus.Credentials{bind: bind, port: port} = Opus.Credentials.load!()

    Supervisor.child_spec({Bandit, plug: Opus.WorkerListener, ip: bind, port: port},
      id: Opus.WorkerListener
    )
  end
end
