# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.WorkerServicePoolTest do
  @moduledoc """
  The worker service over a pool whose runners a scripted keeper hands the
  test, in place of the running service's tree, reached through its
  listener where the wire is the point.

  A kill reaches only what a runner of this boot holds: the root of a
  runner's subtree ends that runner; a child its runner said it started
  is cancelled in that runner alone; an execution no runner holds or held
  is `:not_found` however busy the runners are, and an execution a runner
  of this boot ended, root or child, is `:ok` again. A runner that ends
  without an `exit` is reported holding its root and every child it said
  it started; so is one whose `exit` leaves out a child the service
  cancelled, and one that completes unclean after such a cancel, whether
  the cancel reached it as its child's holder or as a busy runner offered
  it. An unclean completion with no child cancelled is not reported. A
  caller that awaits the reports is answered once every one in flight is.

  An exit is reported under the runner the service assigned, whatever
  runner its frame names.

  A start none of which reached the runner it was given (the runner's
  relay gone, or going as the assign arrived, its handle gone, its channel
  closed before the write) is sent once more, to another runner, and the
  service lives through each. One that may have reached its runner is not,
  and the service lives through that too. A start whose first runner's
  keeper leaves its assign unanswered goes to another, and when that
  one's is left unanswered too is unavailable with its work written to
  neither runner, both retired. A start whose runner waits for the
  keeper's room is served once the keeper places it, past 5 s, while the
  service answers its status and kills, or refused `no_memory` with what
  holds the memory as the keeper said it, which the pool does not take for
  a keeper that refuses runners, and the next start is served once the
  keeper has room; one a
  kill reached is `:ok` to the kill and unavailable, its runner's place
  gone from the keeper's queue at the kill, whether its runner's assign
  was in flight or its take waited inside a pool that remembers a
  refusal. An assign that reached its runner before the kill was read
  is held all the same: the runner's exit is reported naming its root and
  the children it started.

  A keeper that refuses every runner makes the status report the
  refusal, with the keeper's reason and the sentence naming what the
  deployment lacks, beside the bound every runner would run under, and
  count no runner; a start is refused `503` `unavailable` with that
  sentence, and nothing of it is reported as a runner's exit, since no
  runner was given it. A keeper that refuses every runner's place for
  room at once, as on a machine with no room for one, is such a keeper:
  the status names `no_memory` with its sentence, and the pool backs off.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Prima.Test.Wait

  alias Prima.{RunnerControl, WorkerAPI, WorkerAuth, WorkerWire}
  alias Locus.Runtime.Test.{Runners, ScriptedHost, ScriptedKeeper}
  alias Locus.Runtime.WorkerService

  @bound 402_653_184

  setup tags do
    host = ScriptedHost.start!()
    # The running service's tree gives way to one whose pool this test's
    # keeper serves, and comes back when the test ends.
    :ok = Supervisor.terminate_child(Locus.Runtime.Supervisor, Locus.Runtime.WorkerService.Tree)
    previous = Locus.Runtime.Test.Env.merge(keeper: :direct, host_url: host.url)

    on_exit(fn ->
      Locus.Runtime.Test.Env.restore(previous, [:keeper, :host_url])

      {:ok, _pid} =
        Supervisor.restart_child(Locus.Runtime.Supervisor, Locus.Runtime.WorkerService.Tree)
    end)

    keeper = ScriptedKeeper.start!(__MODULE__.Keeper)
    if tags[:refusing], do: :ok = ScriptedKeeper.refuse(keeper, :memory_unavailable)

    # A machine whose W is under F: cyfr-locus refuses every runner's place
    # at once, since no empty pool could hold one.
    if tags[:no_room] do
      held = %{need: 171_966_464, free: 0, mine: [], others_bytes: 0}
      :ok = ScriptedKeeper.placing(keeper, {:refused, {:no_memory, held}})
    end

    {:ok, settings} = Locus.Runtime.Settings.pool([keeper: :direct], %{})

    start_supervised!(
      {DynamicSupervisor, name: Locus.Runtime.RunnerPool.Runners, strategy: :one_for_one}
    )

    start_supervised!(
      {Locus.Runtime.RunnerPool,
       settings: settings,
       keeper: ScriptedKeeper,
       keeper_opts: [memory_bytes: @bound, name: keeper],
       supervisor: Locus.Runtime.RunnerPool.Runners,
       command: %{argv: ["runner"], env: %{"KEEPER" => Atom.to_string(keeper)}}}
    )

    start_supervised!(WorkerService)

    server =
      start_supervised!(
        {Bandit,
         plug: Locus.Runtime.WorkerListener, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, %{boot: boot}} = WorkerService.status()

    {:ok, host: host, boot: boot, keeper: keeper, url: "http://127.0.0.1:#{port}"}
  end

  defp post(context, callback, args) do
    body = Jason.encode!(WorkerWire.request_body(callback, args))

    request = %{
      service: "wrk_local",
      boot: context.boot,
      ts: System.system_time(:millisecond),
      nonce: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    }

    {:ok, header} =
      WorkerAuth.request_header(ScriptedHost.dispatch_key(context.host), request, body)

    {:ok, %Req.Response{status: status, body: answer}} =
      Req.post(context.url <> WorkerWire.worker_route(callback),
        headers: [{WorkerWire.auth_header(), header}],
        body: body,
        retry: false,
        decode_body: false
      )

    {status, Jason.decode!(answer)}
  end

  defp start_args(attempt) do
    %{
      "assignment" => attempt.assignment,
      "input" => attempt.input,
      "sealed_keys" => attempt.sealed_keys
    }
  end

  # A subtree started on a runner of the scripted keeper: the attempt and
  # the runner's spawn, whose channel the test writes and reads.
  defp started!(context) do
    attempt = ScriptedHost.attempt!(context.host, boot: context.boot)
    assert {200, %{"ok" => true}} = post(context, :start, start_args(attempt))

    spawn =
      Enum.find(ScriptedKeeper.spawns(context.keeper), fn spawn ->
        String.contains?(ScriptedKeeper.read(spawn), attempt.assignment)
      end)

    {attempt, spawn}
  end

  # The fresh runner the pool hands out to the next start.
  defp waiting!(context) do
    fresh = fn ->
      Enum.find(Runners.runners(Locus.Runtime.RunnerPool), &(&1.state == :fresh))
    end

    wait_until(fn -> fresh.() != nil end, 5_000, "a fresh runner")
    %{pid: handle} = fresh.()
    Enum.find(ScriptedKeeper.spawns(context.keeper), &(&1.owner == handle))
  end

  defp given(context, attempt) do
    for spawn <- ScriptedKeeper.spawns(context.keeper),
        String.contains?(ScriptedKeeper.read(spawn), attempt.assignment),
        do: spawn
  end

  defp assert_given_to_another(context, dead, attempt) do
    wait_until(fn -> given(context, attempt) != [] end)
    assert [other] = given(context, attempt)
    refute other.ref == dead.ref
    assert attempt.attempt in elem(WorkerService.status(), 1).attempts
  end

  defp queued(pid), do: elem(Process.info(pid, :message_queue_len), 1)

  defp write(spawn, message), do: ScriptedKeeper.write(spawn, RunnerControl.encode(message))

  defp cancels(spawn) do
    for line <- String.split(ScriptedKeeper.read(spawn), "\n", trim: true),
        {:ok, %{type: :cancel_child, execution_id: id}} <- [RunnerControl.decode(line)],
        do: id
  end

  describe "a start that reached no runner" do
    @tag :capture_log
    test "is sent to another when the runner's relay had ended", context do
      attempt = ScriptedHost.attempt!(context.host, boot: context.boot)
      dead = waiting!(context)
      :ok = ScriptedKeeper.end_relay(dead)
      wait_until(fn -> :sys.get_state(dead.owner).relay == nil end)

      assert {200, %{"ok" => true}} = post(context, :start, start_args(attempt))
      assert_given_to_another(context, dead, attempt)
    end

    @tag :capture_log
    test "is sent to another when the relay ends as the assign arrives", context do
      attempt = ScriptedHost.attempt!(context.host, boot: context.boot)
      dead = waiting!(context)
      service = Process.whereis(WorkerService)

      :ok = :sys.suspend(dead.owner)
      :ok = ScriptedKeeper.end_relay(dead)
      started = Task.async(fn -> post(context, :start, start_args(attempt)) end)
      # The relay's end, then the assign.
      wait_until(fn -> queued(dead.owner) >= 2 end)
      :ok = :sys.resume(dead.owner)

      assert {200, %{"ok" => true}} = Task.await(started, 15_000)
      assert Process.whereis(WorkerService) == service
      assert_given_to_another(context, dead, attempt)
    end

    @tag :capture_log
    test "is sent to another when the runner's handle went as it was handed out", context do
      attempt = ScriptedHost.attempt!(context.host, boot: context.boot)
      dead = waiting!(context)
      service = Process.whereis(WorkerService)
      pool = Process.whereis(Locus.Runtime.RunnerPool)

      :ok = :sys.suspend(pool)
      started = Task.async(fn -> post(context, :start, start_args(attempt)) end)
      # The take, then the handle's end behind it.
      wait_until(fn -> queued(pool) >= 1 end)
      monitor = Process.monitor(dead.owner)
      Process.exit(dead.owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, _pid, :killed}, 5_000
      :ok = :sys.resume(pool)

      assert {200, %{"ok" => true}} = Task.await(started, 15_000)
      assert Process.whereis(WorkerService) == service
      assert_given_to_another(context, dead, attempt)
    end

    for reason <- [:control_closed, :unknown_runner, :einval] do
      @reason reason
      @tag :capture_log
      test "is sent to another when the write was refused #{reason}", context do
        attempt = ScriptedHost.attempt!(context.host, boot: context.boot)
        dead = waiting!(context)
        :ok = ScriptedKeeper.refuse_write(dead, @reason)

        assert {200, %{"ok" => true}} = post(context, :start, start_args(attempt))
        assert_given_to_another(context, dead, attempt)
      end
    end

    @tag :capture_log
    test "is not sent again when the write may have arrived", context do
      attempt = ScriptedHost.attempt!(context.host, boot: context.boot)
      dead = waiting!(context)
      :ok = ScriptedKeeper.refuse_write(dead, :closed)

      assert {503, %{"error" => "unavailable"}} = post(context, :start, start_args(attempt))
      assert given(context, attempt) == []
    end

    @tag :capture_log
    test "is not sent again when the handle died holding it, and the service lives", context do
      attempt = ScriptedHost.attempt!(context.host, boot: context.boot)
      dead = waiting!(context)
      service = Process.whereis(WorkerService)

      :ok = :sys.suspend(dead.owner)
      started = Task.async(fn -> post(context, :start, start_args(attempt)) end)
      # The handle has the assign and can answer nothing of it.
      wait_until(fn -> queued(dead.owner) >= 1 end)
      Process.exit(dead.owner, :kill)

      assert {503, %{"error" => "unavailable"}} = Task.await(started, 15_000)
      assert Process.whereis(WorkerService) == service
      assert given(context, attempt) == []
    end

    @tag :capture_log
    @tag timeout: 30_000
    test "is given another when its keeper leaves the first assign unanswered, and when the second's is left too is unavailable, its work written to neither runner and neither offered again",
         context do
      attempt = ScriptedHost.attempt!(context.host, boot: context.boot)
      first = waiting!(context).spec.runner
      :ok = ScriptedKeeper.assigning(context.keeper, :held)
      started = Task.async(fn -> post(context, :start, start_args(attempt)) end)

      # The first runner's assign is held past its wait, and the start goes
      # on to another runner, whose assign is held too.
      held = fn -> Enum.map(ScriptedKeeper.held_assigns(context.keeper), &elem(&1, 0)) end
      wait_until(fn -> held.() == [first] end, 5_000, "the first runner's assign held")

      wait_until(
        fn -> match?([_], held.() -- [first]) end,
        10_000,
        "a second runner's assign held"
      )

      [second] = held.()

      assert {503, %{"error" => "unavailable"}} = Task.await(started, 15_000)

      # The second runner's answer arrives past its assign's wait. The
      # status is read once the service has done with the start.
      :ok = ScriptedKeeper.assigning(context.keeper, :answered)
      :ok = ScriptedKeeper.answer_assigns(context.keeper)
      {:ok, status} = WorkerService.status()
      spawns = ScriptedKeeper.spawns(context.keeper)

      written =
        for runner <- [first, second],
            do: spawns |> Enum.find(&(&1.spec.runner == runner)) |> ScriptedKeeper.read()

      assert written == ["", ""]
      assert status.attempts == []

      wait_until(
        fn ->
          released = Enum.map(ScriptedKeeper.releases(context.keeper), &elem(&1, 0))
          Enum.all?([first, second], &(&1 in released))
        end,
        5_000,
        "both runners released"
      )

      # Neither runner is offered again: the next start runs on a third.
      later = ScriptedHost.attempt!(context.host, boot: context.boot)
      assert {200, %{"ok" => true}} = post(context, :start, start_args(later))
      assert [%{spec: %{runner: third}}] = given(context, later)
      refute third in [first, second]
    end

    @tag :capture_log
    test "is sent once more and no further", context do
      # An idle runner of the athanor and a fresh one, neither writable.
      {done, idle} = started!(context)
      write(idle, %{type: :complete, execution_id: done.execution_id, clean: true})
      wait_until(fn -> elem(WorkerService.status(), 1).runners.idle == 1 end)
      fresh = waiting!(context)
      :ok = ScriptedKeeper.refuse_write(idle, :control_closed)
      :ok = ScriptedKeeper.refuse_write(fresh, :control_closed)

      attempt = ScriptedHost.attempt!(context.host, boot: context.boot)
      assert {503, %{"error" => "unavailable"}} = post(context, :start, start_args(attempt))
      assert given(context, attempt) == []
      assert elem(WorkerService.status(), 1).attempts == []
    end
  end

  describe "a start whose runner waits for the keeper's room" do
    # The fresh runner, placed before the keeper holds every place, goes to
    # a first start, and the runner the pool spawns behind it waits for its
    # place, which a second start is given.
    defp waiting_for_room!(context) do
      waiting!(context)
      :ok = ScriptedKeeper.placing(context.keeper, :held)
      started!(context)
      wait_until(fn -> ScriptedKeeper.held_places(context.keeper) != [] end)
      attempt = ScriptedHost.attempt!(context.host, boot: context.boot)
      {attempt, Task.async(fn -> post(context, :start, start_args(attempt)) end)}
    end

    @tag timeout: 60_000
    test "is served once the keeper places the runner past 5 s, and the service answers its status and kills meanwhile",
         context do
      {attempt, started} = waiting_for_room!(context)
      wait_until(fn -> map_size(:sys.get_state(WorkerService).assigning) == 1 end)

      assert {:ok, %{attempts: [_first]}} = WorkerService.status()
      assert WorkerService.kill("exec_nobody_holds") == {:error, :not_found}
      assert Task.yield(started, 6_000) == nil

      :ok = ScriptedKeeper.answer_places(context.keeper, :ok)
      assert {200, %{"ok" => true}} = Task.await(started, 15_000)
      assert [_spawn] = given(context, attempt)
      assert attempt.attempt in elem(WorkerService.status(), 1).attempts
    end

    @tag :capture_log
    @tag timeout: 60_000
    test "is refused no_memory with what holds the memory as the keeper said it, never at 5 s, " <>
           "and the next start is served once there is room",
         context do
      {attempt, started} = waiting_for_room!(context)
      wait_until(fn -> map_size(:sys.get_state(WorkerService).assigning) == 1 end)
      [%{runner: runner}] = Map.values(:sys.get_state(WorkerService).assigning)
      assert Task.yield(started, 6_000) == nil

      # Other work fills the room: a runner's place is nobody's until its
      # work is assigned, so all of it is one sum.
      held = %{need: 171_966_464, free: 0, mine: [], others_bytes: 2_147_483_648}

      # Only the taken runner's place is refused: the pool's own refill
      # behind it, refused for room, would be the pool's refusal.
      log =
        capture_log(fn ->
          :ok = ScriptedKeeper.answer_place(context.keeper, runner, {:error, {:no_memory, held}})

          assert {503, answer} = Task.await(started, 15_000)

          assert answer == %{
                   "v" => WorkerWire.version(),
                   "error" => "no_memory",
                   "held" => Prima.LocusPool.encode_held(held)
                 }

          # The refusal was that start's alone: the keeper still starts
          # runners, and the pool and the worker's status say none refused.
          assert {:ok, %{refusal: nil}} = WorkerService.status()
        end)

      refute log =~ "the keeper refuses runners"
      assert given(context, attempt) == []
      refute attempt.attempt in elem(WorkerService.status(), 1).attempts

      # Room again: the next start's runner is placed and given its work.
      next = ScriptedHost.attempt!(context.host, boot: context.boot)
      again = Task.async(fn -> post(context, :start, start_args(next)) end)
      wait_until(fn -> ScriptedKeeper.held_places(context.keeper) != [] end)
      :ok = ScriptedKeeper.answer_places(context.keeper, :ok)
      assert {200, %{"ok" => true}} = Task.await(again, 15_000)
      assert [_spawn] = given(context, next)
    end

    @tag :capture_log
    @tag timeout: 60_000
    test "is unavailable once a kill reached it, its runner's place gone from the keeper's queue at the kill and its work given to no runner",
         context do
      {attempt, started} = waiting_for_room!(context)
      wait_until(fn -> map_size(:sys.get_state(WorkerService).assigning) == 1 end)
      [%{runner: runner}] = Map.values(:sys.get_state(WorkerService).assigning)
      assert runner in ScriptedKeeper.held_places(context.keeper)

      assert post(context, :kill, %{"execution_id" => attempt.execution_id}) ==
               {200, %{"ok" => true, "v" => 3}}

      # The place leaves the queue before the keeper finds room for anyone.
      wait_until(fn -> runner not in ScriptedKeeper.held_places(context.keeper) end)
      assert {503, %{"error" => "unavailable"} = refused} = Task.await(started, 15_000)
      refute Map.has_key?(refused, "message")

      :ok = ScriptedKeeper.answer_places(context.keeper, :ok)
      assert given(context, attempt) == []
      refute attempt.attempt in elem(WorkerService.status(), 1).attempts
    end

    @tag :refusing
    @tag :capture_log
    @tag timeout: 60_000
    test "is unavailable once a kill reached its take waiting on a refused pool, its runner's place gone from the keeper's queue at the kill",
         context do
      wait_until(fn -> match?({:ok, %{refusal: %{}}}, WorkerService.status()) end, 5_000)
      :ok = ScriptedKeeper.refuse(context.keeper, nil)
      :ok = ScriptedKeeper.placing(context.keeper, :held)
      attempt = ScriptedHost.attempt!(context.host, boot: context.boot)
      started = Task.async(fn -> post(context, :start, start_args(attempt)) end)

      # The pool remembers the refusal, so the take waits on a runner of its
      # own, whose place waits for room.
      waiter = fn ->
        :sys.get_state(Locus.Runtime.RunnerPool).runners
        |> Map.values()
        |> Enum.find(&(&1.waiter != nil and &1.waiter.execution_id == attempt.execution_id))
      end

      wait_until(fn -> waiter.() != nil end, 5_000, "the take's runner")
      %{id: runner} = waiter.()
      wait_until(fn -> runner in ScriptedKeeper.held_places(context.keeper) end)
      assert :gen_server.reqids_size(:sys.get_state(WorkerService).takes) == 1

      assert post(context, :kill, %{"execution_id" => attempt.execution_id}) ==
               {200, %{"ok" => true, "v" => 3}}

      # The place leaves the queue before the keeper finds room for anyone.
      wait_until(fn -> runner not in ScriptedKeeper.held_places(context.keeper) end)
      assert {503, %{"error" => "unavailable"} = refused} = Task.await(started, 15_000)
      refute Map.has_key?(refused, "message")

      :ok = ScriptedKeeper.answer_places(context.keeper, :ok)
      assert given(context, attempt) == []
      refute attempt.attempt in elem(WorkerService.status(), 1).attempts
    end
  end

  describe "a kill" do
    # The assign has reached the runner and its outcome waits in its task,
    # held there, when the kill is read; the runner, released with its
    # grace, starts a child and exits naming it before the outcome is read.
    @tag :capture_log
    test "read after its start's assign reached the runner and before the outcome was read: the runner's exit is reported naming its root and its child",
         context do
      attempt = ScriptedHost.attempt!(context.host, boot: context.boot)
      runner = waiting!(context)
      :ok = ScriptedKeeper.assigning(context.keeper, :held)
      started = Task.async(fn -> post(context, :start, start_args(attempt)) end)
      wait_until(fn -> ScriptedKeeper.held_assigns(context.keeper) != [] end)

      [%{task: %Task{pid: task}}] = Map.values(:sys.get_state(WorkerService).assigning)
      true = :erlang.suspend_process(task)

      try do
        :ok = ScriptedKeeper.answer_assigns(context.keeper)
        wait_until(fn -> String.contains?(ScriptedKeeper.read(runner), attempt.assignment) end)

        assert post(context, :kill, %{"execution_id" => attempt.execution_id}) ==
                 {200, %{"ok" => true, "v" => 3}}

        write(runner, %{type: :child, execution_id: "exec_child", attempt: "att_child"})
        write(runner, %{type: :exit, runner: runner.spec.runner, open: [attempt.attempt]})

        wait_until(fn ->
          [a] = Map.values(:sys.get_state(WorkerService).assigning)
          length(a.buffered) == 2
        end)
      after
        :erlang.resume_process(task)
      end

      assert {503, %{"error" => "unavailable"}} = Task.await(started, 15_000)
      assert [%{args: %{"attempts" => held}}] = reports(context)
      assert Enum.sort(held) == Enum.sort([attempt.attempt, "att_child"])
    end

    test "reaches the runner holding a child alone, and finds nothing no runner holds", context do
      {root, runner} = started!(context)
      {_other, other_runner} = started!(context)

      write(runner, %{type: :child, execution_id: "exec_child", attempt: "att_child"})
      wait_until(fn -> "att_child" in elem(WorkerService.status(), 1).attempts end)

      # A child its runner said it started: that runner, and only it, is told.
      assert {200, %{"ok" => true}} =
               post(context, :kill, %{"execution_id" => "exec_child"})

      wait_until(fn -> cancels(runner) == ["exec_child"] end)
      assert cancels(other_runner) == []

      # Nobody's: not found, busy as the runners are.
      assert {200, %{"error" => "not_found"}} =
               post(context, :kill, %{"execution_id" => "exec_nobody_ran"})

      # Once the subtree completes, root and child are ended for this boot.
      write(runner, %{type: :complete, execution_id: root.execution_id, clean: false})
      wait_until(fn -> "att_child" not in elem(WorkerService.status(), 1).attempts end)

      for id <- [root.execution_id, "exec_child"] do
        assert {200, %{"ok" => true}} = post(context, :kill, %{"execution_id" => id})
      end

      assert {200, %{"error" => "not_found"}} =
               post(context, :kill, %{"execution_id" => "exec_nobody_ran"})
    end

    test "a runner that ends without an exit is reported holding its root and its children",
         context do
      {root, runner} = started!(context)
      write(runner, %{type: :child, execution_id: "exec_child", attempt: "att_child"})
      wait_until(fn -> "att_child" in elem(WorkerService.status(), 1).attempts end)

      ScriptedKeeper.exit(runner, 137)

      wait_until(fn -> ScriptedHost.requests(context.host, "runner_exited") != [] end, 5_000)

      assert [%{args: %{"attempts" => held} = args}] =
               ScriptedHost.requests(context.host, "runner_exited")

      assert Enum.sort(held) == Enum.sort([root.attempt, "att_child"])
      refute Map.has_key?(args, "refusal")
    end

    # The pool tells a runner's assignee the keeper's refusal of it
    # (`Locus.Runtime.RunnerPool`, "A keeper that refuses runners").
    test "a runner the keeper refused after the start was answered is reported with its refusal's code",
         context do
      {root, runner} = started!(context)
      refusal = %{reason: "capacity", message: "the scripted keeper refuses (capacity)"}
      send(WorkerService, {Locus.Runtime.RunnerPool, runner.owner, {:gone, {:refused, refusal}}})

      wait_until(fn -> ScriptedHost.requests(context.host, "runner_exited") != [] end, 5_000)

      assert [%{args: %{"attempts" => [attempt], "refusal" => wire}}] =
               ScriptedHost.requests(context.host, "runner_exited")

      assert attempt == root.attempt
      assert wire == "capacity"
    end

    test "a cancelled child the runner's exit leaves out is reported with its root", context do
      {root, runner} = started!(context)
      id = runner_id(root)
      write(runner, %{type: :child, execution_id: "exec_child", attempt: "att_child"})
      write(runner, %{type: :child, execution_id: "exec_other", attempt: "att_other"})
      wait_until(fn -> "att_other" in elem(WorkerService.status(), 1).attempts end)

      assert {200, %{"ok" => true}} = post(context, :kill, %{"execution_id" => "exec_child"})
      wait_until(fn -> cancels(runner) == ["exec_child"] end)

      # The runner no longer speaks for the child it cancelled, and names
      # only what it still held when it ended.
      write(runner, %{type: :exit, runner: id, open: [root.attempt]})

      assert [%{args: %{"attempts" => held}}] = reports(context)
      assert Enum.sort(held) == Enum.sort([root.attempt, "att_child", "att_other"])
    end

    test "an exit is reported under the runner the service assigned", context do
      {root, runner} = started!(context)
      assigned = runner_id(root)
      write(runner, %{type: :exit, runner: "runner_named_in_the_frame", open: [root.attempt]})

      assert [%{args: %{"attempts" => held, "runner" => reported}}] = reports(context)
      assert reported == assigned
      assert held == [root.attempt]
    end

    test "a child's cancel then the runner's unclean completion is reported, naming the child",
         context do
      {root, runner} = started!(context)
      id = runner_id(root)
      write(runner, %{type: :child, execution_id: "exec_child", attempt: "att_child"})
      wait_until(fn -> "att_child" in elem(WorkerService.status(), 1).attempts end)

      assert {200, %{"ok" => true}} = post(context, :kill, %{"execution_id" => "exec_child"})
      wait_until(fn -> cancels(runner) == ["exec_child"] end)
      write(runner, %{type: :complete, execution_id: root.execution_id, clean: false})

      assert [%{args: %{"attempts" => held, "runner" => reported}}] = reports(context)
      assert Enum.sort(held) == Enum.sort([root.attempt, "att_child"])
      assert reported == id
      wait_until(fn -> elem(WorkerService.status(), 1).attempts == [] end)
    end

    test "a child cancelled only by the offer to every busy runner is reported too", context do
      {root, runner} = started!(context)

      # Its runner's word of the child has not arrived: the kill is offered
      # to every busy runner, and this one cancels it.
      assert {200, %{"error" => "not_found"}} =
               post(context, :kill, %{"execution_id" => "exec_child"})

      wait_until(fn -> cancels(runner) == ["exec_child"] end)
      write(runner, %{type: :child, execution_id: "exec_child", attempt: "att_child"})
      write(runner, %{type: :complete, execution_id: root.execution_id, clean: false})

      assert [%{args: %{"attempts" => held}}] = reports(context)
      assert Enum.sort(held) == Enum.sort([root.attempt, "att_child"])
    end

    test "an unclean completion with no child cancelled is not reported", context do
      {root, runner} = started!(context)
      write(runner, %{type: :child, execution_id: "exec_child", attempt: "att_child"})
      write(runner, %{type: :complete, execution_id: root.execution_id, clean: false})

      wait_until(fn -> elem(WorkerService.status(), 1).attempts == [] end)
      assert :ok = Runners.await_reports()
      assert ScriptedHost.requests(context.host, "runner_exited") == []
    end
  end

  # The one runner exit report the host received, once it has.
  defp reports(context) do
    wait_until(fn -> ScriptedHost.requests(context.host, "runner_exited") != [] end, 5_000)
    assert :ok = Runners.await_reports()
    ScriptedHost.requests(context.host, "runner_exited")
  end

  # The id of the pool's runner that took `attempt`'s subtree.
  defp runner_id(attempt) do
    Locus.Runtime.RunnerPool
    |> Runners.runners()
    |> Enum.find_value(&(&1.execution_id == attempt.execution_id && &1.id))
  end

  test "awaiting the reports answers once every report in flight is answered", context do
    hold_reports!(context)
    assert :ok = Runners.await_reports()

    {_root, runner} = started!(context)
    ScriptedKeeper.exit(runner, 137)
    assert_receive {:report_held, held}, 5_000

    waiting = Task.async(fn -> Runners.await_reports() end)
    assert Task.yield(waiting, 200) == nil
    send(held, :go)
    assert Task.await(waiting, 5_000) == :ok
  end

  # A report held by the scripted host: `runner_exited` answers once the
  # test sends the holder `:go`.
  defp hold_reports!(context) do
    test = self()

    ScriptedHost.script(context.host, "runner_exited", fn _args, _caller ->
      send(test, {:report_held, self()})

      receive do
        :go -> {:ok, true}
      after
        10_000 -> {:ok, true}
      end
    end)
  end

  # The service holds a report from the callback that starts it: one
  # stopped before it has run a single instruction is in flight all the
  # same, and a test's end waits for it. The report is caught at its
  # spawn: with one normal scheduler and this test at the highest
  # priority, the trace message runs the test before the report is ever
  # scheduled, which its zero reductions confirm.
  test "a report is in flight from its start, before it has run", context do
    hold_reports!(context)
    assert :ok = Runners.await_reports()
    service = Process.whereis(WorkerService)
    {_root, runner} = started!(context)

    1 = :erlang.trace(service, true, [:procs])
    :blocked_normal = :erlang.system_flag(:multi_scheduling, :block_normal)
    priority = Process.flag(:priority, :max)

    report =
      try do
        ScriptedKeeper.exit(runner, 137)

        receive do
          {:trace, ^service, :spawn, report, _mfa} ->
            true = :erlang.suspend_process(report)
            report
        after
          5_000 -> flunk("the service started no report")
        end
      after
        Process.flag(:priority, priority)
        :erlang.system_flag(:multi_scheduling, :unblock_normal)
        :erlang.trace(service, false, [:procs])
      end

    try do
      assert Process.info(report, :reductions) == {:reductions, 0}
      assert report in Runners.reports_in_flight()

      waiting = Task.async(fn -> Runners.await_reports() end)
      assert Task.yield(waiting, 200) == nil

      true = :erlang.resume_process(report)
      assert_receive {:report_held, held}, 5_000
      assert Task.yield(waiting, 200) == nil
      send(held, :go)
      assert Task.await(waiting, 5_000) == :ok
    after
      # A suspended report is resumed whatever failed above.
      if match?({:status, :suspended}, Process.info(report, :status)),
        do: :erlang.resume_process(report)
    end
  end

  # A report is the service's: it ends with the service, however the
  # service ends, so none outlives the boot it reports for and a test's
  # end never waits on one nothing holds.
  test "a report ends with its service when the service stops", context do
    {report, held} = held_report!(context)
    ref = Process.monitor(report)

    :ok = stop_supervised(WorkerService)

    assert_receive {:DOWN, ^ref, :process, ^report, _reason}, 5_000
    send(held, :go)
  end

  test "a report ends with its service when the service is killed", context do
    {report, held} = held_report!(context)
    ref = monitored!(report)
    service = Process.whereis(WorkerService)

    Process.exit(service, :kill)

    assert_receive {:DOWN, ^ref, :process, ^report, :killed}, 5_000
    send(held, :go)

    # The service the suite's supervisor starts again holds no report.
    wait_until(fn -> Process.whereis(WorkerService) not in [nil, service] end)
    assert :ok = Runners.await_reports()
  end

  # A runner's exit, its report held by the scripted host: the report's
  # pid and the holder.
  defp held_report!(context) do
    hold_reports!(context)
    {_root, runner} = started!(context)
    ScriptedKeeper.exit(runner, 137)
    assert_receive {:report_held, held}, 5_000
    assert [report] = Runners.reports_in_flight()
    {report, held}
  end

  # The barrier is there because `Process.monitor/1` returns before its
  # signal reaches the report, so a kill that ends the report through its
  # link can land first and leave the monitor answering `:noproc`.
  defp monitored!(report) do
    ref = Process.monitor(report)
    assert {:monitored_by, monitors} = Process.info(report, :monitored_by)
    assert self() in monitors
    ref
  end

  @tag :no_room
  @tag :capture_log
  @tag timeout: 30_000
  test "a keeper that refuses every runner's place for room: the status names no_memory with its sentence, and the pool backs off",
       context do
    wait_until(fn -> match?({:ok, %{refusal: %{}}}, WorkerService.status()) end, 5_000)

    # The status names why, never what holds the memory.
    assert {:ok, %{runners: %{fresh: 0, idle: 0, busy: 0, tainted: 0}, refusal: refusal}} =
             WorkerService.status()

    assert refusal == %{
             reason: "no_memory",
             message: "cyfr-locus refused to start a runner (no_memory)"
           }

    # The tries after the first wait one second, then two: never one a
    # second for ever.
    asked = ScriptedKeeper.places_refused(context.keeper)
    # sleep-ok: the pool's pace over four seconds is what is asserted
    Process.sleep(4_000)
    assert ScriptedKeeper.places_refused(context.keeper) - asked <= 2
    assert {:ok, %{refusal: %{reason: "no_memory"}}} = WorkerService.status()
  end

  @tag :refusing
  test "a keeper that refuses runners: the status says why, and a start is refused 503 naming it",
       context do
    wait_until(fn -> match?({:ok, %{refusal: %{}}}, WorkerService.status()) end, 5_000)

    assert {200, %{"ok" => wire}} = post(context, :status, %{})

    assert {:ok,
            %{
              runners: %{fresh: 0, idle: 0, busy: 0, tainted: 0},
              memory_bytes: @bound,
              refusal: %{reason: "memory_unavailable", message: message},
              attempts: []
            }} = WorkerAPI.read_status(wire)

    attempt = ScriptedHost.attempt!(context.host, boot: context.boot)

    assert {503, %{"error" => "unavailable", "message" => ^message}} =
             post(context, :start, start_args(attempt))

    assert {200, %{"ok" => %{"attempts" => [], "runners" => %{"tainted" => 0}}}} =
             post(context, :status, %{})

    assert ScriptedHost.requests(context.host) == []
  end
end
