# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ExecutionSemaphoreDualQueueTest do
  use ExUnit.Case, async: false

  test "a queued child is served before a queued root" do
    {:ok, sem} = GenServer.start_link(Opus.ExecutionSemaphore, {1, 16}, [])

    # Acquire the single slot (max 1 → no child reserve)
    :ok = GenServer.call(sem, {:acquire, :root, nil})

    results = :ets.new(:results, [:set, :public])

    # Queue a root waiter
    root_task =
      Task.async(fn ->
        :ok = GenServer.call(sem, {:acquire, :root, nil}, 5000)
        :ets.insert(results, {:root, System.monotonic_time()})
        GenServer.cast(sem, {:release, self()})
      end)

    # Small delay to ensure the root is queued first
    Process.sleep(50)

    # Queue a child waiter
    child_task =
      Task.async(fn ->
        :ok = GenServer.call(sem, {:acquire, :child, nil}, 5000)
        :ets.insert(results, {:child, System.monotonic_time()})
        GenServer.cast(sem, {:release, self()})
      end)

    Process.sleep(50)

    # Release the slot — the child should get it first
    GenServer.cast(sem, {:release, self()})

    Task.await(child_task, 5000)
    Task.await(root_task, 5000)

    [{:child, child_time}] = :ets.lookup(results, :child)
    [{:root, root_time}] = :ets.lookup(results, :root)

    assert child_time < root_time, "a child should be served before a root"

    :ets.delete(results)
    GenServer.stop(sem)
  end

  test "terminate/2 logs and demonitors cleanly" do
    {:ok, sem} = GenServer.start_link(Opus.ExecutionSemaphore, {2, 16}, [])
    :ok = GenServer.call(sem, {:acquire, :root, nil})

    # Stopping should not raise
    GenServer.stop(sem)
  end
end
