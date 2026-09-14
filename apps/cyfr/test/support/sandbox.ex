# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.Sandbox do
  @moduledoc """
  The database sandbox for one test, and the end of the work that test
  started.

  `setup!/1` starts a sandbox owner of its own — not the test process — so
  work the test leaves behind (a thread runner finishing a turn, a
  provisioning fill, a task on one of the supervisors below) still has a
  connection while it is stopped, and stops it before the owner goes. A
  sync test runs in shared mode and alone, so everything on those
  supervisors is its own and is stopped when it ends; an async test shares
  the supervisors with its neighbours, so nothing is swept for it and it
  must not leave work running.

  `on_exit` callbacks run last-registered first. A test that restores
  configuration a background process reads (a base path, a seed path, the
  execution engine) calls `stop_work_on_exit/0` after registering those
  restores, so the work stops before the configuration it runs under moves.
  """

  @task_supervisors [
    Aqua.TaskSupervisor,
    Emissary.TaskSupervisor,
    Sanctum.ProvisioningSupervisor,
    Cyfr.Schedules.TaskSupervisor
  ]

  @doc """
  Start this test's sandbox owner (shared unless the test is async), let
  the task supervisors reach it, and stop the test's background work and
  then the owner when the test ends. Answers the owner pid.
  """
  @spec setup!(map()) :: pid()
  def setup!(tags \\ %{}) do
    shared? = not Map.get(tags, :async, false)
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Arca.Repo, shared: shared?)
    ExUnit.Callbacks.on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    unless shared?, do: Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, owner, self())

    for name <- @task_supervisors, pid = Process.whereis(name), is_pid(pid) do
      Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, owner, pid)
    end

    if shared?, do: stop_work_on_exit()
    owner
  end

  @doc """
  Register, as the next `on_exit` to run, the stop of every runner and every
  task on the supervisors a test's work runs on. For sync tests only.
  """
  @spec stop_work_on_exit() :: :ok
  def stop_work_on_exit, do: ExUnit.Callbacks.on_exit(&stop_work/0)

  # Runners first: a runner outliving its tasks would record their deaths.
  defp stop_work do
    if is_pid(Process.whereis(Aqua.RunnerSupervisor)) do
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Aqua.RunnerSupervisor),
          is_pid(pid) do
        DynamicSupervisor.terminate_child(Aqua.RunnerSupervisor, pid)
      end
    end

    for name <- @task_supervisors,
        is_pid(Process.whereis(name)),
        child <- Task.Supervisor.children(name) do
      Task.Supervisor.terminate_child(name, child)
    end

    :ok
  end
end
