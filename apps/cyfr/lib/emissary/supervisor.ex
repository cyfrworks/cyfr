# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Supervisor do
  @moduledoc """
  The MCP surface's processes: the external-server tree and the task
  supervisor its calls run on. `one_for_one`, because the two are
  independent: the server tree restarts its own dependents, and neither
  holds a reference into the other.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        # The external-server registry, servers and reconciler restart from
        # the registry down: a failure restarts its dependents. The programs
        # controller a stdio server releases its owner through is Opus's
        # (`Opus.Programs`), started before this tree and stopped after it.
        # The reconciler's 5 s is its stop, which holds no work in flight.
        %{
          id: Emissary.External.ServerTree,
          start:
            {Supervisor, :start_link,
             [
               [
                 {Registry, keys: :unique, name: Emissary.External.ServerRegistry},
                 {DynamicSupervisor,
                  name: Emissary.External.ServerSupervisor, strategy: :one_for_one},
                 Supervisor.child_spec(Emissary.External.Reconciler, shutdown: 5_000)
               ],
               [
                 strategy: :rest_for_one,
                 name: Emissary.External.ServerTree,
                 max_restarts: 10,
                 max_seconds: 60
               ]
             ]},
          type: :supervisor
        },
        # 30 s: the longest MCP call it lets finish.
        Supervisor.child_spec({Task.Supervisor, name: Emissary.TaskSupervisor}, shutdown: 30_000)
      ],
      strategy: :one_for_one,
      max_restarts: 10,
      max_seconds: 60
    )
  end
end
