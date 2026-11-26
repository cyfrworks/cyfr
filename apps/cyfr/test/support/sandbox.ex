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
  runs' attempts, then the runtime's runners, then the event buffers
  they wrote to, then the decision log's writers, which work at every tier
  starts. Each child is stopped synchronously, so the sweep returns
  only once every child is gone. The runtime's runners are OS
  processes, and their handles' supervisor (`Locus.Runtime.RunnerPool.Runners`) is
  swept through the pool instead (`pooled/0`): every busy runner is ended
  at once and awaited (`Locus.Runtime.Test.Runners.retire_busy/2`), fresh and idle
  ones stay pooled for the next test, and every report of a runner's exit
  the service has in flight is awaited (`Locus.Runtime.Test.Runners.await_reports/1`),
  so no runner's host call and no report lands after the owner is gone.
  Then the connections open on the listeners of the worker wire
  (`Cyfr.Test.RuntimeService.listeners/0`) are closed: a host call a stopped
  runner had in flight runs on one of them, and it must not reach the
  database after the owner is gone.

  Every process the test spawned is ended before the owner goes too, sync
  or async: a process whose parent, callers or ancestors lead back to the
  test process (`descendants/2`), however it was started — a bare `spawn`,
  a `Task`, a task a supervisor above runs on the test's behalf — is
  killed and awaited, unless it is registered under a name, which makes it
  a service rather than the test's work, or the test started it before its
  sandbox, which makes it scaffolding the test means to outlive it. The
  kills are sent with every other scheduler blocked and the sweep at the
  highest priority, so no process below that priority runs between the
  first kill and the last, and none answers another's end with a write
  after a kill cut the shared connection mid-query. A sync test's sweep
  does this first and again on every pass; an async test's does only this,
  since the supervisors are its neighbours' too.

  A sync test's kills take with them the work that answers another
  process's end with a query (`killed_supervisors/0`), whoever started
  it, in the same instant as the test's descendants: a fill (its attempt,
  the keeper that watches it, the pulls it runs beside itself) and Aqua's
  thread runners with their loops and the loops' workers. A request from
  outside the test's processes starts a fill that leads back to no
  descendant, and a runner leads back to its supervisor alone; left to
  its supervisor's turn, either would still be running after a kill had
  cut the shared connection under a query, and its next query — a keeper
  answering its attempt's end, a loop announcing the turn it committed,
  a runner settling the turn of a loop that died — would find no owner.
  A runner is a transient child, which its supervisor starts again when
  it is killed: the supervisor is held for the kills and given back with
  the dead forgotten, so none is started again (`holding_runners/2`).

  `on_exit` callbacks run last-registered first. A test that restores
  configuration a background process reads (a base path, a seed path, the
  execution engine) calls `stop_work_on_exit/0` after registering those
  restores, so the work stops before the configuration it runs under moves.

  The LiveViews a test mounts are the test supervisor's children, and they
  are shut down with it as the test process ends, before any `on_exit`
  runs, wherever each has reached. A test whose views start work, or read
  what its work broadcasts, ends them and their work itself, as its last
  step (`end_views/0`).

  A process that reaches the database after its owner has gone crashes
  with `DBConnection.OwnershipError`. Every such line logged at error level
  or above, from the first `setup!/1` on, is kept with the sandboxed tests
  running when it arrived; once the suite ends they are printed, and a
  line logged while a sandboxed test ran fails the run
  (`watch_ownership!/0`). A refusal a test provokes and the
  code handles is logged below error level and is not counted.
  """

  # The runtime is a sibling application, not a dependency.
  @compile {:no_warn_undefined, [Locus.Runtime.RunnerPool, Locus.Runtime.Test.Runners]}

  @supervisors [
    Aqua.RunnerSupervisor,
    Aqua.TaskSupervisor,
    Prism.TaskSupervisor,
    Emissary.TaskSupervisor,
    Emissary.Web.TaskSupervisor,
    Sanctum.Gate.TaskSupervisor,
    Sanctum.ProvisioningSupervisor,
    Compendium.ProvisioningSupervisor,
    Opus.Schedules.TaskSupervisor,
    Sanctum.OAuth.RefreshTaskSupervisor,
    Sanctum.TaskSupervisor,
    Opus.TaskSupervisor,
    Compendium.Builds.TaskSupervisor,
    Emissary.External.ServerSupervisor,
    # A program brain's harness writes through its brain holder, which
    # ends with it: the harnesses go first. Each browser and brain holder
    # closes the program session it holds as it stops, so the holders go
    # before the sessions.
    Aqua.Harness.Sessions,
    Opus.Brain.Holders,
    Opus.Browser.Holders,
    Opus.Programs.Relays,
    Opus.Attempt.Supervisor,
    Locus.Runtime.RunnerPool.Runners,
    Opus.Events.Supervisor,
    Arca.DecisionLog.Writers
  ]

  # Swept through the pool whose runners' handles it supervises, never by
  # stopping its children: a handle stopped kills its runner with no report.
  @pooled [Locus.Runtime.RunnerPool.Runners]

  # Where the test process keeps what its sweeps spare: its sandbox owner
  # and what it started before the sandbox.
  @spared {__MODULE__, :spared}

  # The ownership watch: its keeper's name, the lines it kept and the tests
  # running when they arrived.
  @watch __MODULE__.OwnershipWatch
  @lines :cyfr_test_ownership_lines
  @running :cyfr_test_sandbox_running

  # A killed runner's supervisor would start it again: it is held while
  # the kills are sent.
  @runner_supervisor Aqua.RunnerSupervisor

  # How long the sweep waits for each answer of the runners' supervisor as
  # it holds it and gives it back. It answers between two of its messages,
  # and a runner's start is the longest of them.
  @hold_ms 5_000

  # How long `end_views/0` waits, in all, for the views and the work they
  # started to end: well under ExUnit's 60-second test timeout, so a view
  # or its work that never ends fails the test naming each such process,
  # rather than timing the test out with no process named.
  @end_views_deadline_ms 30_000

  @doc "The supervisors a sync test's work is swept from, in the order they are stopped."
  @spec supervisors() :: [atom()]
  def supervisors, do: @supervisors

  @doc "The supervisors of `supervisors/0` swept through their pool rather than stopped."
  @spec pooled() :: [atom()]
  def pooled, do: @pooled

  @doc """
  Start this test's sandbox owner (shared unless the test is async), let
  the supervisors reach it, and stop the test's background work and then
  the owner when the test ends. Tags follow `Arca.Test.Sandbox.start_owner!/1`,
  including `:ownership_timeout`. Answers the owner pid.
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

  @doc """
  End every LiveView the calling test mounted, and the work they started,
  as the test's last step, from the test process. Each view is stopped
  between two of its messages, so none holds the shared connection as it
  goes; what the views started beside themselves (a load, a component
  call whose answer no view now waits for) is awaited to its own end, and
  so is what that work starts in turn: the work is looked for again until
  a look finds none and sees nothing end while it reads.
  Left to the test's end, the views are shut down with the test
  supervisor, before any `on_exit` runs, at whatever point they have
  reached, and their work is stopped by the sweep, at whatever point it
  has reached: either one, inside a query, takes the connection with it,
  and the next query of the work still running finds no owner.

  The views and their work are awaited within one deadline for the whole
  call, `end_views_deadline_ms/0` unless `deadline_ms` names another; past
  it the test fails naming each process still running, and the sweep
  stops them. `opts[:list]` is the process list each look reads
  (`Process.list/0`), a seam for the sandbox's own tests.
  """
  @spec end_views(pos_integer(), keyword()) :: :ok
  def end_views(deadline_ms \\ @end_views_deadline_ms, opts \\ [])
      when is_integer(deadline_ms) and deadline_ms > 0 and is_list(opts) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    {supervisor, views} =
      case ExUnit.fetch_test_supervisor() do
        {:ok, supervisor} ->
          views =
            for {_id, pid, _type, [Phoenix.LiveView.Channel]} <-
                  Supervisor.which_children(supervisor),
                is_pid(pid),
                do: pid

          {supervisor, views}

        :error ->
          {nil, []}
      end

    watched = for pid <- views, do: {Process.monitor(pid), pid}

    # A nested view stops with its parent, and every view of a client with
    # the client, so a view may already be on its way out when its turn
    # comes; the monitors say when each has gone. A stop still waiting at
    # the deadline is given up here, and its view is named below. With only
    # a few milliseconds left the stop can raise as well as exit.
    for pid <- views do
      try do
        GenServer.stop(pid, :normal, time_left(deadline))
      catch
        kind, _gone_or_late when kind in [:exit, :error] -> :ok
      end
    end

    await_down(watched, deadline, deadline_ms)

    # What a view started unlinked goes on without it and ends on its own,
    # a view the page closed during the test included: every view names
    # the test among its `$callers`, and a task or a run's attempt keeps
    # its caller's callers behind its own, so the work of any view, at any
    # depth, names it too. The test supervisor names the test as well, and
    # it and what it supervises stay until the test ends.
    list = Keyword.get(opts, :list, &Process.list/0)
    await_work(self(), supervisor, list, deadline, deadline_ms)
  end

  # Work awaited may start more as it ends (a write it does not wait for),
  # which names the test too. A look lists every process, then reads each
  # one's dictionary. Work that starts after a list descends from a
  # process alive at it that names the test: one read as work is awaited
  # and looked past again; one that ended between the list and its reading
  # is counted, and what it started is alive at the next list or has
  # started work of its own that is. So a look that finds no work and in
  # which nothing listed ended leaves none. Work handed to a process that
  # names neither the test nor its work, to start later, is not followed.
  # The deadline is the whole call's: a look past it that still finds work
  # fails naming it, and one that still sees processes end fails as well.
  defp await_work(test, supervisor, list, deadline, deadline_ms) do
    {work, ended} = look(test, supervisor, list)

    cond do
      work == [] and ended == 0 ->
        :ok

      time_left(deadline) == 0 ->
        still_working(work, deadline_ms)

      true ->
        await_down(for(pid <- work, do: {Process.monitor(pid), pid}), deadline, deadline_ms)
        await_work(test, supervisor, list, deadline, deadline_ms)
    end
  end

  # The work a list holds, and how many it listed ended before it was read.
  defp look(test, supervisor, list) do
    Enum.reduce(list.(), {[], 0}, fn
      pid, found when pid == test or pid == supervisor ->
        found

      pid, {work, ended} ->
        case Process.info(pid, :dictionary) do
          nil ->
            {work, ended + 1}

          {:dictionary, dictionary} ->
            if test in Keyword.get(dictionary, :"$callers", []) and
                 supervisor not in Keyword.get(dictionary, :"$ancestors", []),
               do: {[pid | work], ended},
               else: {work, ended}
        end
    end)
  end

  defp still_working([], deadline_ms) do
    ExUnit.Assertions.flunk(
      "end_views/0 waited out its #{deadline_ms} ms deadline, and processes still ended " <>
        "as it looked for the test's work"
    )
  end

  defp still_working(work, deadline_ms) do
    ExUnit.Assertions.flunk(
      "end_views/0 waited out its #{deadline_ms} ms deadline, and these still run: " <>
        Enum.map_join(work, "; ", &still_running/1)
    )
  end

  @doc "How long `end_views/0` waits for the views and their work, in milliseconds."
  @spec end_views_deadline_ms() :: pos_integer()
  def end_views_deadline_ms, do: @end_views_deadline_ms

  # Once the deadline has passed, each wait left only reads the mailbox, so
  # the failure names every process still running, not just the first.
  defp await_down(watched, deadline, deadline_ms) do
    running = for {ref, pid} <- watched, not down?(ref, pid, deadline), do: pid

    if running != [] do
      ExUnit.Assertions.flunk(
        "end_views/0 waited out its #{deadline_ms} ms deadline, and these still run: " <>
          Enum.map_join(running, "; ", &still_running/1)
      )
    end

    :ok
  end

  defp down?(ref, pid, deadline) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> true
    after
      time_left(deadline) -> false
    end
  end

  defp time_left(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # A process still running, by what it was started as and where it is now.
  defp still_running(pid) do
    case Process.info(pid, [:dictionary, :initial_call, :current_function]) do
      [dictionary: dictionary, initial_call: initial, current_function: current] ->
        started = Keyword.get(dictionary, :"$initial_call", initial)
        "#{inspect(pid)} started as #{mfa(started)}, now in #{mfa(current)}"

      nil ->
        "#{inspect(pid)}, gone since"
    end
  end

  defp mfa({module, function, arity}), do: Exception.format_mfa(module, function, arity)
  defp mfa(other), do: inspect(other)

  # A child stopped can take work it started that the pass already walked
  # past (a runner's loop is killed as the runner ends): passes repeat, at
  # most three, until one finds nothing left. The test's own processes go
  # first on every pass, so none of them starts work behind the sweep.
  defp stop_work(test, spared, passes \\ 3)

  defp stop_work(_test, _spared, 0), do: :ok

  defp stop_work(test, spared, passes) do
    sweeping(test)
    ended = holding_runners(fn -> stop_descendants(test, spared, killed_roots()) end)

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
  def descendants(test, spared \\ []) when is_pid(test) and is_list(spared),
    do: found([test], spared)

  # The live, unnamed processes that lead back to one of `roots`, the roots
  # apart. A root need not be alive: a process names where it came from by
  # pid, so what a dead root started still leads back to it.
  defp found(roots, spared) do
    {_reached, found} = Process.list() |> origins(spared) |> trace({MapSet.new(roots), []})
    found
  end

  # What each of `pids` names as where it came from, and whether it is
  # registered under a name; the caller, the spared and the gone left out.
  # Reading a process's dictionary lets a runnable process run some of its
  # own code while it is read, at the reader's priority.
  defp origins(pids, spared) do
    for pid <- pids,
        pid != self(),
        pid not in spared,
        info = Process.info(pid, [:parent, :dictionary, :registered_name]),
        info != nil do
      dictionary = info[:dictionary]

      from =
        Keyword.get(dictionary, :"$callers", []) ++ Keyword.get(dictionary, :"$ancestors", [])

      {pid, Enum.filter([info[:parent] | from], &is_pid/1), info[:registered_name] != []}
    end
  end

  # Adds `origins`, read for the first time, to what is traced so far: the
  # pids reached from the roots, and the unnamed ones among them. A process
  # names only what existed before it, so nothing traced earlier changes.
  defp trace(origins, {reached, found}) do
    grown = reach(origins, reached)

    new =
      for {pid, _from, false} <- origins,
          MapSet.member?(grown, pid),
          not MapSet.member?(reached, pid),
          do: pid

    {grown, new ++ found}
  end

  # The closure of `reached` over the origins: passes repeat until one adds
  # nobody, so a grandchild counts however the list is ordered.
  defp reach(origins, reached) do
    grown =
      for {pid, from, _named} <- origins,
          not MapSet.member?(reached, pid),
          Enum.any?(from, &MapSet.member?(reached, &1)),
          reduce: reached,
          do: (acc -> MapSet.put(acc, pid))

    if MapSet.size(grown) == MapSet.size(reached), do: reached, else: reach(origins, grown)
  end

  # How many times the sweep, alone, looks for processes it has not read
  # before it kills what it knows. Each look reads a process once, and
  # alone a process below the highest priority runs only while it is read,
  # so a look finds only what the look before let start: the first takes
  # what started while the list was read, the second what those started as
  # they were read, and a third finds nothing unless each generation starts
  # the next. Without a bound, such a chain would hold every other
  # scheduler blocked without end. The bound is on how many times the sweep
  # looks, not on how long it stays alone: a look reads every process it
  # finds unread, however many, and each read waits for its process.
  @looks 3

  # How many times the sweep reads again once what it killed is gone. What
  # such a read finds was not known when the kills were sent, so it runs
  # freely and can start more while it is read and killed: the reads repeat
  # until one finds nothing. A chain that ends within them is ended with
  # them; a longer one, or one that never ends, is the limit the failure
  # then names.
  @reads 5

  # Killed, not asked: a process the test left behind has no one to answer
  # a shutdown to. Each kill is awaited, so the owner outlives them all.
  #
  # A kill can land while its process holds the shared connection
  # mid-query, and the pool then drops the connection and the owner's
  # checkout with it; a sibling free to run would answer that death by
  # writing — a provisioning keeper releasing the claim of the attempt it
  # watches — into no owner at all. So the kills are sent alone
  # (`alone/1`), all of them after the last read:
  #
  #   - between the first kill and the last, no process below the highest
  #     priority runs Erlang code;
  #   - before the first kill, a process the sweep reads for the first time
  #     can run while it is read, and start others: the sweep looks again
  #     for what it has not read, `@looks` times at most;
  #   - a process at the highest priority can run at any point. Only OTP's
  #     own processes run there today, and two test processes for a moment
  #     each: the worker service pool's, and the one here that checks the
  #     sweep gives the priority back.
  #
  # A process read before it names where it came from — a task a supervisor
  # has started for a descendant, before its first instructions — is not
  # known for a descendant: it outlives the kills and can run. So can what
  # a chain longer than `@looks` started. Once the killed are gone the
  # sweep reads again, with the killed as roots since their children name
  # them; what it finds it kills and awaits, and it reads again, `@reads`
  # times at most, until a read finds nothing. Then it fails the test,
  # naming the first of them, and says so when the reads ran out, since
  # something may then be left. The suspension this replaces had the same
  # limit and said nothing.
  @doc """
  End every process that leads back to `test` (`descendants/2`), or to
  one of the `beside` (never ended itself), the `spared` apart: the sweep
  of an async test, and the first step of each pass of a sync test's,
  which ends beside the descendants the work of `killed_supervisors/0`.
  Answers the pids it killed, or fails the test when, once those were
  gone, it found more that it had not known.
  """
  @spec stop_descendants(pid(), [pid()], [pid()]) :: [pid()]
  def stop_descendants(test, spared, beside \\ []) do
    sweeping(test)
    listed = Process.list()

    # The `beside` are roots of the kill alone: work a supervisor starts
    # after it, for whoever asks, is its turn's in the sweep, not a process
    # the test left unknown.
    case listed |> origins(spared) |> trace({MapSet.new([test | beside]), []}) do
      {_reached, []} ->
        []

      traced ->
        read = MapSet.new(listed)

        killed =
          alone(fn ->
            {_reached, found} = unread(traced, read, spared, @looks)
            Enum.each(found, &Process.exit(&1, :kill))
            found
          end)

        await(killed)

        case unknown(test, spared, killed, {0, []}, @reads) do
          {0, [], _left} ->
            killed

          {count, first, left} ->
            ExUnit.Assertions.flunk(
              "the sweep killed #{length(killed)} of the test's processes, and once they " <>
                "had ended found #{count} more that it had not known, the first: " <>
                Enum.join(first, "; ") <>
                if(left == :unread,
                  do: "; each of its #{@reads} reads found more, so some may be left",
                  else: ""
                )
            )
        end
    end
  end

  @doc """
  The supervisors whose children a sync test's sweep kills with its
  descendants rather than stopping them in their turn, since each answers
  another's end with a query: a thread's runner, which settles the turn of
  a loop that died (`Aqua.RunnerSupervisor`); the loops and their workers,
  which go on to announce a turn they committed (`Aqua.TaskSupervisor`); a
  fill's attempt and its pulls (`Compendium.ProvisioningSupervisor`); and
  the keeper that watches the attempt and writes when it ends
  (`Sanctum.ProvisioningSupervisor`).
  """
  @spec killed_supervisors() :: [atom()]
  def killed_supervisors do
    [
      @runner_supervisor,
      Aqua.TaskSupervisor,
      Compendium.ProvisioningSupervisor,
      Sanctum.ProvisioningSupervisor
    ]
  end

  # Each child leads back to its supervisor through `$ancestors`.
  defp killed_roots, do: for(name <- killed_supervisors(), pid = Process.whereis(name), do: pid)

  @doc """
  Run `fun`, which kills runners, with `Aqua.RunnerSupervisor` starting
  none of them again. The supervisor is suspended first, so it starts no
  runner and reads no runner's end while `fun` runs; afterwards it is
  told to forget the children that died and resumed, the same process
  with the children still alive, and the starts asked of it meanwhile
  are answered then. Each of its answers is awaited `wait_ms` at most.

  Where no such supervisor runs, `fun` runs alone. A supervisor that does
  not stop for the hold, or cannot be given back, is killed, so its tree
  starts a fresh one for the next test, and the test fails saying which.
  So is one whose holder dies before it has given it back, however it
  dies: ExUnit kills an `on_exit` callback that outlives its deadline,
  and nothing of the caller's then runs.
  """
  @spec holding_runners((-> result), pos_integer()) :: result when result: var
  def holding_runners(fun, wait_ms \\ @hold_ms)
      when is_function(fun, 0) and is_integer(wait_ms) and wait_ms > 0 do
    case Process.whereis(@runner_supervisor) do
      nil ->
        fun.()

      supervisor ->
        watch = watch_holder(supervisor)

        try do
          held(supervisor, fun, wait_ms)
        after
          send(watch, {:given_back, self()})
        end
    end
  end

  defp held(supervisor, fun, wait_ms) do
    case suspend(supervisor, wait_ms) do
      :ok ->
        try do
          fun.()
        after
          give_back(supervisor, wait_ms)
        end

      :late ->
        replace(supervisor, wait_ms)
        fun.()

        ExUnit.Assertions.flunk(
          "#{inspect(@runner_supervisor)} did not stop for the sweep within #{wait_ms} ms, " <>
            "so the sweep ran with nothing holding its restarts; it was replaced"
        )

      :gone ->
        fun.()
    end
  end

  # Outlives the holder: started before the suspension is asked for, it
  # kills the supervisor when the holder dies without having said it gave
  # it back, a kill included, which runs no `after`. The supervisor's tree
  # then starts a fresh one.
  #
  # A watcher that acts late may kill a supervisor a later hold already
  # holds. That hold then sees its supervisor go down while held and
  # leaves it to its tree: the cost is one counted restart of the tree,
  # in a run a teardown timeout has already failed.
  defp watch_holder(supervisor) do
    holder = self()

    spawn(fn ->
      ref = Process.monitor(holder)

      receive do
        {:given_back, ^holder} -> :ok
        {:DOWN, ^ref, :process, ^holder, _reason} -> Process.exit(supervisor, :kill)
      end
    end)
  end

  # A suspension that timed out is still in the supervisor's mailbox and
  # would take effect later, with nobody to resume it: `:late` has the
  # caller replace the supervisor.
  defp suspend(supervisor, wait_ms) do
    :sys.suspend(supervisor, wait_ms)
  catch
    :exit, {:timeout, _call} -> :late
    :exit, _gone -> :gone
  end

  # A dead child's exit, read after the resume, is then no child's and
  # starts nothing. The supervisor's state is its own: one this cannot
  # read fails the replacement, as an error where a call that got no
  # answer is an exit, and the supervisor is replaced instead.
  defp give_back(supervisor, wait_ms) do
    :sys.replace_state(
      supervisor,
      fn %{children: children} = state ->
        %{state | children: Map.filter(children, fn {pid, _child} -> Process.alive?(pid) end)}
      end,
      wait_ms
    )

    :sys.resume(supervisor, wait_ms)
    :ok
  catch
    kind, reason when kind in [:exit, :error] ->
      if Process.alive?(supervisor) do
        replace(supervisor, wait_ms)

        ExUnit.Assertions.flunk(
          "#{inspect(@runner_supervisor)} could not be given back after the sweep's kills " <>
            "(#{inspect(reason)}); it was replaced"
        )
      end

      :ok
  end

  # The supervisor's tree starts a fresh one in its place.
  defp replace(supervisor, wait_ms) do
    ref = Process.monitor(supervisor)
    Process.exit(supervisor, :kill)

    receive do
      {:DOWN, ^ref, :process, ^supervisor, _reason} -> :ok
    end

    Prima.Test.Wait.wait_until(
      fn -> Process.whereis(@runner_supervisor) not in [nil, supervisor] end,
      wait_ms,
      "a fresh #{inspect(@runner_supervisor)} in place of the one the sweep killed"
    )
  end

  # Kills and awaits what leads back to the test or to anything `killed`,
  # and reads again with those among the killed, until a read finds none
  # (`:none`) or the reads run out (`:unread`). Answers how many it found
  # and the first five as they were before it killed them.
  defp unknown(_test, _spared, _killed, {count, first}, 0), do: {count, first, :unread}

  defp unknown(test, spared, killed, {count, first}, reads) do
    case found([test | killed], spared) do
      [] ->
        {count, first, :none}

      left ->
        named = left |> Enum.take(5 - length(first)) |> Enum.map(&still_running/1)
        kill(left)
        await(left)
        unknown(test, spared, left ++ killed, {count + length(left), first ++ named}, reads - 1)
    end
  end

  # Traces what started since `read` was listed, reading each such process
  # once, until a look finds none unread or the looks run out.
  defp unread(traced, _read, _spared, 0), do: traced

  defp unread(traced, read, spared, looks) do
    case Enum.reject(Process.list(), &MapSet.member?(read, &1)) do
      [] ->
        traced

      new ->
        unread(
          new |> origins(spared) |> trace(traced),
          MapSet.union(read, MapSet.new(new)),
          spared,
          looks - 1
        )
    end
  end

  defp await(pids) do
    for pid <- pids do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      end
    end
  end

  @doc """
  Kill every one of `pids`, with no process below the highest priority
  running Erlang code between the first kill and the last (`alone/1`).
  """
  @spec kill([pid()]) :: :ok
  def kill(pids) when is_list(pids),
    do: alone(fn -> Enum.each(pids, &Process.exit(&1, :kill)) end)

  # `fun` with the other normal schedulers blocked and the caller at the
  # highest priority: the one scheduler left takes up nothing below that
  # priority unless `fun` reads it or waits. A process inside a dirty call
  # stays there, or waits for that scheduler. Blocks count, so sweeps side
  # by side each lift their own, and the VM lifts the block of a caller
  # that dies holding it. The block is lifted before the priority is given
  # back, so the caller is not preempted while it still holds it.
  #
  # The pids are never suspended instead: a suspended process killed while
  # it waits for a dirty I/O scheduler can be freed under that scheduler,
  # which ends the whole VM on a signal 11 (OTP 29.1).
  defp alone(fun) do
    :erlang.system_flag(:multi_scheduling, :block_normal)
    priority = Process.flag(:priority, :max)

    try do
      fun.()
    after
      :erlang.system_flag(:multi_scheduling, :unblock_normal)
      Process.flag(:priority, priority)
    end
  end

  # ---------------------------------------------------------------------------
  # Ownership errors
  # ---------------------------------------------------------------------------

  @doc """
  Watch the log for `DBConnection.OwnershipError` at error level or above,
  once per run: a `:logger` handler keeps each such line with the
  sandboxed tests running when it arrived, and an `after_suite` callback
  prints every line and fails the run for any line logged while a
  sandboxed test was running. A line logged while no
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

    named =
      case tags do
        %{module: module, test: name} ->
          {module, "#{inspect(module)} #{name}"}

        _untagged ->
          module = calling_module()
          {module, "a test of #{inspect(module)} (`setup!/1` was given no tags)"}
      end

    :ets.insert(@running, {test, named, nil, :test})
    ExUnit.Callbacks.on_exit(fn -> :ets.delete(@running, test) end)
  end

  # The module whose setup called `setup!/1`: the nearest frame that is
  # neither this module's nor the test framework's.
  defp calling_module do
    {:current_stacktrace, frames} = Process.info(self(), :current_stacktrace)

    Enum.find_value(frames, fn {module, _function, _arity, _location} ->
      root = module |> Module.split() |> hd()
      if module != __MODULE__ and root not in ["Process", "ExUnit"], do: module
    end)
  rescue
    # An Erlang module has no parts to split.
    ArgumentError -> nil
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
  defp verdict(_running), do: :new

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

  # The runtime's busy runners are ended and awaited, then the reports
  # of their exits: answered as stopped work when there was any. A service
  # a test is restarting has no pool to ask, and its runners went with the
  # old one.
  defp retire_runners do
    busy = Locus.Runtime.RunnerPool.status(Locus.Runtime.RunnerPool).runners.busy
    :ok = Locus.Runtime.Test.Runners.retire_busy(Locus.Runtime.RunnerPool)
    :ok = Locus.Runtime.Test.Runners.await_reports()
    List.duplicate(:retired, busy)
  catch
    :exit, {:noproc, _call} -> []
  end

  # A connection process carries one request; killed, its caller sees a
  # lost answer, which a stopped runner no longer reads. Each kill is
  # awaited, so the sweep returns only once the request is gone.
  defp close_connections do
    for server <- Cyfr.Test.RuntimeService.listeners(),
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
