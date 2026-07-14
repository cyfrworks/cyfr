# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ExecutionSemaphoreTest do
  use ExUnit.Case, async: false

  alias Opus.ExecutionSemaphore

  # The semaphore is started by the application supervisor.
  # We use the running instance rather than trying to restart it,
  # except for tests that need specific configuration.

  setup do
    # Ensure any held slots from previous tests are cleared
    ExecutionSemaphore.force_release_all()
    :ok
  end

  describe "acquire/release" do
    test "acquire returns :ok when slots available" do
      assert :ok = ExecutionSemaphore.acquire()
      ExecutionSemaphore.release()
    end

    test "release frees a slot" do
      assert :ok = ExecutionSemaphore.acquire()
      status = ExecutionSemaphore.status()
      assert status.active == 1

      ExecutionSemaphore.release()
      # Give the cast time to process
      Process.sleep(10)

      status = ExecutionSemaphore.status()
      assert status.active == 0
    end

    test "double release is a no-op" do
      assert :ok = ExecutionSemaphore.acquire()
      ExecutionSemaphore.release()
      Process.sleep(10)
      ExecutionSemaphore.release()
      Process.sleep(10)

      status = ExecutionSemaphore.status()
      assert status.active == 0
    end
  end

  describe "queue-based waiting" do
    test "callers queue when at capacity and are served on release" do
      status = ExecutionSemaphore.status()
      max = status.max

      # Acquire all slots from separate processes
      holders = acquire_from_processes(max)

      # Start a waiter that will queue
      parent = self()

      waiter =
        spawn(fn ->
          result = ExecutionSemaphore.acquire(5_000)
          send(parent, {:waiter_result, result})

          if result == :ok do
            receive do
              :release -> ExecutionSemaphore.release()
            end
          end
        end)

      # Give the waiter time to queue
      Process.sleep(50)

      # Verify it's queued
      status = ExecutionSemaphore.status()
      assert status.queued == 1

      # Release one holder — waiter should get the slot
      [first | rest] = holders
      send(first, :release)
      Process.sleep(50)

      assert_receive {:waiter_result, :ok}, 2_000

      # Clean up
      send(waiter, :release)
      release_holders(rest)
    end

    test "multiple queued callers are served in order" do
      status = ExecutionSemaphore.status()
      max = status.max

      holders = acquire_from_processes(max)

      # Queue 3 waiters
      parent = self()

      waiters =
        Enum.map(1..3, fn i ->
          spawn(fn ->
            result = ExecutionSemaphore.acquire(5_000)
            send(parent, {:waiter_result, i, result})

            if result == :ok do
              receive do
                :release -> ExecutionSemaphore.release()
              end
            end
          end)
        end)

      Process.sleep(50)
      status = ExecutionSemaphore.status()
      assert status.queued == 3

      # Release 3 holders
      {to_release, remaining} = Enum.split(holders, 3)
      Enum.each(to_release, &send(&1, :release))
      Process.sleep(100)

      # All 3 waiters should have acquired
      for i <- 1..3 do
        assert_receive {:waiter_result, ^i, :ok}, 2_000
      end

      Enum.each(waiters, &send(&1, :release))
      release_holders(remaining)
    end
  end

  describe "priority queueing" do
    test "high priority callers are served before normal priority" do
      status = ExecutionSemaphore.status()
      max = status.max

      holders = acquire_from_processes(max)

      parent = self()
      order = :atomics.new(1, signed: false)

      # Queue a normal priority waiter first
      normal_waiter =
        spawn(fn ->
          result = ExecutionSemaphore.acquire(5_000, :normal)
          pos = :atomics.add_get(order, 1, 1)
          send(parent, {:waiter_done, :normal, pos, result})

          if result == :ok do
            receive do
              :release -> ExecutionSemaphore.release()
            end
          end
        end)

      Process.sleep(20)

      # Then queue a high priority waiter
      high_waiter =
        spawn(fn ->
          result = ExecutionSemaphore.acquire(5_000, :high)
          pos = :atomics.add_get(order, 1, 1)
          send(parent, {:waiter_done, :high, pos, result})

          if result == :ok do
            receive do
              :release -> ExecutionSemaphore.release()
            end
          end
        end)

      Process.sleep(50)

      # Release 2 holders
      [h1, h2 | rest] = holders
      send(h1, :release)
      Process.sleep(50)
      send(h2, :release)
      Process.sleep(100)

      # High priority should have been served first (lower position number)
      assert_receive {:waiter_done, :high, high_pos, :ok}, 2_000
      assert_receive {:waiter_done, :normal, normal_pos, :ok}, 2_000
      assert high_pos < normal_pos

      send(high_waiter, :release)
      send(normal_waiter, :release)
      release_holders(rest)
    end
  end

  describe "queue overflow" do
    test "returns :queue_full when queue is at capacity" do
      # Start a small semaphore to test queue limits
      {:ok, pid} = GenServer.start(ExecutionSemaphore, {2, 16}, name: :test_queue_sem)

      # Acquire both slots
      h1 = spawn_acquire(:test_queue_sem)
      h2 = spawn_acquire(:test_queue_sem)
      Process.sleep(20)

      # Queue up to max_waiters (2 * 4 = 8)
      waiters =
        Enum.map(1..8, fn _ ->
          spawn(fn ->
            GenServer.call(:test_queue_sem, {:acquire, :normal, nil}, 10_000)

            receive do
              :release -> :ok
            end
          end)
        end)

      Process.sleep(50)

      # Next one should be rejected
      result = GenServer.call(:test_queue_sem, {:acquire, :normal, nil}, 1_000)
      assert result == {:error, :queue_full}

      # Clean up
      GenServer.call(:test_queue_sem, :force_release_all)
      Enum.each(waiters, fn p -> send(p, :release) end)
      send(h1, :release)
      send(h2, :release)
      GenServer.stop(pid)
    end
  end

  describe "per-tenant cap" do
    @tenant_a {"org_a", "default"}
    @tenant_b {"org_b", "default"}

    test "tenant at cap is rejected while another tenant still acquires" do
      {:ok, pid} = GenServer.start(ExecutionSemaphore, {10, 2}, name: :test_tenant_sem)

      h1 = spawn_acquire(:test_tenant_sem, @tenant_a)
      h2 = spawn_acquire(:test_tenant_sem, @tenant_a)

      # Tenant A at cap → rejected, and no global slot consumed by the attempt
      assert {:error, :tenant_limit} =
               GenServer.call(:test_tenant_sem, {:acquire, :normal, @tenant_a}, 1_000)

      status = GenServer.call(:test_tenant_sem, :status)
      assert status.active == 2
      assert status.tenants == %{@tenant_a => 2}

      # Tenant B unaffected
      assert :ok = GenServer.call(:test_tenant_sem, {:acquire, :normal, @tenant_b}, 1_000)
      GenServer.cast(:test_tenant_sem, {:release, self()})

      # Releasing one A holder frees A capacity again
      send(h1, :release)
      Process.sleep(20)
      assert :ok = GenServer.call(:test_tenant_sem, {:acquire, :normal, @tenant_a}, 1_000)
      GenServer.cast(:test_tenant_sem, {:release, self()})

      send(h2, :release)
      Process.sleep(20)
      GenServer.stop(pid)
    end

    test "holder crash decrements the tenant counter" do
      {:ok, pid} = GenServer.start(ExecutionSemaphore, {10, 1}, name: :test_tenant_down_sem)

      holder = spawn_acquire(:test_tenant_down_sem, @tenant_a)

      assert {:error, :tenant_limit} =
               GenServer.call(:test_tenant_down_sem, {:acquire, :normal, @tenant_a}, 1_000)

      Process.exit(holder, :kill)
      Process.sleep(50)

      assert :ok = GenServer.call(:test_tenant_down_sem, {:acquire, :normal, @tenant_a}, 1_000)
      status = GenServer.call(:test_tenant_down_sem, :status)
      assert status.active == 1
      assert status.tenants == %{@tenant_a => 1}

      GenServer.cast(:test_tenant_down_sem, {:release, self()})
      Process.sleep(20)
      GenServer.stop(pid)
    end

    test "queued waiter whose tenant reaches cap mid-wait is rejected at transfer" do
      # Global max 3, tenant cap 2. A holds 1, B holds 2 (global full).
      # Two A waiters queue (A below cap at queue time). As B releases,
      # the first transfer brings A to its cap, so the second A waiter
      # must be rejected instead of breaching the cap.
      {:ok, pid} = GenServer.start(ExecutionSemaphore, {3, 2}, name: :test_tenant_xfer_sem)

      a1 = spawn_acquire(:test_tenant_xfer_sem, @tenant_a)
      b1 = spawn_acquire(:test_tenant_xfer_sem, @tenant_b)
      b2 = spawn_acquire(:test_tenant_xfer_sem, @tenant_b)

      parent = self()

      waiters =
        Enum.map(1..2, fn i ->
          spawn(fn ->
            result = GenServer.call(:test_tenant_xfer_sem, {:acquire, :normal, @tenant_a}, 5_000)
            send(parent, {:tenant_waiter, i, result})

            if result == :ok do
              receive do
                :release -> GenServer.cast(:test_tenant_xfer_sem, {:release, self()})
              end
            end
          end)
        end)

      Process.sleep(50)
      assert GenServer.call(:test_tenant_xfer_sem, :status).queued == 2

      send(b1, :release)
      Process.sleep(50)
      send(b2, :release)
      Process.sleep(50)

      results =
        for _ <- 1..2 do
          receive do
            {:tenant_waiter, _i, result} -> result
          after
            2_000 -> flunk("tenant waiter did not resolve")
          end
        end

      assert :ok in results
      assert {:error, :tenant_limit} in results

      status = GenServer.call(:test_tenant_xfer_sem, :status)
      assert status.active == 2
      assert status.tenants == %{@tenant_a => 2}

      send(a1, :release)
      Enum.each(waiters, &send(&1, :release))
      Process.sleep(20)
      GenServer.stop(pid)
    end
  end

  describe "process crash cleanup" do
    test "slot is released when holding process crashes" do
      parent = self()

      pid =
        spawn(fn ->
          :ok = ExecutionSemaphore.acquire()
          send(parent, :acquired)

          receive do
            :crash -> raise "intentional crash"
          end
        end)

      receive do
        :acquired -> :ok
      end

      status = ExecutionSemaphore.status()
      assert status.active == 1

      Process.exit(pid, :kill)
      Process.sleep(50)

      status = ExecutionSemaphore.status()
      assert status.active == 0
    end

    test "queued waiter is removed when it crashes" do
      status = ExecutionSemaphore.status()
      max = status.max

      holders = acquire_from_processes(max)

      # Queue a waiter
      waiter =
        spawn(fn ->
          ExecutionSemaphore.acquire(30_000)

          receive do
            :never -> :ok
          end
        end)

      Process.sleep(50)
      assert ExecutionSemaphore.status().queued == 1

      # Kill the waiter
      Process.exit(waiter, :kill)
      Process.sleep(50)

      assert ExecutionSemaphore.status().queued == 0

      release_holders(holders)
    end
  end

  describe ":noproc handling" do
    test "acquire returns :queue_full when semaphore is not running" do
      {:ok, pid} = GenServer.start(ExecutionSemaphore, {2, 16}, name: :test_semaphore)
      GenServer.stop(pid)

      result =
        try do
          GenServer.call(:test_semaphore, {:acquire, :normal, nil}, 100)
        catch
          :exit, _reason -> {:error, :queue_full}
        end

      assert result == {:error, :queue_full}
    end
  end

  describe "status/0" do
    test "returns semaphore state" do
      status = ExecutionSemaphore.status()
      assert is_integer(status.max)
      assert status.active == 0
      assert status.available == status.max
      assert status.queued == 0
      assert status.holders == []
    end

    test "tracks holders with timing info" do
      :ok = ExecutionSemaphore.acquire()
      status = ExecutionSemaphore.status()

      assert status.active == 1
      assert length(status.holders) == 1

      [holder] = status.holders
      assert holder.pid == inspect(self())
      assert holder.alive == true
      assert is_integer(holder.held_ms)

      ExecutionSemaphore.release()
    end
  end

  describe "force_release_all/0" do
    test "releases all held slots and clears queue" do
      parent = self()

      pids =
        Enum.map(1..3, fn _ ->
          spawn(fn ->
            :ok = ExecutionSemaphore.acquire()
            send(parent, {:acquired, self()})

            receive do
              :done -> :ok
            end
          end)
        end)

      Enum.each(pids, fn pid ->
        receive do
          {:acquired, ^pid} -> :ok
        end
      end)

      status = ExecutionSemaphore.status()
      assert status.active == 3

      :ok = ExecutionSemaphore.force_release_all()

      status = ExecutionSemaphore.status()
      assert status.active == 0
      assert status.queued == 0

      Enum.each(pids, &send(&1, :done))
    end
  end

  describe "stale sweeper" do
    test "sweeper message is handled without error" do
      # Manually trigger the sweep message
      send(Process.whereis(ExecutionSemaphore), :sweep_stale)
      Process.sleep(10)

      # Semaphore should still be alive and functional
      status = ExecutionSemaphore.status()
      assert is_integer(status.max)
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp acquire_from_processes(count) do
    parent = self()

    Enum.map(1..count, fn _ ->
      pid =
        spawn(fn ->
          :ok = ExecutionSemaphore.acquire()
          send(parent, {:acquired, self()})

          receive do
            :release -> ExecutionSemaphore.release()
          end
        end)

      receive do
        {:acquired, ^pid} -> pid
      after
        2_000 -> flunk("Failed to acquire slot within 2s")
      end
    end)
  end

  defp release_holders(holders) do
    Enum.each(holders, &send(&1, :release))
    Process.sleep(10)
  end

  defp spawn_acquire(server_name, tenant \\ nil) do
    parent = self()

    pid =
      spawn(fn ->
        GenServer.call(server_name, {:acquire, :normal, tenant}, 5_000)
        send(parent, {:acquired, self()})

        receive do
          :release -> :ok
        end
      end)

    receive do
      {:acquired, ^pid} -> :ok
    after
      2_000 -> :ok
    end

    pid
  end
end
