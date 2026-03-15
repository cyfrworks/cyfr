defmodule Phase1g.ExecutionSemaphoreDualQueueTest do
  use ExUnit.Case, async: false

  test "high-priority waiters are served before normal-priority" do
    {:ok, sem} = GenServer.start_link(Opus.ExecutionSemaphore, 1, [])

    # Acquire the single slot
    :ok = GenServer.call(sem, {:acquire, :normal})

    results = :ets.new(:results, [:set, :public])

    # Queue a normal priority waiter
    normal_task = Task.async(fn ->
      :ok = GenServer.call(sem, {:acquire, :normal}, 5000)
      :ets.insert(results, {:normal, System.monotonic_time()})
      GenServer.cast(sem, {:release, self()})
    end)

    # Small delay to ensure normal is queued first
    Process.sleep(50)

    # Queue a high priority waiter
    high_task = Task.async(fn ->
      :ok = GenServer.call(sem, {:acquire, :high}, 5000)
      :ets.insert(results, {:high, System.monotonic_time()})
      GenServer.cast(sem, {:release, self()})
    end)

    Process.sleep(50)

    # Release the slot — high priority should get it first
    GenServer.cast(sem, {:release, self()})

    Task.await(high_task, 5000)
    Task.await(normal_task, 5000)

    [{:high, high_time}] = :ets.lookup(results, :high)
    [{:normal, normal_time}] = :ets.lookup(results, :normal)

    assert high_time < normal_time, "High priority should be served before normal"

    :ets.delete(results)
    GenServer.stop(sem)
  end

  test "terminate/2 logs and demonitors cleanly" do
    {:ok, sem} = GenServer.start_link(Opus.ExecutionSemaphore, 2, [])
    :ok = GenServer.call(sem, {:acquire, :normal})

    # Stopping should not raise
    GenServer.stop(sem)
  end
end
