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
  runs' attempts, then the Opus service's runners, then the event buffers
  they wrote to. Each child is stopped synchronously, so the sweep returns
  only once every child is gone. The Opus service's runners are OS
  processes, and their handles' supervisor (`Opus.RunnerPool.Runners`) is
  swept through the pool instead (`pooled/0`): every busy runner is ended
  at once and awaited (`Opus.RunnerPool.retire_busy/2`), fresh and idle
  ones stay pooled for the next test, and every report of a runner's exit
  the service has in flight is awaited (`Opus.WorkerService.await_reports/1`),
  so no runner's host call and no report lands after the owner is gone.
  Then the connections open on the listeners of the worker wire
  (`Cyfr.Test.OpusService.listeners/0`) are closed: a host call a stopped
  runner had in flight runs on one of them, and it must not reach the
  database after the owner is gone.

  `on_exit` callbacks run last-registered first. A test that restores
  configuration a background process reads (a base path, a seed path, the
  execution engine) calls `stop_work_on_exit/0` after registering those
  restores, so the work stops before the configuration it runs under moves.
  """

  # The Opus service is a sibling application, not a dependency.
  @compile {:no_warn_undefined, [Opus.RunnerPool, Opus.WorkerService]}

  @supervisors [
    Aqua.RunnerSupervisor,
    Aqua.TaskSupervisor,
    Emissary.TaskSupervisor,
    Grimoire.TaskSupervisor,
    Sanctum.ProvisioningSupervisor,
    Compendium.ProvisioningSupervisor,
    Crucible.Schedules.TaskSupervisor,
    Sanctum.OAuth.RefreshTaskSupervisor,
    Sanctum.TaskSupervisor,
    Crucible.TaskSupervisor,
    Compendium.Builds.TaskSupervisor,
    Emissary.External.ServerSupervisor,
    Crucible.Attempt.Supervisor,
    Opus.RunnerPool.Runners,
    Crucible.Events.Supervisor
  ]

  # Swept through the pool whose runners' handles it supervises, never by
  # stopping its children: a handle stopped kills its runner with no report.
  @pooled [Opus.RunnerPool.Runners]

  @doc "The supervisors a sync test's work is swept from, in the order they are stopped."
  @spec supervisors() :: [atom()]
  def supervisors, do: @supervisors

  @doc "The supervisors of `supervisors/0` swept through their pool rather than stopped."
  @spec pooled() :: [atom()]
  def pooled, do: @pooled

  @doc """
  Start this test's sandbox owner (shared unless the test is async), let
  the supervisors reach it, and stop the test's background work and then
  the owner when the test ends. Answers the owner pid.
  """
  @spec setup!(map()) :: pid()
  def setup!(tags \\ %{}) do
    shared? = not Map.get(tags, :async, false)
    # The owner protocol is the persistence layer's; what this adds is the
    # lending to the supervisors above it and the sweep of their children.
    owner = Arca.Test.Sandbox.start_owner!(tags)

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
      Enum.flat_map(@supervisors, fn name ->
        case Process.whereis(name) do
          nil -> []
          _supervisor when name in @pooled -> retire_runners()
          supervisor -> stop_children(supervisor)
        end
      end)

    close_connections()

    if stopped == [], do: :ok, else: stop_work(passes - 1)
  end

  defp stop_children(supervisor) do
    for {_, child, _, _} <- DynamicSupervisor.which_children(supervisor),
        is_pid(child),
        do: DynamicSupervisor.terminate_child(supervisor, child)
  end

  # The Opus service's busy runners are ended and awaited, then the reports
  # of their exits: answered as stopped work when there was any. A service
  # a test is restarting has no pool to ask, and its runners went with the
  # old one.
  defp retire_runners do
    busy = Opus.RunnerPool.status(Opus.RunnerPool).runners.busy
    :ok = Opus.RunnerPool.retire_busy(Opus.RunnerPool)
    :ok = Opus.WorkerService.await_reports()
    List.duplicate(:retired, busy)
  catch
    :exit, {:noproc, _call} -> []
  end

  # A connection process carries one request; killed, its caller sees a
  # lost answer, which a stopped runner no longer reads. Each kill is
  # awaited, so the sweep returns only once the request is gone.
  defp close_connections do
    for server <- Cyfr.Test.OpusService.listeners(),
        {:ok, connections} <- [ThousandIsland.connection_pids(server)],
        connection <- connections do
      ref = Process.monitor(connection)
      Process.exit(connection, :kill)

      receive do
        {:DOWN, ^ref, :process, ^connection, _reason} -> :ok
      end
    end

    :ok
  end
end
