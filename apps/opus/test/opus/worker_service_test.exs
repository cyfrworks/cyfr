# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.WorkerServiceTest do
  @moduledoc """
  The worker service starts only an assignment addressed to it and its
  boot, with the input its digest binds and keys sealed for it that open
  as its attempt. A runner that exits leaving its attempt open is reported
  to CYFR at once over the wire, signed with the service's dispatch key; a
  killed runner is reported the same way. A restarted service is a new
  boot that holds none of its predecessor's attempts. Neither the service
  nor its runners' supervisor shows a runner's attempt keys or the
  service's own.
  """

  use ExUnit.Case, async: false

  import Opus.Test.Wait

  alias Cyfr.WorkerAuth
  alias Opus.Test.ScriptedHost
  alias Opus.WorkerService

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

  test "a runner that exits leaving its attempt open is reported at once, signed by the service", %{
    host: host,
    boot: boot
  } do
    ScriptedHost.script(host, "attach", {:error, :lost})
    attempt = ScriptedHost.attempt!(host, boot: boot)

    assert :ok = start(attempt)

    wait_until(fn -> ScriptedHost.requests(host, "runner_exited") != [] end, 5_000)

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

    wait_until(fn -> ScriptedHost.requests(host, "fail") != [] end, 5_000)
    wait_until(fn -> attempts() == [] end)
    assert ScriptedHost.requests(host, "runner_exited") == []
  end

  test "a kill stops the runner, and its exit is reported", %{host: host, boot: boot} do
    ScriptedHost.script(host, "attach", fn _args, _caller ->
      Process.sleep(2_000)
      {:ok, %{}}
    end)

    attempt = ScriptedHost.attempt!(host, boot: boot)
    assert :ok = start(attempt)
    wait_until(fn -> attempts() == [attempt.attempt] end)

    assert :ok = WorkerService.kill(attempt.execution_id)
    wait_until(fn -> attempts() == [] end)
    assert {:error, :not_found} = WorkerService.kill(attempt.execution_id)

    wait_until(fn -> ScriptedHost.requests(host, "runner_exited") != [] end, 5_000)
    assert [%{args: %{"attempts" => [held]}}] = ScriptedHost.requests(host, "runner_exited")
    assert held == attempt.attempt
    assert attempts() == []
  end

  test "a restarted service is a new boot that holds none of its predecessor's attempts", %{
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
    [runner] = DynamicSupervisor.which_children(WorkerService.Runners)
    {_, runner_pid, _, _} = runner

    ScriptedHost.restart_service!()

    assert {:ok, %{boot: new_boot, attempts: []}} = WorkerService.status()
    assert new_boot != boot
    wait_until(fn -> not Process.alive?(runner_pid) end)

    # The predecessor's assignment is another boot's now.
    assert {:error, :malformed} = start(attempt)
  end

  test "neither the service nor its runners' supervisor shows a key", %{host: host, boot: boot} do
    ScriptedHost.script(host, "attach", fn _args, _caller ->
      Process.sleep(2_000)
      {:ok, %{}}
    end)

    attempt = ScriptedHost.attempt!(host, boot: boot)
    assert :ok = start(attempt)
    wait_until(fn -> attempts() == [attempt.attempt] end)

    %Opus.Credentials{} = credentials = Opus.Credentials.current()

    for process <- [WorkerService, WorkerService.Runners],
        key <- [
          attempt.keys.call,
          attempt.keys.seal,
          credentials.worker_key,
          credentials.dispatch_key,
          credentials.dispatch_seal_key
        ] do
      status = :erlang.term_to_binary(:sys.get_status(process))
      assert :binary.match(status, key) == :nomatch
    end
  end
end
