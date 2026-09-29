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
  they wrote to, then the decision log's writers, which work at every tier
  starts. Each child is stopped synchronously, so the sweep returns
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

  Every process the test spawned is ended before the owner goes too, sync
  or async: a process whose parent, callers or ancestors lead back to the
  test process (`descendants/2`), however it was started — a bare `spawn`,
  a `Task`, a task a supervisor above runs on the test's behalf — is
  killed and awaited, unless it is registered under a name, which makes it
  a service rather than the test's work, or the test started it before its
  sandbox, which makes it scaffolding the test means to outlive it. A sync
  test's sweep does this first and again on every pass; an async test's
  does only this, since the supervisors are its neighbours' too.

  `on_exit` callbacks run last-registered first. A test that restores
  configuration a background process reads (a base path, a seed path, the
  execution engine) calls `stop_work_on_exit/0` after registering those
  restores, so the work stops before the configuration it runs under moves.

  A process that reaches the database after its owner has gone crashes
  with `DBConnection.OwnershipError`. Every such line logged at error level
  or above, from the first `setup!/1` on, is kept with the sandboxed tests
  running when it arrived; once the suite ends they are printed, and a
  line of a sandboxed test outside the exact roster of known offenders
  fails the run (`watch_ownership!/0`). A refusal a test provokes and the
  code handles is logged below error level and is not counted.
  """

  # The Opus service is a sibling application, not a dependency.
  @compile {:no_warn_undefined, [Opus.RunnerPool, Opus.WorkerService]}

  @supervisors [
    Aqua.RunnerSupervisor,
    Aqua.TaskSupervisor,
    Prism.TaskSupervisor,
    Emissary.TaskSupervisor,
    Emissary.Web.TaskSupervisor,
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
    Crucible.Events.Supervisor,
    Arca.DecisionLog.Writers
  ]

  # Swept through the pool whose runners' handles it supervises, never by
  # stopping its children: a handle stopped kills its runner with no report.
  @pooled [Opus.RunnerPool.Runners]

  # Where the test process keeps what its sweeps spare: its sandbox owner
  # and what it started before the sandbox.
  @spared {__MODULE__, :spared}

  # The ownership watch: its keeper's name, the lines it kept and the tests
  # running when they arrived.
  @watch __MODULE__.OwnershipWatch
  @lines :cyfr_test_ownership_lines
  @running :cyfr_test_sandbox_running

  # Sandboxed tests whose own end loses the connection under work they
  # started: a LiveView or request process linked to the test process dies
  # with it, before any `on_exit` runs, while it holds the shared
  # connection, and the work it started (a turn's host calls and runner
  # reports, a decision-log writer, a provisioning task) then finds no
  # owner. No sweep runs early enough; a module leaves this roster when its
  # test ends that work itself.
  @known_offenders %{
    PrismWeb.AquaPanelLiveTest =>
      "the panel's turn outlives the LiveView that died with the test",
    PrismWeb.ChatLiveTest => "the chat's turns outlive the LiveViews that died with the test",
    PrismWeb.SignInTraceTest => "the sign-in's work outlives the request that died with the test"
  }

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
    watch_ownership!()
    running!(tags)
    # What the test started before its sandbox is scaffolding it means to
    # outlive it (a collector its `on_exit` reads), not work under the owner.
    before = descendants(self())
    # The owner protocol is the persistence layer's; what this adds is the
    # lending to the supervisors above it and the sweep of their children.
    owner = Arca.Test.Sandbox.start_owner!(tags)
    :ets.update_element(@running, self(), {3, owner})
    # The owner is the test's child too, and the one it must keep.
    spared = [owner | before]
    Process.put(@spared, spared)

    for name <- @supervisors, pid = Process.whereis(name), is_pid(pid) do
      Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, owner, pid)
    end

    if shared? do
      stop_work_on_exit()
    else
      test = self()
      ExUnit.Callbacks.on_exit(fn -> stop_descendants(test, spared) end)
    end

    owner
  end

  @doc """
  Register, as the next `on_exit` to run, the stop of every child of the
  supervisors a test's work runs on. For sync tests only.
  """
  @spec stop_work_on_exit() :: :ok
  def stop_work_on_exit do
    test = self()
    spared = Process.get(@spared, [])
    ExUnit.Callbacks.on_exit(fn -> stop_work(test, spared) end)
  end

  # A child stopped can take work it started that the pass already walked
  # past (a runner's loop is killed as the runner ends): passes repeat, at
  # most three, until one finds nothing left. The test's own processes go
  # first on every pass, so none of them starts work behind the sweep.
  defp stop_work(test, spared, passes \\ 3)

  defp stop_work(_test, _spared, 0), do: :ok

  defp stop_work(test, spared, passes) do
    sweeping(test)
    ended = stop_descendants(test, spared)

    stopped =
      Enum.flat_map(@supervisors, fn name ->
        case Process.whereis(name) do
          nil -> []
          _supervisor when name in @pooled -> retire_runners()
          supervisor -> stop_children(supervisor)
        end
      end)

    close_connections()

    if stopped == [] and ended == [], do: :ok, else: stop_work(test, spared, passes - 1)
  end

  @doc """
  Every live process that leads back to `test` — through its parent, its
  `$callers` or its `$ancestors`, transitively — and is registered under
  no name. The test process itself is not among them, nor are the `spared`
  (the sandbox owner, what the test started before its sandbox) or
  anything that leads back only through them.
  """
  @spec descendants(pid(), [pid()]) :: [pid()]
  def descendants(test, spared \\ []) when is_pid(test) and is_list(spared) do
    lineage =
      for pid <- Process.list(),
          pid != self(),
          pid not in spared,
          from = lineage(pid),
          from != nil,
          do: {pid, from}

    lineage
    |> reach(MapSet.new([test]))
    |> MapSet.delete(test)
    |> Enum.filter(&(Process.info(&1, :registered_name) == {:registered_name, []}))
  end

  # The pids a process names as where it came from, or nil once it is gone.
  defp lineage(pid) do
    case Process.info(pid, [:parent, :dictionary]) do
      [parent: parent, dictionary: dictionary] ->
        from =
          Keyword.get(dictionary, :"$callers", []) ++ Keyword.get(dictionary, :"$ancestors", [])

        Enum.filter([parent | from], &is_pid/1)

      nil ->
        nil
    end
  end

  # The closure of `reached` over the lineage: passes repeat until one adds
  # nobody, so a grandchild counts however the list is ordered.
  defp reach(lineage, reached) do
    grown =
      for {pid, from} <- lineage,
          not MapSet.member?(reached, pid),
          Enum.any?(from, &MapSet.member?(reached, &1)),
          reduce: reached,
          do: (acc -> MapSet.put(acc, pid))

    if MapSet.size(grown) == MapSet.size(reached), do: reached, else: reach(lineage, grown)
  end

  # Killed, not asked: a process the test left behind has no one to answer
  # a shutdown to. Each kill is awaited, so the owner outlives them all.
  defp stop_descendants(test, spared) do
    sweeping(test)

    for pid <- descendants(test, spared) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> pid
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Ownership errors
  # ---------------------------------------------------------------------------

  @doc """
  Watch the log for `DBConnection.OwnershipError` at error level or above,
  once per run: a `:logger` handler keeps each such line with the
  sandboxed tests running when it arrived, and an `after_suite` callback
  prints every line and fails the run for any line a sandboxed test
  outside `known_offenders/0` was running for. A line logged while no
  sandboxed test runs comes from a test that checks the sandbox out
  itself, whose owner is its own process; it is printed, and those tests
  answer for it. Idempotent; `setup!/1` calls it.
  """
  @spec watch_ownership!() :: :ok
  def watch_ownership! do
    case Process.whereis(@watch) do
      nil -> start_watch()
      _keeper -> :ok
    end
  end

  @doc """
  The sandboxed test modules whose ownership lines do not fail the run,
  each with its reason. Exact: a module that no longer logs one leaves.
  """
  @spec known_offenders() :: %{module() => String.t()}
  def known_offenders, do: @known_offenders

  # The tables outlive every test: their keeper is registered, unlinked,
  # and so never swept.
  defp start_watch do
    parent = self()

    {keeper, ref} =
      spawn_monitor(fn ->
        try do
          Process.register(self(), @watch)
          :ets.new(@lines, [:named_table, :public, :duplicate_bag])
          :ets.new(@running, [:named_table, :public, :set])
          send(parent, {@watch, :ready})
          Process.sleep(:infinity)
        rescue
          ArgumentError -> send(parent, {@watch, :raced})
        end
      end)

    receive do
      {@watch, :ready} ->
        Process.demonitor(ref, [:flush])
        :ok = :logger.add_handler(@watch, __MODULE__, %{level: :error})
        ExUnit.after_suite(&report_ownership/1)

      {@watch, :raced} ->
        Process.demonitor(ref, [:flush])

      {:DOWN, ^ref, :process, ^keeper, reason} ->
        raise "the ownership watch did not start: #{inspect(reason)}"
    end

    :ok
  end

  # The tests a line arriving now is attributed to, each with its owner and
  # whether its sweep has begun: added as its sandbox is set up and removed
  # once its owner has gone (registered before the owner's stop, so it
  # runs after it).
  defp running!(tags) do
    test = self()
    module = Map.get(tags, :module)

    :ets.insert(
      @running,
      {test, {module, "#{inspect(module)} #{Map.get(tags, :test)}"}, nil, :test}
    )

    ExUnit.Callbacks.on_exit(fn -> :ets.delete(@running, test) end)
  end

  # A test that checks the sandbox out itself may register the sweep before
  # any sandbox started the watch; it has no entry to mark.
  defp sweeping(test) do
    if :ets.whereis(@running) != :undefined,
      do: :ets.update_element(@running, test, {4, :sweep})

    :ok
  end

  defp running do
    for {_test, {module, name}, owner, phase} <- :ets.tab2list(@running) do
      cond do
        owner == nil -> {module, "#{name} (before its owner)"}
        not Process.alive?(owner) -> {module, "#{name} (after its owner)"}
        phase == :sweep -> {module, "#{name} (in its sweep)"}
        true -> {module, name}
      end
    end
  end

  @doc false
  # The `:logger` handler callback, run in the process that logged.
  @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
  def log(event, _config) do
    text = render(event)

    if String.contains?(text, "DBConnection.OwnershipError") do
      :ets.insert(@lines, {System.monotonic_time(), text, running()})
    end

    :ok
  rescue
    # The watch never takes the logger down with it.
    _ -> :ok
  end

  defp render(%{msg: {:string, chardata}}), do: IO.chardata_to_string(chardata)

  defp render(%{msg: {:report, report}, meta: %{report_cb: callback}})
       when is_function(callback, 1) do
    {format, args} = callback.(report)
    render_format(format, args)
  end

  defp render(%{msg: {:report, report}}),
    do: inspect(report, limit: :infinity, printable_limit: :infinity)

  defp render(%{msg: {format, args}}), do: render_format(format, args)

  defp render_format(format, args),
    do: format |> :io_lib.format(args) |> IO.chardata_to_string()

  defp verdict([]), do: :outside

  defp verdict(running) do
    if Enum.all?(running, fn {module, _name} -> Map.has_key?(@known_offenders, module) end),
      do: :known,
      else: :new
  end

  defp report_ownership(_result) do
    lines =
      for {at, text, running} <- @lines |> :ets.tab2list() |> Enum.sort(),
          do: {at, text, running, verdict(running)}

    if lines != [] do
      new = Enum.count(lines, &(elem(&1, 3) == :new))

      IO.puts(
        :stderr,
        "\n** #{length(lines)} DBConnection.OwnershipError line(s) were logged, #{new} new:"
      )

      for {_at, text, running, verdict} <- lines do
        names = Enum.map_join(running, "; ", &elem(&1, 1))

        heading =
          case verdict do
            :new -> "NEW, while running: #{names}"
            :known -> "known offender, while running: #{names}"
            :outside -> "while no sandboxed test ran (a test that checks the sandbox out itself)"
          end

        IO.puts(:stderr, "\n-- " <> heading)
        IO.puts(:stderr, text |> String.split("\n") |> Enum.take(6) |> Enum.join("\n"))
      end

      if new > 0, do: System.at_exit(fn _ -> exit({:shutdown, 1}) end)
    end

    :ok
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
