# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.Supervisor do
  @moduledoc """
  The gate's processes: the table of running calls and the task
  supervisor its handlers run on. `rest_for_one`, because every handler
  registers in `Grimoire.RunningTasks`: a fresh table restarts the
  handlers that were registered in the old one.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        # 5 s: its stop; the tables it owns go with it.
        Supervisor.child_spec(Grimoire.RunningTasks, shutdown: 5_000),
        # The gate's supervised handlers, after the table they register
        # in, so a shutdown stops them first. 30 s: the longest handler it
        # lets finish.
        Supervisor.child_spec(Grimoire.TaskSupervisor, shutdown: 30_000)
      ],
      strategy: :rest_for_one,
      max_restarts: 10,
      max_seconds: 60
    )
  end
end
