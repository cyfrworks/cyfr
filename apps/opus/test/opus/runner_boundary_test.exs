# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.RunnerBoundaryTest do
  @moduledoc """
  The worker service over its runner boundary, with the `Direct` keeper:
  each runner is a VM of its own, started with this VM's code paths, that
  attaches, runs the subtree and reports over the control channel. The
  service loads no component. A clean completion leaves the runner idle
  for its athanor, and the next subtree of that athanor reuses it; another
  athanor gets a fresh one. A root kill ends the runner's process and
  reports its exit once; a host answer that is lost taints the runner; a
  guest that ignores its deadline is halted by the runner's watchdog, and
  one whose call was killed at its timeout taints its runner; the
  service's handle dying reaps the runner; the keeper dying takes the
  service tree with it and every runner too.
  """

  use ExUnit.Case, async: false

  import Opus.Test.Wait

  alias Opus.Test.ScriptedHost
  alias Opus.{RunnerPool, RunnerProcess, WorkerService}

  @moduletag timeout: 90_000

  @echo File.read!(Path.expand("../support/test_wasm/echo.wasm", __DIR__))
  @spin File.read!(Path.expand("../support/test_wasm/spin.wasm", __DIR__))

  # A runner is a VM booting from nothing: its first attach takes seconds.
  @boot_ms 30_000

  @settings [:keeper, :pool_size, :idle_ttl_ms, :watchdog_grace_ms, :release_grace_ms]

  setup do
    previous = Map.new(@settings, &{&1, Application.get_env(:opus, &1)})
    Application.put_env(:opus, :keeper, :direct)
    Application.put_env(:opus, :pool_size, 1)
    Application.put_env(:opus, :idle_ttl_ms, 30_000)
    Application.put_env(:opus, :watchdog_grace_ms, 1_000)
    Application.put_env(:opus, :release_grace_ms, 1_000)

    host = ScriptedHost.start!()
    boot = ScriptedHost.serve!(host)

    # Registered after `serve!/1`'s, so it runs first: the service the
    # host's restart brings back runs under the suite's settings again.
    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:opus, key, value),
          else: Application.delete_env(:opus, key)
      end
    end)

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
    RunnerPool |> RunnerPool.runners() |> Enum.find(&(&1.state == :busy))
  end

  defp os_pid(%{pid: pid}), do: RunnerProcess.info(pid).os_pid

  defp alive?(os_pid) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp attach_runners(host),
    do: for(%{caller: %{runner: runner}} <- ScriptedHost.requests(host, "attach"), do: runner)

  test "the service role loads no component: the engine runs in the runner's VM alone" do
    {:ok, settings} = Opus.Settings.pool([keeper: :direct], %{})
    service = Opus.Application.children(:service, settings)
    runner = Opus.Application.children(:runner, %{})

    refute Opus.SharedEngine in service
    refute Opus.Cache in service
    assert Opus.SharedEngine in runner
    assert Opus.Cache in runner
    assert Enum.any?(service, &match?(%{id: Opus.WorkerListener}, &1))
    refute Enum.any?(runner, &match?(%{id: Opus.WorkerListener}, &1))

    tree = Opus.Application.service_tree(settings)
    assert Enum.any?(tree, &match?(%{id: Opus.Keeper.Direct}, &1))
    assert Enum.any?(tree, &match?({Opus.RunnerPool, _}, &1))
    assert Opus.WorkerService in tree
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

  test "a guest that ignores its deadline is halted by the runner's watchdog, and no process is left",
       %{host: host, boot: boot} do
    # The attempt's close is held, so the subtree cannot end on its own:
    # only the watchdog, armed at the deadline plus the grace, ends it.
    ScriptedHost.script(host, "fail", fn _args, _caller ->
      Process.sleep(30_000)
      {:ok, "held"}
    end)

    attempt = spin!(host, boot, timeout_ms: 500)
    assert :ok = start(attempt)
    wait_until(fn -> ScriptedHost.requests(host, "attach") != [] end, @boot_ms)
    wait_until(fn -> busy_runner() != nil end)
    os_pid = os_pid(busy_runner())

    wait_until(fn -> not alive?(os_pid) end, 10_000, "the spinning runner to be halted")
    wait_until(fn -> ScriptedHost.requests(host, "runner_exited") != [] end, 5_000)

    assert [%{args: %{"attempts" => [held]}}] = ScriptedHost.requests(host, "runner_exited")
    assert held == attempt.attempt
    assert ScriptedHost.requests(host, "complete") == []
    wait_until(fn -> match?(%{busy: 0, tainted: 0}, runners()) end, 10_000)
  end

  test "a guest killed at its timeout taints its runner, which is ended with no process left",
       %{host: host, boot: boot} do
    attempt = spin!(host, boot, timeout_ms: 500)
    assert :ok = start(attempt)
    wait_until(fn -> ScriptedHost.requests(host, "attach") != [] end, @boot_ms)
    wait_until(fn -> busy_runner() != nil end)
    os_pid = os_pid(busy_runner())

    # The attempt's own timeout kills the component call and closes the
    # attempt failed as abandoned; the call's native thread spins on.
    wait_until(fn -> ScriptedHost.requests(host, "fail") != [] end, 10_000)
    assert [%{args: %{"outcome" => %{"abandoned" => true}}}] = ScriptedHost.requests(host, "fail")

    # A killed call makes the completion unclean: the runner is never kept
    # idle for its athanor, and the service ends its VM, thread and all.
    wait_until(fn -> not alive?(os_pid) end, 10_000, "the runner with the killed call to be gone")
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

  test "the keeper dying ends every runner and restarts the service as a new boot", %{
    host: host,
    boot: boot
  } do
    attempt = spin!(host, boot)
    assert :ok = start(attempt)
    wait_until(fn -> ScriptedHost.requests(host, "attach") != [] end, @boot_ms)
    wait_until(fn -> busy_runner() != nil end)

    os_pids = for runner <- RunnerPool.runners(RunnerPool), pid = os_pid(runner), do: pid
    assert os_pids != []

    Process.exit(Process.whereis(Opus.Keeper.Direct), :kill)

    for os_pid <- os_pids,
        do: wait_until(fn -> not alive?(os_pid) end, 10_000, "runner #{os_pid} to be gone")

    # The service tree is restarting: a poll that lands in the gap finds no
    # service to ask, which is not yet the new boot.
    wait_until(
      fn -> match?({:ok, %{boot: new}} when new != boot, status_or_restarting()) end,
      10_000
    )

    assert {:ok, %{attempts: []}} = WorkerService.status()
  end

  defp status_or_restarting do
    WorkerService.status()
  catch
    :exit, {:noproc, _call} -> :restarting
  end
end
