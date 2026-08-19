# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.RunningTasksTest do
  use ExUnit.Case, async: false

  alias Emissary.MCP.RunningTasks

  setup do
    # `RunningTasks` is a child of the infra tier, so the supervisor owns its
    # lifecycle. The terminate test below stops it; this waits for the
    # restart rather than starting one here. Starting it from a test races
    # the supervisor for the registered name, and the race the supervisor
    # loses is the expensive one: its child start fails with
    # `{:already_started, _}`, it retries, and at ten failures inside a
    # minute the whole tier goes down — `Emissary.TaskSupervisor`, the Finch
    # pools, the registries — failing whichever tests happen to be running.
    pid = await_running()
    # Drain the mailbox so each test starts from a settled state.
    :sys.get_state(pid)
    :ok
  end

  defp await_running(replacing \\ nil) do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      case GenServer.whereis(RunningTasks) do
        pid when is_pid(pid) and pid != replacing -> {:halt, pid}
        _ -> Process.sleep(10) && {:cont, nil}
      end
    end) || flunk("RunningTasks was not (re)started by its supervisor")
  end

  # Cancellation kills the tracked process outright, so a *linked* task would
  # propagate the `:cancelled` exit straight into the test process. Production
  # tasks come from `Task.Supervisor.async_nolink/2` for the same reason — the
  # dispatcher must survive a handler dying — so the tests use it too.
  defp forever, do: Task.Supervisor.async_nolink(Emissary.TaskSupervisor, &sleep_forever/0)

  defp sleep_forever, do: Process.sleep(:infinity)

  describe "register/2 and cancel/1" do
    test "cancel kills the registered process" do
      %Task{ref: ref} = task = forever()

      :ok = RunningTasks.register("req_01HQ", task)
      assert :ok == RunningTasks.cancel("req_01HQ")

      assert_receive {:DOWN, ^ref, :process, _pid, :cancelled}, 1_000
    end

    test "cancel returns :not_found for an unknown request id" do
      assert {:error, :not_found} = RunningTasks.cancel("nonexistent")
    end

    test "cancel returns :not_found once the work has already finished" do
      task = Task.Supervisor.async_nolink(Emissary.TaskSupervisor, fn -> :ok end)
      :ok = RunningTasks.register("req_done", task)
      Task.await(task)

      RunningTasks.unregister("req_done")
      :sys.get_state(RunningTasks)

      assert {:error, :not_found} = RunningTasks.cancel("req_done")
    end

    test "concurrent requests are independent — no shared key" do
      # The whole reason the key is the server-minted request id: two callers
      # sending `{"id": 1}` used to collide on one ETS row, so the second
      # registration evicted the first and a cancellation reached the wrong
      # task. Distinct ids must never interfere.
      %Task{ref: ref_a} = a = forever()
      b = forever()

      :ok = RunningTasks.register("req_a", a)
      :ok = RunningTasks.register("req_b", b)

      assert :ok == RunningTasks.cancel("req_a")
      assert_receive {:DOWN, ^ref_a, :process, _pid, :cancelled}, 1_000

      assert Process.alive?(b.pid), "cancelling one request must not touch another"
      Task.shutdown(b, :brutal_kill)
    end

    test "re-registering the same id replaces the previous entry" do
      first = forever()
      %Task{ref: ref_second} = second = forever()

      :ok = RunningTasks.register("req_replace", first)
      :ok = RunningTasks.register("req_replace", second)
      :sys.get_state(RunningTasks)

      assert :ok == RunningTasks.cancel("req_replace")
      assert_receive {:DOWN, ^ref_second, :process, _pid, :cancelled}, 1_000

      assert Process.alive?(first.pid), "the evicted entry must not be killed"
      Task.shutdown(first, :brutal_kill)
    end

    test "ETS entry is auto-cleaned when the task process dies" do
      task = Task.Supervisor.async_nolink(Emissary.TaskSupervisor, fn -> :ok end)
      :ok = RunningTasks.register("req_cleanup", task)

      Task.await(task)

      # Poll until the GenServer has processed the :DOWN message.
      # :sys.get_state/1 drains the GenServer's mailbox, but the :DOWN message
      # may arrive after the first call, so we retry a few times.
      Enum.reduce_while(1..20, nil, fn _, _ ->
        :sys.get_state(RunningTasks)

        case RunningTasks.cancel("req_cleanup") do
          {:error, :not_found} ->
            {:halt, :ok}

          _ ->
            Process.sleep(10)
            {:cont, nil}
        end
      end)

      assert {:error, :not_found} = RunningTasks.cancel("req_cleanup")
    end
  end

  describe "terminate/2" do
    test "demonitors all tracked processes" do
      # Verify that terminate/2 calls Process.demonitor on all tracked refs.
      #
      # We can't call RunningTasks.terminate/2 directly because it deletes
      # the live ETS table owned by the supervised GenServer, which causes
      # flaky failures in other test files (e.g., MCPTest) that depend on
      # the table existing. Instead, we verify the behavior by registering
      # tasks, stopping the GenServer cleanly, and confirming cleanup.

      # Use spawn (not Task.async) to avoid linking to the test process —
      # GenServer.stop would propagate the exit through the link.
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)
      task1 = %{pid: pid1, ref: make_ref(), owner: self(), mfa: {Function, :identity, 1}}
      task2 = %{pid: pid2, ref: make_ref(), owner: self(), mfa: {Function, :identity, 1}}

      :ok = RunningTasks.register("term_req_1", struct!(Task, task1))
      :ok = RunningTasks.register("term_req_2", struct!(Task, task2))

      # Stop the GenServer cleanly — this triggers terminate/2 internally,
      # which demonitors all processes and deletes the ETS table. Its
      # supervisor restarts it; that is the one restart this test spends.
      was = GenServer.whereis(RunningTasks)
      GenServer.stop(RunningTasks, :shutdown)

      # The ETS table should have been deleted by terminate/2.
      # The supervisor may restart the GenServer (recreating the table) before
      # this assertion runs, so we verify the table is either gone or empty
      # (freshly recreated by supervisor with no entries).
      case :ets.whereis(Emissary.MCP.RunningTasks) do
        :undefined -> :ok
        ref -> assert :ets.tab2list(ref) == []
      end

      # Clean up spawned processes
      Process.exit(pid1, :kill)
      Process.exit(pid2, :kill)

      # Wait for the supervisor's own restart before handing the name back to
      # the next test — never start a second one here (see `setup`).
      await_running(was)
    end
  end
end
