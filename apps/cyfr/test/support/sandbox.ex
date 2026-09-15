# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.Sandbox do
  @moduledoc """
  The database sandbox for one test, and the end of the work that test
  started.

  `setup!/1` starts a sandbox owner of its own — not the test process — so
  work the test leaves behind (a thread runner finishing a turn, a
  provisioning fill, a run's attempt, a task on any supervisor below)
  still has a connection while it is stopped, and stops it before the
  owner goes. A sync test runs in shared mode and alone, so everything on
  those supervisors is its own and is stopped when it ends; an async test
  shares the supervisors with its neighbours, so nothing is swept for it
  and it must not leave work running.

  The supervisors are every dynamic supervisor the applications of this
  repository start (`supervisors/0`, pinned by `Cyfr.Test.SandboxTest`),
  stopped in order: what starts work before the work it started — runners
  (whose loops die with them), then the tasks that wait on runs, then the
  runs' attempts and runners, then the event buffers they wrote to. Each
  child is stopped synchronously, so the sweep returns only once every
  child is gone.

  `on_exit` callbacks run last-registered first. A test that restores
  configuration a background process reads (a base path, a seed path, the
  execution engine) calls `stop_work_on_exit/0` after registering those
  restores, so the work stops before the configuration it runs under moves.
  """

  @supervisors [
    Aqua.RunnerSupervisor,
    Aqua.TaskSupervisor,
    Emissary.TaskSupervisor,
    Sanctum.ProvisioningSupervisor,
    Cyfr.Schedules.TaskSupervisor,
    Sanctum.OAuth.RefreshTaskSupervisor,
    Cyfr.Execution.TaskSupervisor,
    Opus.TaskSupervisor,
    Locus.TaskSupervisor,
    Emissary.MCP.ExternalServerSupervisor,
    Cyfr.Execution.Attempt.Supervisor,
    Opus.WorkerService.Runners,
    Cyfr.Execution.Events.Supervisor
  ]

  @doc "The supervisors a sync test's work is swept from, in the order they are stopped."
  @spec supervisors() :: [atom()]
  def supervisors, do: @supervisors

  @doc """
  Start this test's sandbox owner (shared unless the test is async), let
  the supervisors reach it, and stop the test's background work and then
  the owner when the test ends. Answers the owner pid.
  """
  @spec setup!(map()) :: pid()
  def setup!(tags \\ %{}) do
    shared? = not Map.get(tags, :async, false)
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Arca.Repo, shared: shared?)
    ExUnit.Callbacks.on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    unless shared?, do: Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, owner, self())

    for name <- @supervisors, pid = Process.whereis(name), is_pid(pid) do
      Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, owner, pid)
    end

    if shared?, do: stop_work_on_exit()
    owner
  end

  @doc """
  Register, as the next `on_exit` to run, the stop of every child of the
  supervisors a test's work runs on. For sync tests only.
  """
  @spec stop_work_on_exit() :: :ok
  def stop_work_on_exit, do: ExUnit.Callbacks.on_exit(&stop_work/0)

  # A child stopped can take work it started that the pass already walked
  # past (a runner's loop is killed as the runner ends): passes repeat, at
  # most three, until one finds nothing left.
  defp stop_work(passes \\ 3)

  defp stop_work(0), do: :ok

  defp stop_work(passes) do
    stopped =
      for name <- @supervisors,
          supervisor = Process.whereis(name),
          is_pid(supervisor),
          {_, child, _, _} <- DynamicSupervisor.which_children(supervisor),
          is_pid(child) do
        DynamicSupervisor.terminate_child(supervisor, child)
      end

    if stopped == [], do: :ok, else: stop_work(passes - 1)
  end
end
