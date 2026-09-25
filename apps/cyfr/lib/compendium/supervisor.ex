# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Supervisor do
  @moduledoc """
  The component domain's processes: the builds' and the estate fills'
  task supervisors, the estate filler and the projection reconciler.
  `one_for_one`, because none of them holds a reference into another: each
  restarts alone.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        # Builds (`Compendium.Builds`): a started build, the process watching
        # it, each request to the Locus builds service and the registration
        # after it. After the catalog, the bus and the bookkeeping they write
        # through, so a shutdown ends the builds before them; a build it ends
        # publishes nothing. 30 s: the longest build step it lets finish.
        Supervisor.child_spec({Task.Supervisor, name: Compendium.Builds.TaskSupervisor},
          shutdown: 30_000
        ),
        # Filling an athanor's component estate: the background fills the
        # first-need hook and a sign-in ask for, and the registry pulls each
        # attempt runs under its own deadline. 30 s: the longest fill step
        # it lets finish.
        Supervisor.child_spec({Task.Supervisor, name: Compendium.ProvisioningSupervisor},
          shutdown: 30_000
        ),
        # The estate filler itself — it reacts to the identity domain's
        # announcement that an athanor needs filling. 5 s: its stop, which
        # holds no work in flight.
        Supervisor.child_spec(Compendium.Provisioning, shutdown: 5_000),
        # The registry and the agent index follow the seeded roots' changes:
        # it reconciles the estate a change names, and recovers every estate
        # a root is behind in once started and on every tick this member
        # holds its slot. Every read passes its own barrier, so nothing
        # waits on this child to be right. 5 s: its terminate detaching
        # its handler.
        Supervisor.child_spec(Compendium.ProjectionReconciler, shutdown: 5_000)
      ],
      strategy: :one_for_one,
      max_restarts: 10,
      max_seconds: 60
    )
  end
end
