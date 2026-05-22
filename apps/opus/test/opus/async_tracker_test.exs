# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.AsyncTrackerTest do
  use ExUnit.Case, async: true

  alias Opus.AsyncTracker

  # ============================================================================
  # start_link/1
  # ============================================================================

  describe "start_link/1" do
    test "starts successfully with default options" do
      {:ok, pid} = AsyncTracker.start_link([])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "starts with custom options" do
      {:ok, pid} =
        AsyncTracker.start_link(
          parent_execution_id: "exec_test",
          max_tasks: 5,
          batch_timeout_ms: 10_000
        )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  # ============================================================================
  # spawn_task/3
  # ============================================================================

  describe "spawn_task/3" do
    test "returns task_id on success" do
      {:ok, tracker} = AsyncTracker.start_link(max_tasks: 10)
      {:ok, task_id} = AsyncTracker.spawn_task(tracker, fn -> :hello end, "test-ref")
      assert task_id == "task_1"
      GenServer.stop(tracker)
    end

    test "increments task_id" do
      {:ok, tracker} = AsyncTracker.start_link(max_tasks: 10)
      {:ok, id1} = AsyncTracker.spawn_task(tracker, fn -> :one end, "ref1")
      {:ok, id2} = AsyncTracker.spawn_task(tracker, fn -> :two end, "ref2")
      assert id1 == "task_1"
      assert id2 == "task_2"
      GenServer.stop(tracker)
    end

    test "enforces max_tasks limit" do
      {:ok, tracker} = AsyncTracker.start_link(max_tasks: 2)

      {:ok, _} =
        AsyncTracker.spawn_task(
          tracker,
          fn ->
            Process.sleep(1000)
            :a
          end,
          "ref1"
        )

      {:ok, _} =
        AsyncTracker.spawn_task(
          tracker,
          fn ->
            Process.sleep(1000)
            :b
          end,
          "ref2"
        )

      assert {:error, :max_tasks_exceeded} =
               AsyncTracker.spawn_task(tracker, fn -> :c end, "ref3")

      GenServer.stop(tracker)
    end

    test "max_tasks=0 means unlimited" do
      {:ok, tracker} = AsyncTracker.start_link(max_tasks: 0)

      for i <- 1..20 do
        {:ok, _} =
          AsyncTracker.spawn_task(
            tracker,
            fn ->
              Process.sleep(500)
              i
            end,
            "ref#{i}"
          )
      end

      GenServer.stop(tracker)
    end
  end

  # ============================================================================
  # await_task/3
  # ============================================================================

  describe "await_task/3" do
    test "returns result of completed task" do
      {:ok, tracker} = AsyncTracker.start_link([])
      {:ok, task_id} = AsyncTracker.spawn_task(tracker, fn -> {:result, 42} end, "ref")

      {:ok, result} = AsyncTracker.await_task(tracker, task_id, 5000)
      assert result == {:result, 42}
      GenServer.stop(tracker)
    end

    test "returns error for unknown task_id" do
      {:ok, tracker} = AsyncTracker.start_link([])
      assert {:error, :unknown_task} = AsyncTracker.await_task(tracker, "nonexistent", 1000)
      GenServer.stop(tracker)
    end

    test "returns timeout error when task takes too long" do
      {:ok, tracker} = AsyncTracker.start_link([])

      {:ok, task_id} =
        AsyncTracker.spawn_task(
          tracker,
          fn ->
            Process.sleep(10_000)
            :done
          end,
          "ref"
        )

      assert {:error, :timeout} = AsyncTracker.await_task(tracker, task_id, 100)
      GenServer.stop(tracker)
    end

    test "returns result for already-completed task" do
      {:ok, tracker} = AsyncTracker.start_link([])
      {:ok, task_id} = AsyncTracker.spawn_task(tracker, fn -> :fast end, "ref")

      # Give the task time to complete and store result
      Process.sleep(100)

      {:ok, result} = AsyncTracker.await_task(tracker, task_id, 1000)
      assert result == :fast
      GenServer.stop(tracker)
    end
  end

  # ============================================================================
  # await_all/3
  # ============================================================================

  describe "await_all/3" do
    test "returns all results when all tasks complete" do
      {:ok, tracker} = AsyncTracker.start_link([])
      {:ok, id1} = AsyncTracker.spawn_task(tracker, fn -> :one end, "ref1")
      {:ok, id2} = AsyncTracker.spawn_task(tracker, fn -> :two end, "ref2")
      {:ok, id3} = AsyncTracker.spawn_task(tracker, fn -> :three end, "ref3")

      {:ok, results} = AsyncTracker.await_all(tracker, [id1, id2, id3], 5000)
      assert length(results) == 3

      result_map = Map.new(results)
      assert result_map[id1] == {:ok, :one}
      assert result_map[id2] == {:ok, :two}
      assert result_map[id3] == {:ok, :three}

      GenServer.stop(tracker)
    end

    test "returns timeout errors for slow tasks" do
      {:ok, tracker} = AsyncTracker.start_link([])
      {:ok, id1} = AsyncTracker.spawn_task(tracker, fn -> :fast end, "ref1")

      {:ok, id2} =
        AsyncTracker.spawn_task(
          tracker,
          fn ->
            Process.sleep(10_000)
            :slow
          end,
          "ref2"
        )

      # Short timeout — id1 should complete, id2 should timeout
      # Let id1 complete
      Process.sleep(50)

      {:ok, results} = AsyncTracker.await_all(tracker, [id1, id2], 200)
      result_map = Map.new(results)

      assert result_map[id1] == {:ok, :fast}
      assert result_map[id2] == {:error, :timeout}

      GenServer.stop(tracker)
    end

    test "returns empty list for empty task_ids" do
      {:ok, tracker} = AsyncTracker.start_link([])
      {:ok, results} = AsyncTracker.await_all(tracker, [], 1000)
      assert results == []
      GenServer.stop(tracker)
    end
  end

  # ============================================================================
  # await_any/3
  # ============================================================================

  describe "await_any/3" do
    test "returns the first completed task" do
      {:ok, tracker} = AsyncTracker.start_link([])

      {:ok, id1} =
        AsyncTracker.spawn_task(
          tracker,
          fn ->
            Process.sleep(500)
            :slow
          end,
          "ref1"
        )

      {:ok, id2} = AsyncTracker.spawn_task(tracker, fn -> :fast end, "ref2")

      # Wait for fast task to complete
      Process.sleep(50)

      {:ok, winner_id, result, pending} = AsyncTracker.await_any(tracker, [id1, id2], 5000)
      assert winner_id == id2
      assert result == {:ok, :fast}
      assert id1 in pending
      refute id2 in pending

      GenServer.stop(tracker)
    end

    test "returns timeout when no task completes in time" do
      {:ok, tracker} = AsyncTracker.start_link([])

      {:ok, id1} =
        AsyncTracker.spawn_task(
          tracker,
          fn ->
            Process.sleep(10_000)
            :a
          end,
          "ref1"
        )

      {:ok, id2} =
        AsyncTracker.spawn_task(
          tracker,
          fn ->
            Process.sleep(10_000)
            :b
          end,
          "ref2"
        )

      assert {:error, :timeout} = AsyncTracker.await_any(tracker, [id1, id2], 100)
      GenServer.stop(tracker)
    end

    test "returns already-completed task immediately" do
      {:ok, tracker} = AsyncTracker.start_link([])
      {:ok, id1} = AsyncTracker.spawn_task(tracker, fn -> :done end, "ref1")

      # Let it complete
      Process.sleep(100)

      {:ok, winner_id, result, pending} = AsyncTracker.await_any(tracker, [id1], 1000)
      assert winner_id == id1
      assert result == {:ok, :done}
      assert pending == []

      GenServer.stop(tracker)
    end
  end

  # ============================================================================
  # poll/2
  # ============================================================================

  describe "poll/2" do
    test "returns pending for running task" do
      {:ok, tracker} = AsyncTracker.start_link([])

      {:ok, task_id} =
        AsyncTracker.spawn_task(
          tracker,
          fn ->
            Process.sleep(5000)
            :done
          end,
          "ref"
        )

      assert {:ok, :pending} = AsyncTracker.poll(tracker, task_id)
      GenServer.stop(tracker)
    end

    test "returns result for completed task" do
      {:ok, tracker} = AsyncTracker.start_link([])
      {:ok, task_id} = AsyncTracker.spawn_task(tracker, fn -> :completed end, "ref")

      # Give task time to complete
      Process.sleep(100)

      result = AsyncTracker.poll(tracker, task_id)
      assert result == {:ok, :completed}
      GenServer.stop(tracker)
    end

    test "returns error for unknown task_id" do
      {:ok, tracker} = AsyncTracker.start_link([])
      assert {:error, :unknown_task} = AsyncTracker.poll(tracker, "nonexistent")
      GenServer.stop(tracker)
    end
  end

  # ============================================================================
  # cancel_task/2
  # ============================================================================

  describe "cancel_task/2" do
    test "cancels a running task" do
      {:ok, tracker} = AsyncTracker.start_link([])

      {:ok, task_id} =
        AsyncTracker.spawn_task(
          tracker,
          fn ->
            Process.sleep(10_000)
            :done
          end,
          "ref"
        )

      assert :ok = AsyncTracker.cancel_task(tracker, task_id)

      # Polling should show cancelled error
      assert {:error, :cancelled} = AsyncTracker.poll(tracker, task_id)
      GenServer.stop(tracker)
    end

    test "returns error for already-completed task" do
      {:ok, tracker} = AsyncTracker.start_link([])
      {:ok, task_id} = AsyncTracker.spawn_task(tracker, fn -> :done end, "ref")

      # Let it complete
      Process.sleep(100)

      assert {:error, :already_completed} = AsyncTracker.cancel_task(tracker, task_id)
      GenServer.stop(tracker)
    end

    test "returns error for unknown task_id" do
      {:ok, tracker} = AsyncTracker.start_link([])
      assert {:error, :unknown_task} = AsyncTracker.cancel_task(tracker, "nonexistent")
      GenServer.stop(tracker)
    end

    test "cancelled task does not affect other tasks" do
      {:ok, tracker} = AsyncTracker.start_link([])

      {:ok, id1} =
        AsyncTracker.spawn_task(
          tracker,
          fn ->
            Process.sleep(10_000)
            :a
          end,
          "ref1"
        )

      {:ok, id2} = AsyncTracker.spawn_task(tracker, fn -> :b end, "ref2")

      # Cancel id1
      assert :ok = AsyncTracker.cancel_task(tracker, id1)

      # id2 should still complete normally
      {:ok, result} = AsyncTracker.await_task(tracker, id2, 5000)
      assert result == :b

      GenServer.stop(tracker)
    end
  end

  # ============================================================================
  # await-all kills timed-out tasks
  # ============================================================================

  describe "await_all timed-out task cleanup" do
    test "timed-out tasks are killed after await_all returns" do
      {:ok, tracker} = AsyncTracker.start_link([])

      test_pid = self()
      {:ok, id1} = AsyncTracker.spawn_task(tracker, fn -> :fast end, "ref1")

      {:ok, id2} =
        AsyncTracker.spawn_task(
          tracker,
          fn ->
            send(test_pid, {:task_pid, self()})
            Process.sleep(60_000)
            :slow
          end,
          "ref2"
        )

      # Get the pid of the slow task
      assert_receive {:task_pid, slow_pid}, 1000

      # Let fast task complete
      Process.sleep(50)

      # Await with short timeout — id2 should timeout
      {:ok, results} = AsyncTracker.await_all(tracker, [id1, id2], 200)
      result_map = Map.new(results)
      assert result_map[id2] == {:error, :timeout}

      # The slow task process should be dead (killed by Task.shutdown)
      Process.sleep(50)
      refute Process.alive?(slow_pid)

      GenServer.stop(tracker)
    end
  end

  # ============================================================================
  # Mixed success/failure/timeout
  # ============================================================================

  describe "mixed results in await_all" do
    test "handles mix of success, crash, and timeout" do
      {:ok, tracker} = AsyncTracker.start_link([])
      {:ok, id_ok} = AsyncTracker.spawn_task(tracker, fn -> :success end, "ref1")
      {:ok, id_crash} = AsyncTracker.spawn_task(tracker, fn -> raise "boom" end, "ref2")

      {:ok, id_slow} =
        AsyncTracker.spawn_task(
          tracker,
          fn ->
            Process.sleep(10_000)
            :slow
          end,
          "ref3"
        )

      # Let fast tasks settle
      Process.sleep(100)

      {:ok, results} = AsyncTracker.await_all(tracker, [id_ok, id_crash, id_slow], 200)
      result_map = Map.new(results)

      assert result_map[id_ok] == {:ok, :success}
      assert {:error, crash_reason} = result_map[id_crash]
      assert crash_reason =~ "crash"
      assert result_map[id_slow] == {:error, :timeout}

      GenServer.stop(tracker)
    end
  end

  # ============================================================================
  # max_tasks enforcement during batch
  # ============================================================================

  describe "max_tasks during batch spawns" do
    test "spawn fails mid-batch when max_tasks reached" do
      {:ok, tracker} = AsyncTracker.start_link(max_tasks: 3)

      # Spawn 3 long-running tasks to fill the limit
      {:ok, _} =
        AsyncTracker.spawn_task(
          tracker,
          fn ->
            Process.sleep(5000)
            :a
          end,
          "ref1"
        )

      {:ok, _} =
        AsyncTracker.spawn_task(
          tracker,
          fn ->
            Process.sleep(5000)
            :b
          end,
          "ref2"
        )

      {:ok, _} =
        AsyncTracker.spawn_task(
          tracker,
          fn ->
            Process.sleep(5000)
            :c
          end,
          "ref3"
        )

      # Fourth spawn should fail
      assert {:error, :max_tasks_exceeded} =
               AsyncTracker.spawn_task(tracker, fn -> :d end, "ref4")

      GenServer.stop(tracker)
    end

    test "completed tasks free up slots for new spawns" do
      {:ok, tracker} = AsyncTracker.start_link(max_tasks: 2)

      # Both tasks must block long enough to actually be active simultaneously
      {:ok, id1} =
        AsyncTracker.spawn_task(
          tracker,
          fn ->
            Process.sleep(200)
            :first
          end,
          "ref1"
        )

      {:ok, _id2} =
        AsyncTracker.spawn_task(
          tracker,
          fn ->
            Process.sleep(5000)
            :slow
          end,
          "ref2"
        )

      # At limit — both tasks still running
      assert {:error, :max_tasks_exceeded} =
               AsyncTracker.spawn_task(tracker, fn -> :c end, "ref3")

      # Await id1 to free a slot (also removes from tasks map)
      {:ok, :first} = AsyncTracker.await_task(tracker, id1, 5000)

      # Now we should be able to spawn again
      {:ok, _id3} = AsyncTracker.spawn_task(tracker, fn -> :new end, "ref3")

      GenServer.stop(tracker)
    end
  end

  # ============================================================================
  # Cleanup / Terminate
  # ============================================================================

  describe "cleanup" do
    test "stopping tracker kills orphaned tasks" do
      {:ok, tracker} = AsyncTracker.start_link([])

      test_pid = self()

      {:ok, _task_id} =
        AsyncTracker.spawn_task(
          tracker,
          fn ->
            # This task runs "forever"
            send(test_pid, :task_started)
            Process.sleep(60_000)
            :never_reached
          end,
          "ref"
        )

      assert_receive :task_started, 1000

      # Stop the tracker — should kill the orphaned task
      GenServer.stop(tracker)

      # The tracker should be dead
      refute Process.alive?(tracker)
    end
  end

  # ============================================================================
  # Task Crash Handling
  # ============================================================================

  describe "crash handling" do
    test "crashed task is stored as error result" do
      {:ok, tracker} = AsyncTracker.start_link([])
      {:ok, task_id} = AsyncTracker.spawn_task(tracker, fn -> raise "boom" end, "ref")

      # Give time for crash to propagate
      Process.sleep(100)

      result = AsyncTracker.poll(tracker, task_id)
      assert {:error, reason} = result
      assert reason =~ "crash"

      GenServer.stop(tracker)
    end
  end
end
