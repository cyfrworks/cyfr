# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.RunnerBoundaryTest do
  @moduledoc """
  The worker service over its runner boundary, with the direct launcher:
  each runner is the runner program this checkout built, a process of its
  own that attaches, runs the subtree and reports over the control
  channel. The service loads no component. A clean completion leaves the
  runner idle for its athanor, and the next subtree of that athanor reuses
  it; another athanor gets a fresh one. A root kill ends the runner's
  process and reports its exit once; a host answer that is lost taints the
  runner; a close CYFR holds past the assignment's deadline and the grace
  is ended by the service's watch, which releases the runner and reports
  it once, and leaves alone a runner whose hold ended first, however it
  ended; a guest stopped at its timeout taints its runner; the service's
  handle dying reaps the runner.
  """

  use ExUnit.Case, async: false

  import Prima.Test.Wait

  alias Locus.Runtime.Test.{Runners, ScriptedHost}
  alias Locus.Runtime.{RunnerPool, RunnerProcess, WorkerService}

  @moduletag timeout: 90_000

  @echo File.read!(Path.expand("../../support/runtime/test_wasm/echo.wasm", __DIR__))
  @spin File.read!(Path.expand("../../support/runtime/test_wasm/spin.wasm", __DIR__))

  # A runner's first attach, bounded for a loaded host.
  @boot_ms 30_000

  @settings [:keeper, :idle_ttl_ms, :watchdog_grace_ms, :release_grace_ms]

  setup context do
    previous =
      Locus.Runtime.Test.Env.merge(
        keeper: :direct,
        idle_ttl_ms: 30_000,
        watchdog_grace_ms: context[:watchdog_grace_ms] || 1_000,
        release_grace_ms: 1_000
      )

    host = ScriptedHost.start!()
    boot = ScriptedHost.serve!(host)

    # Registered after `serve!/1`'s, so it runs first: the service the
    # host's restart brings back runs under the suite's settings again.
    on_exit(fn -> Locus.Runtime.Test.Env.restore(previous, @settings) end)

    {:ok, host: host, boot: boot}
  end

  defp start(attempt),
    do: WorkerService.start(attempt.assignment, attempt.input, attempt.sealed_keys)

  defp echo!(host, boot, opts \\ []) do
    ScriptedHost.script(host, "fetch_artifact", {:ok, Base.encode64(@echo)})

    ScriptedHost.attempt!(
      host,
      [boot: boot, component_type: :reagent, digest: Prima.Digest.sha256(@echo)] ++ opts
    )
  end

  defp spin!(host, boot, opts \\ []) do
    ScriptedHost.script(host, "fetch_artifact", {:ok, Base.encode64(@spin)})

    ScriptedHost.attempt!(
      host,
      [boot: boot, component_type: :reagent, digest: Prima.Digest.sha256(@spin)] ++ opts
    )
  end

  defp runners, do: elem(WorkerService.status(), 1).runners

  defp busy_runner do
    RunnerPool |> Runners.runners() |> Enum.find(&(&1.state == :busy))
  end

  defp os_pid(%{pid: pid}), do: RunnerProcess.info(pid).os_pid

  # The pool's one runner once it has attached, before any take.
  defp fresh_runner! do
    wait_until(
      fn -> match?([%{state: :fresh}], Runners.runners(RunnerPool)) end,
      @boot_ms,
      "the pool's runner to attach"
    )

    [runner] = Runners.runners(RunnerPool)
    runner
  end

  defp alive?(os_pid) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)],
           stderr_to_stdout: true,
           env: Locus.Test.ProcessFamily.no_env()
         ) do
      {_, 0} -> true
      _ -> false
    end
  end

  # Each request of `op` is held for as long as the test lives and no
  # longer: a request still parked when the test ends would hold the
  # scripted host's stop.
  defp hold_while_alive(host, op) do
    test = self()

    ScriptedHost.script(host, op, fn _args, _caller ->
      ref = Process.monitor(test)
      receive do: ({:DOWN, ^ref, :process, ^test, _reason} -> {:ok, "held"})
    end)
  end

  # What the service holds for the runner `handle`, its watch among it.
  defp held_by!(handle) do
    %{assigned: assigned} = :sys.get_state(WorkerService)
    Map.fetch!(assigned, handle)
  end

  defp first_deadline(attempt) do
    {:ok, assignment} = Prima.Assignment.read(attempt.assignment)
    assignment.deadline
  end

  defp attach_runners(host),
    do: for(%{caller: %{runner: runner}} <- ScriptedHost.requests(host, "attach"), do: runner)

  test "the service role loads no component: every runner is the runner program" do
    {:ok, settings} = Locus.Runtime.Settings.pool([keeper: :direct], %{})
    service = Locus.Runtime.children(:service, settings)

    assert Locus.Runtime.Settings.runner_command() ==
             %{argv: ["/usr/local/bin/cyfr-runner"], env: %{}}

    assert Enum.any?(service, &match?(%{id: Locus.Runtime.WorkerListener}, &1))

    tree = Locus.Runtime.service_tree(settings)
    assert Enum.any?(tree, &match?(%{id: Locus.DirectLauncher.Runner}, &1))
    assert Locus.Runtime.Events in tree
    assert Enum.any?(tree, &match?({Locus.Runtime.RunnerPool, _}, &1))
    assert Locus.Runtime.WorkerService in tree

    # What the service hands a runner: its identities, and nothing else.
    assert Locus.Runtime.Settings.runner_environment(%{
             runner_id: "run_x",
             service_id: "wrk_x",
             boot: "boot_x"
           }) == %{
             "RUNTIME_RUNNER_ID" => "run_x",
             "RUNTIME_SERVICE_ID" => "wrk_x",
             "RUNTIME_BOOT_ID" => "boot_x"
           }
  end

  test "a subtree runs in a runner's VM, completes cleanly, and its runner is reused for its athanor only",
       %{host: host, boot: boot} do
    first = echo!(host, boot, input: %{"hello" => "world"})
    assert :ok = start(first)

    wait_until(fn -> ScriptedHost.requests(host, "complete") != [] end, @boot_ms)

    assert [%{args: %{"outcome" => %{"output" => %{"hello" => "world"}}}, caller: caller}] =
             ScriptedHost.requests(host, "complete")

    assert caller.boot == boot
    assert [runner] = attach_runners(host)
    assert caller.runner == runner

    wait_until(fn -> match?(%{busy: 0, idle: 1}, runners()) end, 5_000)
    assert %{tainted: 0} = runners()
    assert {:ok, %{attempts: []}} = WorkerService.status()
    assert ScriptedHost.requests(host, "runner_exited") == []

    second = echo!(host, boot, input: %{"again" => true})
    assert :ok = start(second)
    wait_until(fn -> length(ScriptedHost.requests(host, "complete")) == 2 end, @boot_ms)
    assert [^runner, ^runner] = attach_runners(host)

    other = echo!(host, boot, athanor_id: "ath_other", input: %{"elsewhere" => true})
    assert :ok = start(other)
    wait_until(fn -> length(ScriptedHost.requests(host, "complete")) == 3 end, @boot_ms)
    assert [^runner, ^runner, fresh] = attach_runners(host)
    assert fresh != runner
    wait_until(fn -> match?(%{busy: 0, idle: 2}, runners()) end, 5_000)
  end

  test "the status has the contract's shape", %{host: host, boot: boot} do
    {:ok, status} = WorkerService.status()
    assert Prima.WorkerAPI.valid_status?(status)

    assert :ok = start(spin!(host, boot))
    wait_until(fn -> ScriptedHost.requests(host, "attach") != [] end, @boot_ms)
    {:ok, status} = WorkerService.status()
    assert Prima.WorkerAPI.valid_status?(status)
    assert %{busy: 1} = status.runners
  end

  test "a root kill ends the runner's process and reports its exit once", %{
    host: host,
    boot: boot
  } do
    attempt = spin!(host, boot)
    assert :ok = start(attempt)
    wait_until(fn -> ScriptedHost.requests(host, "attach") != [] end, @boot_ms)
    wait_until(fn -> busy_runner() != nil end)
    os_pid = os_pid(busy_runner())
    assert alive?(os_pid)

    assert :ok = WorkerService.kill(attempt.execution_id)

    wait_until(fn -> ScriptedHost.requests(host, "runner_exited") != [] end, 10_000)

    assert [%{args: %{"attempts" => [held], "runner" => runner}}] =
             ScriptedHost.requests(host, "runner_exited")

    assert held == attempt.attempt
    assert [^runner] = attach_runners(host)

    wait_until(fn -> not alive?(os_pid) end, 10_000, "the runner's process to be gone")
    assert :ok = WorkerService.kill(attempt.execution_id)
    wait_until(fn -> match?(%{busy: 0, tainted: 0, idle: 0}, runners()) end, 10_000)
    # sleep-ok: 300 ms after the pool settled in which no second runner_exited and no complete
    # must arrive
    Process.sleep(300)
    assert length(ScriptedHost.requests(host, "runner_exited")) == 1
    assert ScriptedHost.requests(host, "complete") == []
  end

  test "a kill of an execution no runner of this boot ran is not found", %{host: host, boot: boot} do
    assert {:error, :not_found} = WorkerService.kill("exec_never")

    attempt = spin!(host, boot)
    assert :ok = start(attempt)
    wait_until(fn -> busy_runner() != nil end)
    # No runner said it holds such a child: the kill reached nothing,
    # however busy the runners are.
    assert {:error, :not_found} = WorkerService.kill("exec_child_of_someone")
  end

  test "a host answer that is lost taints the runner, which is never reused", %{
    host: host,
    boot: boot
  } do
    attempt = echo!(host, boot)
    ScriptedHost.script(host, "fetch_artifact", :drop)
    assert :ok = start(attempt)

    wait_until(fn -> ScriptedHost.requests(host, "fail") != [] end, @boot_ms)
    assert [%{args: %{"outcome" => %{"error" => error}}}] = ScriptedHost.requests(host, "fail")
    assert error =~ "could not be fetched"
    [runner] = attach_runners(host)

    wait_until(fn -> match?(%{busy: 0, idle: 0, tainted: 0}, runners()) end, 10_000)
    assert ScriptedHost.requests(host, "runner_exited") == []

    ScriptedHost.script(host, "fetch_artifact", {:ok, Base.encode64(@echo)})
    assert :ok = start(echo!(host, boot))
    wait_until(fn -> ScriptedHost.requests(host, "complete") != [] end, @boot_ms)
    assert [^runner, fresh] = attach_runners(host)
    assert fresh != runner
  end

  test "a close CYFR holds past the deadline and the grace is ended by the service's watch, " <>
         "which releases the runner and reports it once, and no process is left",
       %{host: host, boot: boot} do
    # The attempt's close is held, so the subtree cannot end on its own:
    # the runner stops its guest at its budget and waits on the close, and
    # only the service's watch, at the deadline plus the grace, ends it.
    # Held for as long as the test lives and no longer: a request still
    # parked when the test ends would hold the scripted host's stop.
    hold_while_alive(host, "fail")

    # The pool's one runner, taken before the attempt's deadline is set:
    # the runner is known by its process and its report, never by a poll
    # for the busy runner, whose moment may pass between two looks.
    runner = fresh_runner!()
    os_pid = os_pid(runner)
    assert is_integer(os_pid)

    attempt = spin!(host, boot, timeout_ms: 500)
    assert :ok = start(attempt)

    wait_until(fn -> ScriptedHost.requests(host, "fail") != [] end, @boot_ms)
    assert [%{args: %{"outcome" => %{"abandoned" => true}}}] = ScriptedHost.requests(host, "fail")

    wait_until(fn -> not alive?(os_pid) end, @boot_ms, "the runner to be released")
    wait_until(fn -> ScriptedHost.requests(host, "runner_exited") != [] end, 10_000)

    assert [%{args: %{"attempts" => [held], "runner" => reported}}] =
             ScriptedHost.requests(host, "runner_exited")

    assert held == attempt.attempt
    assert reported == runner.id
    assert ScriptedHost.requests(host, "complete") == []
    wait_until(fn -> match?(%{busy: 0, tainted: 0}, runners()) end, 10_000)
    assert {:ok, %{attempts: []}} = WorkerService.status()
    # sleep-ok: 300 ms after the pool settled in which no second report may arrive
    Process.sleep(300)
    assert length(ScriptedHost.requests(host, "runner_exited")) == 1
  end

  test "the watch ends with its hold: a runner whose subtree completed, or was killed, before " <>
         "the deadline and the grace is never released by it",
       %{host: host, boot: boot} do
    # A clean completion, held until the test has read the watch's timer.
    test = self()

    ScriptedHost.script(host, "complete", fn _args, _caller ->
      send(test, {:completing, self()})
      receive do: (:complete -> {:ok, "done"})
    end)

    runner = fresh_runner!()
    first = echo!(host, boot, timeout_ms: 5_000)
    assert :ok = start(first)
    assert_receive {:completing, completing}, @boot_ms
    %{watch: stale, watch_timer: timer} = held_by!(runner.pid)
    assert is_integer(Process.read_timer(timer))
    send(completing, :complete)

    wait_until(fn -> match?(%{busy: 0, idle: 1}, runners()) end, 10_000)
    # Its hold ended with the completion, and its timer with it.
    assert Process.read_timer(timer) == false

    # The runner taken for its athanor's next subtree: the first hold's
    # watch, should it still arrive, names a hold the runner no longer
    # has, and ends nothing.
    second = echo!(host, boot, timeout_ms: 5_000)
    assert :ok = start(second)
    assert_receive {:completing, completing}, @boot_ms
    assert held_by!(runner.pid).watch != stale
    send(WorkerService, {:watch, runner.pid, stale})
    assert %{busy: 1} = runners()
    assert alive?(os_pid(runner))
    send(completing, :complete)
    wait_until(fn -> match?(%{busy: 0, idle: 1}, runners()) end, 10_000)
    assert attach_runners(host) == [runner.id, runner.id]

    # A kill ends a hold too, whatever its deadline: of another athanor's
    # subtree, so the first runner stays kept.
    attempt = spin!(host, boot, athanor_id: "ath_other")
    assert :ok = start(attempt)
    wait_until(fn -> busy_runner() != nil end, @boot_ms)
    %{watch_timer: killed} = held_by!(busy_runner().pid)
    assert is_integer(Process.read_timer(killed))
    assert :ok = WorkerService.kill(attempt.execution_id)
    wait_until(fn -> ScriptedHost.requests(host, "runner_exited") != [] end, 10_000)
    assert Process.read_timer(killed) == false

    # Past the first subtree's deadline and the grace, its runner is still
    # kept for its athanor, and only the killed runner was reported.
    wait_until(
      fn -> System.system_time(:millisecond) > first_deadline(first) + 1_000 + 500 end,
      15_000
    )

    assert %{idle: 1} = runners()
    assert [%{args: %{"attempts" => [held]}}] = ScriptedHost.requests(host, "runner_exited")
    assert held == attempt.attempt
  end

  # The service's watch, armed at the deadline plus its grace, would
  # release the runner and report its exit: its grace outlasts the test,
  # so only the guest's budget ends the subtree.
  @tag watchdog_grace_ms: 60_000
  test "a guest stopped at its timeout taints its runner, which is ended with no process left",
       %{host: host, boot: boot} do
    # The pool's one runner, attached before the attempt's deadline is
    # set: its busy moment ends at that deadline, sooner than a poll may
    # look.
    runner = fresh_runner!()
    os_pid = os_pid(runner)
    assert is_integer(os_pid)

    attempt = spin!(host, boot, timeout_ms: 500)
    assert :ok = start(attempt)
    wait_until(fn -> ScriptedHost.requests(host, "attach") != [] end, @boot_ms)
    assert attach_runners(host) == [runner.id]

    # The attempt's own budget stops the guest at the engine's next epoch
    # tick and closes the attempt failed as abandoned.
    wait_until(fn -> ScriptedHost.requests(host, "fail") != [] end, 10_000)
    assert [%{args: %{"outcome" => %{"abandoned" => true}}}] = ScriptedHost.requests(host, "fail")

    # A stopped call makes the completion unclean: the runner is never kept
    # idle for its athanor, and the service ends its process.
    wait_until(fn -> not alive?(os_pid) end, 10_000, "the runner with the stopped call to be gone")
    wait_until(fn -> match?(%{busy: 0, idle: 0, tainted: 0}, runners()) end, 10_000)
    assert ScriptedHost.requests(host, "complete") == []
    assert ScriptedHost.requests(host, "runner_exited") == []
  end

  test "the service's handle dying reaps the runner and reports it", %{host: host, boot: boot} do
    attempt = spin!(host, boot)
    assert :ok = start(attempt)
    wait_until(fn -> ScriptedHost.requests(host, "attach") != [] end, @boot_ms)
    wait_until(fn -> busy_runner() != nil end)
    %{pid: handle} = busy_runner()
    os_pid = os_pid(busy_runner())

    Process.exit(handle, :kill)

    wait_until(fn -> not alive?(os_pid) end, 10_000, "the runner's process to be reaped")
    wait_until(fn -> ScriptedHost.requests(host, "runner_exited") != [] end, 5_000)
    assert [%{args: %{"attempts" => [held]}}] = ScriptedHost.requests(host, "runner_exited")
    assert held == attempt.attempt
    wait_until(fn -> match?(%{busy: 0}, runners()) end, 5_000)
  end
end
