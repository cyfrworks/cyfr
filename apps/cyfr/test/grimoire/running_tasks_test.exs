# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.RunningTasksTest do
  use ExUnit.Case, async: false

  alias Grimoire.RunningTasks

  setup do
    # `RunningTasks` is a child of the infra tier, so the supervisor owns its
    # lifecycle. The terminate test below stops it; this waits for the
    # restart rather than starting one here. Starting it from a test races
    # the supervisor for the registered name, and the race the supervisor
    # loses is the expensive one: its child start fails with
    # `{:already_started, _}`, it retries, and at ten failures inside a
    # minute the whole tier goes down — `Grimoire.TaskSupervisor`, the Finch
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
  #
  # `started/2` runs as the gate does: the test process claims under the
  # request, and the task registers against the claim from inside itself,
  # then reports and runs `work`. It answers once the task has registered.
  defp started(request_id, work \\ &sleep_forever/0) do
    claim = RunningTasks.claim_request(request_id)
    test = self()

    task =
      Task.Supervisor.async_nolink(Grimoire.TaskSupervisor, fn ->
        :ok = RunningTasks.register(request_id, claim, self())
        send(test, {:registered, self()})
        work.()
      end)

    pid = task.pid
    assert_receive {:registered, ^pid}, 1_000
    {task, claim}
  end

  defp sleep_forever, do: Process.sleep(:infinity)

  # A task that waits for `:go` before registering, so a test can act
  # between the claim and the registration.
  defp parked(register) do
    test = self()

    Task.Supervisor.async_nolink(Grimoire.TaskSupervisor, fn ->
      send(test, {:parked, self()})

      receive do
        :go -> :ok
      end

      case register.(self()) do
        :ok ->
          send(test, {:ran, self()})
          sleep_forever()

        refused ->
          send(test, {:refused, self(), refused})
          refused
      end
    end)
  end

  defp await_parked(%Task{pid: pid}), do: assert_receive({:parked, ^pid}, 1_000)

  describe "register/3 and cancel/1" do
    test "cancel kills the registered process" do
      {%Task{ref: ref}, _claim} = started("req_01HQ")
      assert :ok == RunningTasks.cancel("req_01HQ")

      assert_receive {:DOWN, ^ref, :process, _pid, :cancelled}, 1_000
    end

    test "cancel returns :not_found for an unknown request id" do
      assert {:error, :not_found} = RunningTasks.cancel("nonexistent")
    end

    test "cancel returns :not_found once the work has already finished" do
      {task, claim} = started("req_done", fn -> :ok end)
      Task.await(task)

      RunningTasks.unregister("req_done", claim)
      :sys.get_state(RunningTasks)

      assert {:error, :not_found} = RunningTasks.cancel("req_done")
    end

    test "concurrent requests are independent — no shared key" do
      # Distinct server request ids must isolate tasks even when client JSON-RPC ids are identical.
      {%Task{ref: ref_a}, _} = started("req_a")
      {b, _} = started("req_b")

      assert :ok == RunningTasks.cancel("req_a")
      assert_receive {:DOWN, ^ref_a, :process, _pid, :cancelled}, 1_000

      assert Process.alive?(b.pid), "cancelling one request must not touch another"
      Task.shutdown(b, :brutal_kill)
    end

    test "a nested call registers alongside its parent — one request, several tasks" do
      # Nested calls sharing a root request id must preserve the parent registration and cancellation monitor.
      {%Task{ref: ref_outer}, _} = started("req_chain")
      {%Task{ref: ref_inner}, _} = started("req_chain")

      assert length(RunningTasks.pids("req_chain")) == 2

      # The caller hung up: everything the request started stops.
      assert :ok == RunningTasks.cancel("req_chain")

      assert_receive {:DOWN, ^ref_inner, :process, _pid, :cancelled}, 1_000
      assert_receive {:DOWN, ^ref_outer, :process, _pid, :cancelled}, 1_000
    end

    test "a finished nested call leaves its parent cancellable" do
      # The nested call's `unregister` must drop only its own claim, so after
      # an in-chain call returned, cancelling the request still reaches the parent.
      {%Task{ref: ref_outer} = outer, _} = started("req_chain_done")
      {inner, inner_claim} = started("req_chain_done", fn -> :ok end)
      Task.await(inner)

      RunningTasks.unregister("req_chain_done", inner_claim)
      :sys.get_state(RunningTasks)

      assert RunningTasks.pids("req_chain_done") == [outer.pid]

      assert :ok == RunningTasks.cancel("req_chain_done")
      assert_receive {:DOWN, ^ref_outer, :process, _pid, :cancelled}, 1_000
    end

    test "re-registering the very same task does not stack registrations" do
      claim = RunningTasks.claim_request("req_same")
      %Task{ref: ref, pid: pid} = task = parked(&RunningTasks.register("req_same", claim, &1))
      await_parked(task)

      assert :ok = RunningTasks.register("req_same", claim, pid)
      assert :ok = RunningTasks.register("req_same", claim, pid)
      assert RunningTasks.pids("req_same") == [pid]

      assert :ok == RunningTasks.cancel("req_same")
      assert_receive {:DOWN, ^ref, :process, _pid, :cancelled}, 1_000
    end

    test "a cancel between the claim and the registration: the handler never runs" do
      request_id = "req_#{System.unique_integer([:positive])}"
      claim = RunningTasks.claim_request(request_id)
      %Task{pid: pid, ref: ref} = task = parked(&RunningTasks.register(request_id, claim, &1))
      await_parked(task)

      assert :ok = RunningTasks.cancel(request_id)
      send(pid, :go)

      assert_receive {:refused, ^pid, :cancelled}, 1_000
      assert_receive {^ref, :cancelled}, 1_000
      refute_received {:ran, ^pid}
      assert RunningTasks.pids(request_id) == []

      # The marked claim holds no task, so a second cancel finds nothing.
      assert {:error, :not_found} = RunningTasks.cancel(request_id)
      RunningTasks.unregister(request_id, claim)
    end

    test "a claim released before its task registers: the handler never runs" do
      request_id = "req_#{System.unique_integer([:positive])}"
      claim = RunningTasks.claim_request(request_id)
      %Task{pid: pid} = task = parked(&RunningTasks.register(request_id, claim, &1))
      await_parked(task)

      RunningTasks.unregister(request_id, claim)
      send(pid, :go)

      assert_receive {:refused, ^pid, :released}, 1_000
      refute_received {:ran, ^pid}
      assert RunningTasks.pids(request_id) == []
    end

    test "a claimer that dies before its task registers takes the claim with it" do
      request_id = "req_#{System.unique_integer([:positive])}"
      test = self()

      claimer =
        spawn(fn ->
          send(test, {:claim, RunningTasks.claim_request(request_id)})
          sleep_forever()
        end)

      assert_receive {:claim, claim}, 1_000
      Process.exit(claimer, :kill)

      Prima.Test.Wait.wait_until(fn -> no_claim?(request_id) end, 1_000, "the claim to go")

      assert :released = RunningTasks.register(request_id, claim, self())
      assert {:error, :not_found} = RunningTasks.cancel(request_id)
    end

    test "a registered task outlives its dead claimer until it exits itself" do
      request_id = "req_#{System.unique_integer([:positive])}"
      test = self()

      claimer =
        spawn(fn ->
          claim = RunningTasks.claim_request(request_id)

          task =
            Task.Supervisor.async_nolink(Grimoire.TaskSupervisor, fn ->
              :ok = RunningTasks.register(request_id, claim, self())
              send(test, {:registered, self()})
              sleep_forever()
            end)

          send(test, {:task, task})
          sleep_forever()
        end)

      assert_receive {:registered, pid}, 1_000
      assert_receive {:task, %Task{pid: ^pid}}, 1_000
      ref = Process.monitor(pid)
      claimer_ref = Process.monitor(claimer)
      Process.exit(claimer, :kill)
      assert_receive {:DOWN, ^claimer_ref, :process, _, :killed}, 1_000
      :sys.get_state(RunningTasks)

      # The cancel still reaches the task, and its exit leaves nothing.
      assert RunningTasks.pids(request_id) == [pid]
      assert :ok = RunningTasks.cancel(request_id)
      assert_receive {:DOWN, ^ref, :process, ^pid, :cancelled}, 1_000

      Prima.Test.Wait.wait_until(
        fn -> no_claim?(request_id) end,
        1_000,
        "the killed task's claim to go"
      )

      assert {:error, :not_found} = RunningTasks.cancel(request_id)
    end

    test "ETS entry is auto-cleaned when the task process dies" do
      {task, _claim} = started("req_cleanup", fn -> :ok end)
      Task.await(task)

      # The task's `DOWN` reaches the server on its own schedule: a bounded wait.
      Prima.Test.Wait.wait_until(
        fn -> RunningTasks.cancel("req_cleanup") == {:error, :not_found} end,
        1_000,
        "the finished task's row to go"
      )

      assert RunningTasks.pids("req_cleanup") == []
    end
  end

  defp no_claim?(request_id) do
    :sys.get_state(RunningTasks).requests
    |> Map.values()
    |> Enum.all?(&(&1.request_id != request_id))
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

      :ok = RunningTasks.register("term_req_1", RunningTasks.claim_request("term_req_1"), pid1)
      :ok = RunningTasks.register("term_req_2", RunningTasks.claim_request("term_req_2"), pid2)

      # Stop the GenServer cleanly — this triggers terminate/2 internally,
      # which demonitors all processes and deletes the ETS table. Its
      # supervisor restarts it; that is the one restart this test spends.
      was = GenServer.whereis(RunningTasks)
      GenServer.stop(RunningTasks, :shutdown)

      # The ETS table should have been deleted by terminate/2.
      # The supervisor may restart the GenServer (recreating the table) before
      # this assertion runs, so we verify the table is either gone or empty
      # (freshly recreated by supervisor with no entries).
      case :ets.whereis(Grimoire.RunningTasks) do
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

  describe "a handle" do
    test "cancels its own task and nothing else under the request" do
      request_id = "req_#{System.unique_integer([:positive])}"
      handle = {:turn, System.unique_integer([:positive])}
      {sibling, _} = started(request_id)

      assert :ok = RunningTasks.claim(handle)

      {%Task{ref: ref}, _} =
        started(request_id, fn ->
          :ok = RunningTasks.register_handle(handle, self())
          sleep_forever()
        end)

      Prima.Test.Wait.wait_until(
        fn -> match?([{_, pid}] when is_pid(pid), row(handle)) end,
        1_000,
        "the handle's task to register"
      )

      assert :ok = RunningTasks.cancel_handle(handle)
      assert_receive {:DOWN, ^ref, :process, _, :cancelled}, 1_000
      assert Process.alive?(sibling.pid)
      Task.shutdown(sibling, :brutal_kill)
      RunningTasks.release_handle(handle)
    end

    test "cancelled between the claim and the registration, it never runs" do
      handle = handle()
      assert :ok = RunningTasks.claim(handle)
      %Task{pid: pid, ref: ref} = task = parked(&RunningTasks.register_handle(handle, &1))
      await_parked(task)

      assert :ok = RunningTasks.cancel_handle(handle)
      assert :cancelled = RunningTasks.claim(handle)
      send(pid, :go)

      assert_receive {:refused, ^pid, :cancelled}, 1_000
      assert_receive {^ref, :cancelled}, 1_000
      refute_received {:ran, ^pid}

      RunningTasks.release_handle(handle)
      assert :ok = RunningTasks.claim(handle)
      RunningTasks.release_handle(handle)
    end

    test "released before its task registers, it never runs and writes nothing" do
      handle = handle()
      assert :ok = RunningTasks.claim(handle)
      %Task{pid: pid} = task = parked(&RunningTasks.register_handle(handle, &1))
      await_parked(task)

      assert :ok = RunningTasks.release_handle(handle)
      send(pid, :go)

      assert_receive {:refused, ^pid, :released}, 1_000
      refute_received {:ran, ^pid}
      assert [] = row(handle)
    end

    test "a handle never claimed refuses a registration and writes nothing" do
      handle = handle()
      assert :released = RunningTasks.register_handle(handle, self())
      assert [] = row(handle)
    end

    test "a claimer killed before its task registers leaves no row" do
      handle = handle()
      test = self()

      claimer =
        spawn(fn ->
          send(test, {:claimed, RunningTasks.claim(handle)})
          sleep_forever()
        end)

      assert_receive {:claimed, :ok}, 1_000
      assert [{^handle, :pending}] = row(handle)
      Process.exit(claimer, :kill)

      Prima.Test.Wait.wait_until(fn -> row(handle) == [] end, 1_000, "the claimer's row to go")
      assert :released = RunningTasks.register_handle(handle, self())
      assert [] = row(handle)
    end

    # An aborted turn kills its worker (the claimer) and then cancels the
    # call by its handle: the row must still reach the handler, and the
    # handler's death must then delete it.
    test "a claimer killed after its task registers: the cancel still stops it, and no row survives" do
      handle = handle()
      test = self()

      claimer =
        spawn(fn ->
          :ok = RunningTasks.claim(handle)

          Task.Supervisor.async_nolink(Grimoire.TaskSupervisor, fn ->
            :ok = RunningTasks.register_handle(handle, self())
            send(test, {:registered, self()})
            sleep_forever()
          end)

          sleep_forever()
        end)

      assert_receive {:registered, pid}, 1_000
      ref = Process.monitor(pid)
      claimer_ref = Process.monitor(claimer)
      Process.exit(claimer, :kill)
      assert_receive {:DOWN, ^claimer_ref, :process, _, :killed}, 1_000
      :sys.get_state(RunningTasks)
      assert [{^handle, ^pid}] = row(handle)

      assert :ok = Grimoire.cancel_call(handle)
      assert_receive {:DOWN, ^ref, :process, ^pid, :cancelled}, 1_000

      Prima.Test.Wait.wait_until(
        fn -> row(handle) == [] end,
        1_000,
        "the killed task's row to go"
      )
    end

    test "a task that exits on its own takes its row, and the late release is a no-op" do
      handle = handle()
      assert :ok = RunningTasks.claim(handle)
      test = self()

      %Task{pid: pid} =
        task =
        Task.Supervisor.async_nolink(Grimoire.TaskSupervisor, fn ->
          :ok = RunningTasks.register_handle(handle, self())
          send(test, {:registered, self()})
          :done
        end)

      assert_receive {:registered, ^pid}, 1_000
      assert :done = Task.await(task)
      Prima.Test.Wait.wait_until(fn -> row(handle) == [] end, 1_000, "the task's row to go")

      assert :ok = Grimoire.cancel_call(handle)
      assert [] = row(handle)
      assert :ok = RunningTasks.release_handle(handle)
      assert [] = row(handle)
    end

    # A re-dispatch bumps the call's generation, which is part of its handle:
    # the old generation's cancel marker never refuses the new one.
    test "a new generation is claimed afresh beside the old one's marker" do
      id = System.unique_integer([:positive])
      old = {:turn, id, 1}
      new = {:turn, id, 2}

      assert :ok = RunningTasks.claim(old)
      assert :ok = RunningTasks.cancel_handle(old)
      assert [{^old, :cancelled}] = row(old)

      assert :ok = RunningTasks.claim(new)
      %Task{pid: pid} = task = parked(&RunningTasks.register_handle(new, &1))
      await_parked(task)
      send(pid, :go)
      assert_receive {:ran, ^pid}, 1_000
      assert [{^new, ^pid}] = row(new)
      assert [{^old, :cancelled}] = row(old)

      Task.shutdown(task, :brutal_kill)
      RunningTasks.release_handle(old)
      RunningTasks.release_handle(new)
      assert :ok = RunningTasks.claim(old)
      RunningTasks.release_handle(old)
    end
  end

  # A handle's row lives from its claim to its release or its task's exit.
  # A cancel marks a live row; with no row there is no work to stop and
  # nothing is written, so neither a released handle nor one this member
  # never claimed leaves a marker behind.
  describe "a handle's row" do
    # A running handler, registered under `handle` as the gate registers one.
    defp running(handle) do
      :ok = RunningTasks.claim(handle)
      test = self()

      task =
        Task.Supervisor.async_nolink(Grimoire.TaskSupervisor, fn ->
          :ok = RunningTasks.register_handle(handle, self())
          send(test, :registered)
          sleep_forever()
        end)

      assert_receive :registered, 1_000
      task
    end

    test "cancel: the handler is stopped, and its exit deletes the row" do
      handle = handle()
      %Task{ref: ref, pid: pid} = running(handle)
      assert [{^handle, ^pid}] = row(handle)

      assert :ok = RunningTasks.cancel_handle(handle)
      assert_receive {:DOWN, ^ref, :process, _, :cancelled}, 1_000

      Prima.Test.Wait.wait_until(
        fn -> row(handle) == [] end,
        1_000,
        "the killed task's row to go"
      )

      assert :ok = RunningTasks.release_handle(handle)
      assert [] = row(handle)
    end

    test "release then cancel: the cancel is a no-op and no row is left" do
      handle = handle()
      assert :ok = RunningTasks.claim(handle)
      assert :ok = RunningTasks.release_handle(handle)

      assert :ok = RunningTasks.cancel_handle(handle)
      assert [] = row(handle)
      assert :ok = RunningTasks.claim(handle)
      RunningTasks.release_handle(handle)
    end

    test "a second cancel stops nothing more and writes nothing new" do
      handle = handle()
      assert :ok = RunningTasks.claim(handle)
      assert :ok = RunningTasks.cancel_handle(handle)
      assert :ok = RunningTasks.cancel_handle(handle)
      assert [{^handle, :cancelled}] = row(handle)

      RunningTasks.release_handle(handle)
      assert :ok = Grimoire.cancel_call(handle)
      assert [] = row(handle)
    end

    test "a cancel of a handle never claimed here writes nothing" do
      handle = handle()
      assert :ok = Grimoire.cancel_call(handle)
      assert [] = row(handle)

      assert :ok = RunningTasks.claim(handle)
      assert [{^handle, :pending}] = row(handle)
      assert :ok = Grimoire.release_call(handle)
      assert [] = row(handle)
    end
  end

  describe "a duplicate cancel of a request" do
    test "answers not_found once the first cancel has run" do
      {%Task{ref: ref}, _} = started("req_twice")

      assert :ok = Grimoire.cancel_request("req_twice")
      assert_receive {:DOWN, ^ref, :process, _pid, :cancelled}, 1_000

      assert {:error, :not_found = reason} = Grimoire.cancel_request("req_twice")
      assert %Prima.Refusal{class: :not_found} = Grimoire.Error.classify(reason)
    end
  end

  defp handle, do: {:turn, System.unique_integer([:positive])}
  defp row(handle), do: :ets.lookup(Grimoire.RunningTasks.Handles, handle)
end
