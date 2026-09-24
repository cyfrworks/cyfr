# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.WorkerServiceTest do
  @moduledoc """
  The worker service starts only an assignment addressed to it and its
  boot, with the input its digest binds and keys sealed for it that open
  as its attempt. Its runners are OS processes of their own (the `Direct`
  keeper). A runner that exits leaving its attempt open is reported to
  CYFR at once over the wire, signed with the service's dispatch key; a
  killed runner is reported the same way. A restarted service is a new
  boot that holds none of its predecessor's attempts, and its runners'
  processes are gone. Neither the service, nor a runner's handle holding
  the assign it sent, nor the keeper shows a runner's attempt keys or the
  service's own, raw or as the hex the channel carries.
  """

  use ExUnit.Case, async: false

  import Opus.Test.Wait

  alias Prima.WorkerAuth
  alias Opus.Test.ScriptedHost
  alias Opus.{RunnerPool, RunnerProcess, WorkerService}

  # A runner is a VM booting from nothing: its first host call takes seconds.
  @boot_ms 30_000

  setup do
    host = ScriptedHost.start!()
    boot = ScriptedHost.serve!(host)
    {:ok, host: host, boot: boot}
  end

  defp start(attempt, sealed \\ nil),
    do: WorkerService.start(attempt.assignment, attempt.input, sealed || attempt.sealed_keys)

  defp sealed_with(key, attempt) do
    {:ok, sealed} = WorkerAuth.seal_attempt_keys(key, attempt.keys)
    sealed
  end

  defp worker_key(host, service) do
    {:ok, key} = WorkerAuth.worker_key(host.root, service)
    key
  end

  defp attempts, do: elem(WorkerService.status(), 1).attempts

  describe "start/3" do
    test "refuses an assignment addressed to another worker service, or another boot of this one",
         %{host: host, boot: boot} do
      other_service = ScriptedHost.attempt!(host, service: "wrk_other", boot: boot)
      assert {:error, :malformed} = start(other_service)

      other_boot = ScriptedHost.attempt!(host, boot: "boot_other")
      assert {:error, :malformed} = start(other_boot)

      assert attempts() == []
      assert ScriptedHost.requests(host) == []
    end

    test "refuses input its assignment's digest does not bind", %{host: host, boot: boot} do
      attempt = ScriptedHost.attempt!(host, boot: boot)

      assert {:error, :malformed} =
               WorkerService.start(attempt.assignment, ~s({"fixture":false}), attempt.sealed_keys)

      assert attempts() == []
    end

    test "refuses keys that do not open as the assignment's attempt on this worker service", %{
      host: host,
      boot: boot
    } do
      attempt = ScriptedHost.attempt!(host, boot: boot)
      other = ScriptedHost.attempt!(host, boot: boot)
      elsewhere = WorkerAuth.dispatch_seal_key(worker_key(host, "wrk_other"))
      signing = WorkerAuth.dispatch_key(worker_key(host, "wrk_local"))

      for sealed <- [
            other.sealed_keys,
            sealed_with(elsewhere, attempt),
            sealed_with(signing, attempt),
            "not sealed"
          ] do
        assert {:error, :malformed} = start(attempt, sealed)
      end

      assert %{busy: 0} = elem(WorkerService.status(), 1).runners
      assert attempts() == []
    end

    test "refuses an execution this service already runs", %{host: host, boot: boot} do
      ScriptedHost.script(host, "attach", fn _args, _caller ->
        Process.sleep(500)
        {:error, :lost}
      end)

      attempt = ScriptedHost.attempt!(host, boot: boot)
      assert :ok = start(attempt)
      assert {:error, :malformed} = start(attempt)
      assert attempts() == [attempt.attempt]
    end
  end

  test "a runner that exits leaving its attempt open is reported at once, signed by the service",
       %{
         host: host,
         boot: boot
       } do
    ScriptedHost.script(host, "attach", {:error, :lost})
    attempt = ScriptedHost.attempt!(host, boot: boot)

    assert :ok = start(attempt)

    wait_until(fn -> ScriptedHost.requests(host, "runner_exited") != [] end, @boot_ms)

    assert [%{args: args, caller: report, header: header}] =
             ScriptedHost.requests(host, "runner_exited")

    assert args["attempts"] == [attempt.attempt]
    assert [%{caller: %{runner: runner}}] = ScriptedHost.requests(host, "attach")
    assert args["runner"] == runner
    assert %{service: "wrk_local", boot: ^boot} = report
    assert String.starts_with?(header, "v1 kind=report ")
    wait_until(fn -> attempts() == [] end)
  end

  test "a runner that closes its attempt is not reported", %{host: host, boot: boot} do
    attempt = ScriptedHost.attempt!(host, boot: boot)
    assert :ok = start(attempt)

    wait_until(fn -> ScriptedHost.requests(host, "fail") != [] end, @boot_ms)
    wait_until(fn -> attempts() == [] end)
    assert ScriptedHost.requests(host, "runner_exited") == []
  end

  test "a kill stops the runner, its exit is reported, and the kill is idempotent", %{
    host: host,
    boot: boot
  } do
    ScriptedHost.script(host, "attach", fn _args, _caller ->
      Process.sleep(2_000)
      {:ok, %{}}
    end)

    attempt = ScriptedHost.attempt!(host, boot: boot)
    assert :ok = start(attempt)
    wait_until(fn -> attempts() == [attempt.attempt] end)

    assert :ok = WorkerService.kill(attempt.execution_id)
    wait_until(fn -> attempts() == [] end)
    # Again for an execution this boot ended; never for one it never ran.
    assert :ok = WorkerService.kill(attempt.execution_id)
    assert {:error, :not_found} = WorkerService.kill("exec_never_here")

    wait_until(fn -> ScriptedHost.requests(host, "runner_exited") != [] end, @boot_ms)
    assert [%{args: %{"attempts" => [held]}}] = ScriptedHost.requests(host, "runner_exited")
    assert held == attempt.attempt
    assert attempts() == []
  end

  test "a restarted service is a new boot that holds none of its predecessor's attempts", %{
    host: host,
    boot: boot
  } do
    hold_attach!(host)
    attempt = ScriptedHost.attempt!(host, boot: boot)
    assert :ok = start(attempt)
    assert_receive {:attach_held, held}, @boot_ms
    %{pid: handle} = Enum.find(RunnerPool.runners(RunnerPool), &(&1.state == :busy))
    os_pid = RunnerProcess.info(handle).os_pid

    ScriptedHost.restart_service!()
    send(held, :go)

    assert {:ok, %{boot: new_boot, attempts: []}} = WorkerService.status()
    assert new_boot != boot
    wait_until(fn -> not os_alive?(os_pid) end, 10_000, "the old boot's runner to be gone")

    # The predecessor's assignment is another boot's now.
    assert {:error, :malformed} = start(attempt)
  end

  test "neither the service, nor a runner's handle, nor the keeper shows a key", %{
    host: host,
    boot: boot
  } do
    hold_attach!(host)
    attempt = ScriptedHost.attempt!(host, boot: boot)
    assert :ok = start(attempt)
    assert_receive {:attach_held, held}, @boot_ms

    %Opus.Credentials{} = credentials = Opus.Credentials.current()
    handles = for %{pid: pid} <- RunnerPool.runners(RunnerPool), do: pid

    for process <- [WorkerService, Opus.Keeper.Direct | handles],
        key <- [
          attempt.keys.call,
          attempt.keys.seal,
          credentials.worker_key,
          credentials.dispatch_key,
          credentials.dispatch_seal_key
        ],
        encoded <- [key, Base.encode16(key, case: :lower)] do
      status = :erlang.term_to_binary(:sys.get_status(process))
      assert :binary.match(status, encoded) == :nomatch
    end

    send(held, :go)
  end

  # The runner's attach is held until the test lets it go: the runner is
  # busy with its attempt open, and the test hears the attach arrive.
  defp hold_attach!(host) do
    test = self()

    ScriptedHost.script(host, "attach", fn _args, _caller ->
      send(test, {:attach_held, self()})

      receive do
        :go -> {:ok, %{}}
      after
        30_000 -> {:ok, %{}}
      end
    end)
  end

  defp os_alive?(os_pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(os_pid)],
           stderr_to_stdout: true
         ) do
      {stat, 0} -> not String.starts_with?(String.trim(stat), "Z")
      {_none, _status} -> false
    end
  end
end
