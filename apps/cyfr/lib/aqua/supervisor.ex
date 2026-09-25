# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Supervisor do
  @moduledoc """
  The assistant's processes: the schedule notes, the loop worker with the
  task supervisor its steps run on, and the thread runners with their
  recovery. `rest_for_one`, because the loops run their steps on
  `Aqua.TaskSupervisor`: a fresh worker tree restarts the runners whose
  loops held the old one.

  Options, given by the composition root, which reads the configuration:
  `thread_recovery` (whether the runners of the threads holding an open
  turn are started once the tree is up).
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Supervisor.init(
      [
        # Keeps a completed schedule's outcome as a note when the schedule
        # asked for it: subscribed to the committed completions before the
        # scheduler can fire, and acting only on its own member's.
        Aqua.ScheduleNotes,
        group(Aqua.WorkerTree, [
          Aqua.Loop.Worker,
          {Task.Supervisor, name: Aqua.TaskSupervisor}
        ]),
        # Thread runners: one process per thread with open turns, started on
        # demand; the recovery task starts one for every thread holding an
        # open turn when the server last stopped. It is transient, so it
        # stays listed once it has run and runs again whenever the group
        # restarts over a fresh, empty runner supervisor. The registry
        # names each runner by its thread and each loop by the root turn it
        # holds (`Aqua.Loop.holder/1`). Registry and the supervisor whose
        # children register in it restart together; a runner's loop dies
        # with the runner.
        group(Aqua.RunnerTree, [
          {Registry, keys: :unique, name: Aqua.RunnerRegistry},
          {DynamicSupervisor, name: Aqua.RunnerSupervisor, strategy: :one_for_one}
          | thread_recovery(Keyword.fetch!(opts, :thread_recovery))
        ])
      ],
      strategy: :rest_for_one,
      max_restarts: 10,
      max_seconds: 60
    )
  end

  # Off in the test env: suites drive runners directly.
  defp thread_recovery(true) do
    [
      Supervisor.child_spec(
        {Task, &Aqua.Runner.recover_all/0},
        id: Aqua.RunnerRecovery,
        restart: :transient
      )
    ]
  end

  defp thread_recovery(false), do: []

  # A registry and the processes that hold references into it restart
  # together: :rest_for_one from the registry (or table owner) down, so a
  # restart never leaves dependents holding a name that resolves to
  # nothing.
  defp group(name, children) do
    %{
      id: name,
      start:
        {Supervisor, :start_link,
         [children, [strategy: :rest_for_one, name: name, max_restarts: 10, max_seconds: 60]]},
      type: :supervisor
    }
  end
end
