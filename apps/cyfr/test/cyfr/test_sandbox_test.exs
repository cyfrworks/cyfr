# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("../integration/runtime/support/nested_execution_helper.exs", __DIR__)

defmodule Cyfr.Test.SandboxTest.WorkingView do
  @moduledoc false
  # A view that, once connected, starts work beside itself, unlinked, on a
  # task supervisor, and hands the test the work's pid. The work outlives
  # the view: it ends `work_ms` (100 unless the session names it) after the
  # view has gone. Told `{:busy, ms}`, the view is busy that long before it
  # reads its next message, a stop included; told `:stick`, it waits in its
  # `handle_info` until it is told `:release`. Either way it tells the test
  # first.
  use Phoenix.LiveView

  @impl true
  def mount(_params, %{"test" => test} = session, socket) do
    if connected?(socket) do
      view = self()
      work_ms = Map.get(session, "work_ms", 100)

      {:ok, work} =
        Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
          ref = Process.monitor(view)

          receive do
            {:DOWN, ^ref, :process, ^view, _reason} -> Process.sleep(work_ms)
          end
        end)

      send(test, {:work, work})
    end

    {:ok, assign(socket, :test, test)}
  end

  @impl true
  def handle_info({:busy, ms}, socket) do
    send(socket.assigns.test, {:busy, self()})
    Process.sleep(ms)
    {:noreply, socket}
  end

  def handle_info(:stick, socket) do
    send(socket.assigns.test, {:stuck, self()})

    receive do
      :release -> {:noreply, socket}
    end
  end

  @impl true
  def render(assigns), do: ~H"<p>working</p>"
end

defmodule Cyfr.Test.SandboxTest do
  @moduledoc """
  A sync test's background work is stopped before its sandbox owner is:
  every dynamic supervisor this repository's applications start is swept,
  and each child's last database work lands while the owner still holds
  the connection. The runtime's runners are swept through their pool
  instead: a runner the test left busy is ended and its exit reported,
  and the fresh runners stay pooled for the next test.

  `end_views/0` finds each view a test mounted as the test supervisor's
  LiveView child and the views' work by the test among its callers, and
  awaits both within a deadline past which it names what still runs.
  """

  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias Cyfr.Test.{Sandbox, TwoServices}
  alias Cyfr.Test.SandboxTest.WorkingView
  alias Locus.Runtime.Test.NestedExecution, as: Probe
  alias Sanctum.Consent.{Bootstrap}

  @endpoint CyfrWeb.Endpoint

  @apps_root Path.expand("../../..", __DIR__) <> "/"

  test "every dynamic supervisor the repository's running applications start is swept" do
    running = repository_dynamic_supervisors()
    assert running != []
    assert Enum.sort(running) == Enum.sort(Enum.filter(Sandbox.supervisors(), &Process.whereis/1))
  end

  test "the runtime's runners are swept through their pool, not stopped" do
    assert Sandbox.pooled() == [Locus.Runtime.RunnerPool.Runners]
    assert Locus.Runtime.RunnerPool.Runners in repository_dynamic_supervisors()
  end

  @tag ownership_timeout: 1_000
  test "the ownership timeout tag reaches this test's checkout", tags do
    ExUnit.CaptureLog.capture_log(fn ->
      owner = Sandbox.setup!(tags)
      assert Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, owner, self()) != :not_found

      # Observe the checkout's expiry without issuing a query after it has
      # been reclaimed, which would itself log an ownership error.
      Prima.Test.Wait.wait_until(
        fn -> Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, owner, self()) == :not_found end,
        5_000,
        "the checkout's tagged ownership timeout"
      )
    end)
  end

  describe "a sync test's work" do
    setup do
      collector = spawn(fn -> collect(%{}) end)

      # Registered before the sandbox, so it runs after the owner is gone.
      on_exit(fn ->
        send(collector, {:reports, self()})
        assert_receive {:reports, reports}, 5_000

        for name <- swept_by_stopping() do
          assert match?({:ok, _}, Map.get(reports, name)),
                 "#{inspect(name)}'s child did not finish its database work before the owner " <>
                   "stopped: #{inspect(Map.get(reports, name, :never_stopped))}"
        end
      end)

      Sandbox.setup!()
      {:ok, collector: collector}
    end

    test "is stopped under every dynamic supervisor while the owner still holds the connection",
         %{collector: collector} do
      for name <- swept_by_stopping() do
        assert {:ok, _child} =
                 DynamicSupervisor.start_child(name, last_query_child(name, collector))
      end
    end
  end

  describe "a sync test's descendants" do
    setup do
      collector = spawn(fn -> collect(%{}) end)

      # Registered before the sandbox, so it runs after the sweep: the one
      # scheduler is given back, and nothing the test left may have run
      # once its sibling was killed.
      schedulers = :erlang.system_info(:schedulers_online)

      on_exit(fn ->
        :erlang.system_flag(:schedulers_online, schedulers)
        send(collector, {:reports, self()})
        assert_receive {:reports, reports}, 5_000

        assert reports == %{},
               "a descendant ran after the sweep killed its sibling: #{inspect(reports)}"
      end)

      Sandbox.setup!()
      {:ok, collector: collector}
    end

    # Each sibling watches the other and, told of its end, writes — the
    # shape of a provisioning keeper releasing the claim of the attempt it
    # watches (`Sanctum.Provisioning.keep/2`). One holds the shared
    # connection as a query in flight does, so whichever is killed first,
    # the kill either cuts the connection under the other's write or leaves
    # one alive to make it. On one scheduler, with the siblings above the
    # test's priority, a sibling free to run when the other ends always
    # runs before a next kill the sweep waited to send: the sweep must send
    # every kill before it lets any of them run.
    test "are all killed before any of them runs again, so none writes after a kill",
         %{collector: collector} do
      test = self()
      holding = sibling(test, collector, :holding, true)
      watching = sibling(test, collector, :watching, false)
      send(holding, {:watch, watching})
      send(watching, {:watch, holding})
      assert_receive {:watching, ^holding}, 5_000
      assert_receive {:watching, ^watching}, 5_000
      :erlang.system_flag(:schedulers_online, 1)
    end
  end

  describe "a descendant that starts children until it is swept" do
    setup do
      collector = spawn(fn -> collect(%{}) end)

      # Registered before the sandbox, so it runs after the sweep.
      on_exit(fn ->
        send(collector, {:reports, self()})
        assert_receive {:reports, started}, 5_000
        left = for {pid, :started} <- started, Process.alive?(pid), do: pid
        Enum.each(left, &Process.exit(&1, :kill))

        assert left == [],
               "#{length(left)} of the #{map_size(started)} processes the test's descendant " <>
                 "started outlived the sweep"
      end)

      Sandbox.setup!()
      {:ok, collector: collector}
    end

    # The parent never stops starting children, so some start after the
    # sweep has read which processes there are. Each child names only its
    # parent, and its parent is dead once it is killed: the sweep must find
    # the child all the same.
    test "are ended with it, however late each started", %{collector: collector} do
      test = self()

      spawn(fn ->
        send(collector, {:report, self(), :started})
        send(test, :breeding)
        breed(collector)
      end)

      assert_receive :breeding, 5_000
    end
  end

  test "a kill pass gives the caller back the priority it had" do
    for priority <- [:low, :normal, :high, :max] do
      was = Process.flag(:priority, priority)
      pids = for _ <- 1..2, do: spawn(fn -> Process.sleep(:infinity) end)
      :ok = Sandbox.kill(pids)
      assert Process.info(self(), :priority) == {:priority, priority}
      Process.flag(:priority, was)
    end
  end

  # The sweeps of async tests run side by side, each blocking the other
  # schedulers for its kills. Every one must end, and the last to lift its
  # block must leave the schedulers running. Each sweeper stays alive until
  # the test has looked, since the VM lifts the block of one that ends.
  test "kills made side by side all land, and leave every scheduler running" do
    assert :erlang.system_info(:multi_scheduling) == :enabled
    test = self()

    sweepers =
      for _ <- 1..8 do
        spawn_link(fn ->
          for _ <- 1..500 do
            watched = for _ <- 1..3, do: spawn_monitor(fn -> Process.sleep(:infinity) end)
            :ok = Sandbox.kill(for {pid, _ref} <- watched, do: pid)
            for {pid, ref} <- watched, do: assert_receive({:DOWN, ^ref, :process, ^pid, :killed})
          end

          send(test, {:swept, self()})
          receive do: (:looked -> :ok)
        end)
      end

    for sweeper <- sweepers, do: assert_receive({:swept, ^sweeper}, 30_000)

    assert :erlang.system_info(:multi_scheduling) == :enabled
    assert :erlang.system_info(:normal_multi_scheduling_blockers) == []

    for sweeper <- sweepers, do: send(sweeper, :looked)
  end

  describe "a sync test's runners" do
    setup tags do
      # Unlinked, so it outlives the test process for the check below.
      {:ok, seen} = Agent.start(fn -> %{} end)

      # Registered before the sandbox, so it runs after the sweep.
      on_exit(fn ->
        %{busy: busy, fresh: fresh} = Agent.get(seen, & &1)
        Agent.stop(seen)

        pooled =
          Map.new(
            Locus.Runtime.Test.Runners.runners(Locus.Runtime.RunnerPool),
            &{&1.id, &1.state}
          )

        refute Map.has_key?(pooled, busy), "the busy runner outlived the sweep"

        for id <- fresh,
            do: assert(Map.has_key?(pooled, id), "a fresh runner was swept: #{id}")
      end)

      Sandbox.setup!(tags)
      TwoServices.watch!()

      test_path =
        Path.join(System.tmp_dir!(), "sandbox_runners_#{System.unique_integer([:positive])}")

      keys = [:base_path]
      previous = Map.new(keys, &{&1, Application.get_env(:arca, &1)})
      Application.put_env(:arca, :base_path, test_path)

      on_exit(fn ->
        File.rm_rf!(test_path)

        for {key, value} <- previous do
          if value,
            do: Application.put_env(:arca, key, value),
            else: Application.delete_env(:arca, key)
        end
      end)

      Sandbox.stop_work_on_exit()

      ctx = Sanctum.TestContext.local(:api)
      Sanctum.TestContext.ready!(ctx.athanor_id)
      :ok = Probe.publish_probe!(ctx)
      {:ok, _minted} = Bootstrap.run(ctx)
      {:ok, ctx: ctx, seen: seen}
    end

    test "a runner left busy is ended and the fresh ones stay pooled", %{ctx: ctx, seen: seen} do
      root_id = Prima.UUID7.execution_id()
      TwoServices.hold!(:tool_call, root_id, once: true)

      # The run waits in a task of the execution domain's supervisor, not in
      # a process of this test's, so the sweep stops it and then its attempt
      # in their supervisors' order. The attempt traps exits so that a stop
      # runs `terminate/2` after its reaction to its waiter; killed with the
      # test's other descendants it could be cut off mid-write, taking the
      # shared connection down under the report of the runner the sweep
      # then ends.
      {:ok, _waiter} =
        Task.Supervisor.start_child(Opus.TaskSupervisor, fn ->
          Process.delete(:"$callers")

          Opus.run_root(ctx, :default, Probe.probe_ref(), Probe.held_input(),
            execution_id: root_id
          )
        end)

      assert_receive {:held, ^root_id, _call}, 30_000

      runners = Locus.Runtime.Test.Runners.runners(Locus.Runtime.RunnerPool)
      assert [%{id: busy}] = for(%{state: :busy} = runner <- runners, do: runner)
      fresh = for %{state: :fresh, id: id} <- runners, do: id
      Agent.update(seen, fn _ -> %{busy: busy, fresh: fresh} end)
    end
  end

  describe "end_views/0" do
    setup tags do
      Sandbox.setup!(tags)
      {:ok, conn: Phoenix.ConnTest.build_conn()}
    end

    test "ends each view the test mounted and awaits the work the view started beside itself",
         %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, WorkingView, session: %{"test" => self()})
      assert_receive {:work, work}, 5_000

      # The view is the test supervisor's child under LiveView's own spec,
      # and its work names the test among its callers, not its ancestors.
      {:ok, supervisor} = ExUnit.fetch_test_supervisor()
      pid = view.pid

      assert Enum.any?(
               Supervisor.which_children(supervisor),
               &match?({_id, ^pid, :worker, [Phoenix.LiveView.Channel]}, &1)
             )

      {:dictionary, dictionary} = Process.info(work, :dictionary)
      assert self() in Keyword.fetch!(dictionary, :"$callers")
      refute supervisor in Keyword.get(dictionary, :"$ancestors", [])

      assert :ok = Sandbox.end_views()
      refute Process.alive?(pid)
      refute Process.alive?(work), "end_views/0 returned before the view's work ended"
    end

    test "fails at its deadline naming each process still running" do
      assert Sandbox.end_views_deadline_ms() < ExUnit.configuration()[:timeout]

      # Work the test started that never ends on its own.
      {:ok, work} =
        Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
          receive do: (:finish -> :ok)
        end)

      ref = Process.monitor(work)

      error = assert_raise ExUnit.AssertionError, fn -> Sandbox.end_views(200) end
      assert error.message =~ "200 ms deadline"
      assert error.message =~ inspect(work)

      send(work, :finish)
      assert_receive {:DOWN, ^ref, :process, ^work, :normal}, 5_000
    end

    test "a view stuck in its handle_info fails it at the deadline, named", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, WorkingView, session: %{"test" => self()})
      assert_receive {:work, _work}, 5_000
      send(view.pid, :stick)
      assert_receive {:stuck, pid}, 5_000

      error = assert_raise ExUnit.AssertionError, fn -> Sandbox.end_views(300) end
      assert error.message =~ "300 ms deadline"
      assert error.message =~ inspect(pid)

      # Released, it reads the stop it was sent.
      ref = Process.monitor(pid)
      send(pid, :release)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end

    test "every process still running at the deadline is named, not only the first" do
      works =
        for _ <- 1..2 do
          {:ok, work} =
            Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
              receive do: (:finish -> :ok)
            end)

          {work, Process.monitor(work)}
        end

      error = assert_raise ExUnit.AssertionError, fn -> Sandbox.end_views(200) end

      for {work, ref} <- works do
        assert error.message =~ inspect(work)
        send(work, :finish)
        assert_receive {:DOWN, ^ref, :process, ^work, :normal}, 5_000
      end
    end

    test "a view's stop and its work's end share one deadline", %{conn: conn} do
      # Each fits the deadline on its own; together they outlast it.
      {:ok, view, _html} =
        live_isolated(conn, WorkingView, session: %{"test" => self(), "work_ms" => 700})

      assert_receive {:work, work}, 5_000
      send(view.pid, {:busy, 700})
      assert_receive {:busy, _pid}, 5_000

      error = assert_raise ExUnit.AssertionError, fn -> Sandbox.end_views(1_000) end
      assert error.message =~ "1000 ms deadline"
      # The work, unless a loaded host kept the view's stop past it too.
      assert error.message =~ inspect(work) or error.message =~ inspect(view.pid)
    end
  end

  # The dynamic supervisors a sweep stops the children of.
  defp swept_by_stopping, do: repository_dynamic_supervisors() -- Sandbox.pooled()

  # A child that, told to stop, runs one query and reports how it went.
  defp last_query_child(name, collector) do
    %{
      id: name,
      restart: :temporary,
      start:
        {Task, :start_link,
         [
           fn ->
             Process.flag(:trap_exit, true)

             receive do
               {:EXIT, _supervisor, _reason} -> send(collector, {:report, name, last_query()})
             end
           end
         ]}
    }
  end

  # Starts a child that never ends and reports it, again and again.
  defp breed(collector) do
    send(collector, {:report, spawn(fn -> Process.sleep(:infinity) end), :started})
    for _ <- 1..500, do: :erlang.unique_integer()
    breed(collector)
  end

  # A task of the test's, as the attempt and its keeper are: it watches the
  # sibling it is told of and, once that one has ended, reports and makes
  # one write, holding the connection meanwhile when `hold?`.
  defp sibling(test, collector, name, hold?) do
    {:ok, pid} =
      Task.Supervisor.start_child(Sanctum.ProvisioningSupervisor, fn ->
        Process.flag(:priority, :high)

        if hold?,
          do: Arca.Repo.checkout(fn -> watch(test, collector, name) end),
          else: watch(test, collector, name)
      end)

    pid
  end

  defp watch(test, collector, name) do
    receive do
      {:watch, other} ->
        ref = Process.monitor(other)
        send(test, {:watching, self()})

        receive do
          {:DOWN, ^ref, :process, ^other, _reason} ->
            send(collector, {:report, name, :ran_after_its_sibling})
            send(collector, {:report, {name, :write}, last_query()})
        end
    end
  end

  defp last_query do
    Ecto.Adapters.SQL.query(Arca.Repo, "SELECT 1", [])
  rescue
    error -> {:error, error}
  end

  defp collect(reports) do
    receive do
      {:report, name, result} -> collect(Map.put(reports, name, result))
      {:reports, from} -> send(from, {:reports, reports})
    end
  end

  # The name of every dynamic supervisor in the trees of the started
  # applications whose callback module is this repository's source.
  defp repository_modules?(modules) when is_list(modules) and modules != [] do
    Enum.all?(modules, fn module ->
      source = Code.ensure_loaded?(module) && Keyword.get(module.module_info(:compile), :source)
      is_list(source) and String.starts_with?(List.to_string(source), @apps_root)
    end)
  end

  defp repository_modules?(_modules), do: false

  defp repository_dynamic_supervisors do
    for {app, _description, _vsn} <- Application.started_applications(),
        {module, _args} <- [Application.spec(app, :mod)],
        source = Keyword.get(module.module_info(:compile), :source),
        source && String.starts_with?(List.to_string(source), @apps_root),
        {:ok, top} <- [:application.get_supervisor(app)],
        pid <- dynamic_supervisors(top) do
      case Process.info(pid, :registered_name) do
        {:registered_name, name} when is_atom(name) and name != [] -> name
        _ -> flunk("an unnamed dynamic supervisor cannot be swept: #{inspect(pid)}")
      end
    end
  end

  # The tree the repository builds is walked: its `Supervisor.start_link/2`
  # groups, and a supervisor a module of the repository starts from a
  # function of its own (the runtime's service tree). A library's own supervisor
  # is not descended into, and a dynamic supervisor's children are the work
  # a sweep stops.
  defp dynamic_supervisors(supervisor) do
    Enum.flat_map(Supervisor.which_children(supervisor), fn
      {_id, pid, :supervisor, modules} when is_pid(pid) ->
        cond do
          dynamic?(pid) -> [pid]
          modules == [Supervisor] or repository_modules?(modules) -> dynamic_supervisors(pid)
          true -> []
        end

      _worker ->
        []
    end)
  end

  # A `Task.Supervisor` is a `DynamicSupervisor` too.
  defp dynamic?(pid), do: match?(%DynamicSupervisor{}, :sys.get_state(pid))
end
