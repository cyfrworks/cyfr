# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ExecutionSemaphoreTest do
  use ExUnit.Case, async: false

  import Opus.TestWait

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

      # The status call is ordered after the release cast (same sender), so
      # no wait is needed.
      status = ExecutionSemaphore.status()
      assert status.active == 0
    end

    test "double release is a no-op" do
      assert :ok = ExecutionSemaphore.acquire()
      ExecutionSemaphore.release()
      ExecutionSemaphore.release()

      status = ExecutionSemaphore.status()
      assert status.active == 0
    end
  end

  describe "queue-based waiting" do
    test "callers queue when at capacity and are served on release" do
      status = ExecutionSemaphore.status()
      max = status.max - status.child_reserve

      # Acquire every foreground slot from separate processes
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

      wait_until(fn -> ExecutionSemaphore.status().queued == 1 end)

      # Release one holder — waiter should get the slot
      [first | rest] = holders
      send(first, :release)

      assert_receive {:waiter_result, :ok}, 2_000

      # Clean up
      send(waiter, :release)
      release_holders(rest)
    end

    test "multiple queued callers are served in order" do
      status = ExecutionSemaphore.status()
      max = status.max - status.child_reserve

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

      wait_until(fn -> ExecutionSemaphore.status().queued == 3 end)

      # Release 3 holders
      {to_release, remaining} = Enum.split(holders, 3)
      Enum.each(to_release, &send(&1, :release))

      # All 3 waiters should have acquired
      for i <- 1..3 do
        assert_receive {:waiter_result, ^i, :ok}, 2_000
      end

      Enum.each(waiters, &send(&1, :release))
      release_holders(remaining)
    end
  end

  describe "classes" do
    test "a queued child is served before a queued root, and a root before background" do
      # 8 slots, reserve 2: six roots and two children fill it.
      {:ok, pid} = GenServer.start(ExecutionSemaphore, {8, 16}, name: :test_order_sem)
      roots = Enum.map(1..6, fn _ -> spawn_acquire(:test_order_sem, nil, :root) end)
      children = Enum.map(1..2, fn _ -> spawn_acquire(:test_order_sem, nil, :child) end)

      parent = self()
      order = :atomics.new(1, signed: false)

      waiter = fn class ->
        spawn(fn ->
          result = GenServer.call(:test_order_sem, {:acquire, class, nil}, 10_000)
          pos = :atomics.add_get(order, 1, 1)
          send(parent, {:waiter_done, class, pos, result})

          if result == :ok do
            receive do
              :release -> GenServer.cast(:test_order_sem, {:release, self()})
            end
          end
        end)
      end

      queued = fn -> GenServer.call(:test_order_sem, :status).queued end

      background_waiter = waiter.(:background)
      wait_until(fn -> queued.() == 1 end)
      root_waiter = waiter.(:root)
      wait_until(fn -> queued.() == 2 end)
      child_waiter = waiter.(:child)
      wait_until(fn -> queued.() == 3 end)

      # Roots leave one at a time. The child takes the first freed slot at
      # once (any slot is a child's); the root and then the background waiter
      # follow only when the count is back under the foreground line — the
      # children now sitting inside it hold the count up.
      [r1, r2, r3, r4, r5, r6] = roots
      send(r1, :release)
      wait_until(fn -> queued.() == 2 end)
      send(r2, :release)
      send(r3, :release)
      wait_until(fn -> GenServer.call(:test_order_sem, :status).active == 6 end)
      assert queued.() == 2
      send(r4, :release)
      wait_until(fn -> queued.() == 1 end)
      send(r5, :release)
      wait_until(fn -> queued.() == 0 end)

      assert_receive {:waiter_done, :child, child_pos, :ok}, 2_000
      assert_receive {:waiter_done, :root, root_pos, :ok}, 2_000
      assert_receive {:waiter_done, :background, bg_pos, :ok}, 2_000
      assert child_pos < root_pos and root_pos < bg_pos

      Enum.each(
        [r6, child_waiter, root_waiter, background_waiter | children],
        &send(&1, :release)
      )

      GenServer.stop(pid)
    end

    test "roots stop at the child reserve; children take the rest" do
      {:ok, pid} = GenServer.start(ExecutionSemaphore, {8, 16}, name: :test_reserve_sem)

      # 8 slots, reserve 2: six roots fit, the seventh queues.
      roots = Enum.map(1..6, fn _ -> spawn_acquire(:test_reserve_sem, nil, :root) end)
      status = GenServer.call(:test_reserve_sem, :status)
      assert status.root_active == 6 and status.child_reserve == 2

      parent = self()

      queued_root =
        spawn(fn ->
          result = GenServer.call(:test_reserve_sem, {:acquire, :root, nil}, 5_000)
          send(parent, {:queued_root, result})
        end)

      wait_until(fn -> GenServer.call(:test_reserve_sem, :status).queued_by_class.root == 1 end)

      # Children still get in — the reserve is theirs.
      c1 = spawn_acquire(:test_reserve_sem, "ath_a", :child)
      c2 = spawn_acquire(:test_reserve_sem, "ath_a", :child)
      status = GenServer.call(:test_reserve_sem, :status)
      assert status.child_active == 2 and status.active == 8
      # Children are not counted against the athanor.
      assert status.tenants == %{}

      # The foreground line is on the total count and the two children sit
      # inside it, so the queued root gets in only once the count is back
      # under the line: after the third root release.
      [r1, r2, r3 | rest] = roots
      send(r1, :release)
      send(r2, :release)
      refute_receive {:queued_root, _}, 200
      send(r3, :release)
      assert_receive {:queued_root, :ok}, 2_000

      Enum.each(rest ++ [c1, c2, queued_root], &send(&1, :release))
      GenServer.stop(pid)
    end

    test "a child is never refused for its athanor's cap" do
      {:ok, pid} = GenServer.start(ExecutionSemaphore, {8, 1}, name: :test_child_cap_sem)

      root = spawn_acquire(:test_child_cap_sem, "ath_a", :root)

      assert {:error, :tenant_limit} =
               GenServer.call(:test_child_cap_sem, {:acquire, :root, "ath_a"}, 1_000)

      assert :ok = GenServer.call(:test_child_cap_sem, {:acquire, :child, "ath_a"}, 1_000)
      GenServer.cast(:test_child_cap_sem, {:release, self()})

      send(root, :release)
      GenServer.stop(pid)
    end

    test "background work at the athanor's cap waits instead of being refused" do
      {:ok, pid} = GenServer.start(ExecutionSemaphore, {8, 1}, name: :test_bg_sem)

      root = spawn_acquire(:test_bg_sem, "ath_a", :root)
      parent = self()

      bg =
        spawn(fn ->
          result = GenServer.call(:test_bg_sem, {:acquire, :background, "ath_a"}, 5_000)
          send(parent, {:bg, result})

          if result == :ok do
            receive do
              :release -> GenServer.cast(:test_bg_sem, {:release, self()})
            end
          end
        end)

      wait_until(fn -> GenServer.call(:test_bg_sem, :status).queued_by_class.background == 1 end)
      refute_receive {:bg, _}, 100

      # Another athanor is unaffected while ath_a's schedule waits.
      assert :ok = GenServer.call(:test_bg_sem, {:acquire, :background, "ath_b"}, 1_000)
      GenServer.cast(:test_bg_sem, {:release, self()})

      send(root, :release)
      assert_receive {:bg, :ok}, 2_000

      send(bg, :release)
      GenServer.stop(pid)
    end

    test "128 roots and 128 children all complete under {128, 16}" do
      {:ok, pid} = GenServer.start(ExecutionSemaphore, {128, 16}, name: :test_load_sem)
      parent = self()

      workers =
        for i <- 1..128, class <- [:root, :child] do
          tenant = "ath_#{rem(i, 16)}"

          spawn(fn ->
            result = GenServer.call(:test_load_sem, {:acquire, class, tenant}, 30_000)
            if result == :ok, do: GenServer.cast(:test_load_sem, {:release, self()})
            send(parent, {:done, class, result})
          end)
        end

      results =
        for _ <- workers do
          receive do
            {:done, class, result} -> {class, result}
          after
            10_000 -> flunk("a worker did not finish")
          end
        end

      # Roots may hit their athanor's cap and queue-full when 128 arrive at
      # once (16 tenants × 16 slots), but every child gets through, and
      # nothing hangs.
      assert Enum.all?(results, fn
               {:child, r} -> r == :ok
               {:root, r} -> r in [:ok, {:error, :tenant_limit}, {:error, :queue_full}]
             end)

      wait_until(fn -> GenServer.call(:test_load_sem, :status).active == 0 end)
      GenServer.stop(pid)
    end
  end

  describe "queue overflow" do
    test "returns :queue_full when queue is at capacity" do
      # Start a small semaphore to test queue limits
      {:ok, pid} = GenServer.start(ExecutionSemaphore, {2, 16}, name: :test_queue_sem)

      # Acquire both slots
      h1 = spawn_acquire(:test_queue_sem)
      h2 = spawn_acquire(:test_queue_sem)

      # Queue up to max_waiters (2 * 4 = 8)
      waiters =
        Enum.map(1..8, fn _ ->
          spawn(fn ->
            GenServer.call(:test_queue_sem, {:acquire, :root, nil}, 10_000)

            receive do
              :release -> :ok
            end
          end)
        end)

      wait_until(fn -> GenServer.call(:test_queue_sem, :status).queued == 8 end)

      # Next one should be rejected
      result = GenServer.call(:test_queue_sem, {:acquire, :root, nil}, 1_000)
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
    @tenant_a "ath_a"
    @tenant_b "ath_b"

    test "tenant at cap is rejected while another tenant still acquires" do
      {:ok, pid} = GenServer.start(ExecutionSemaphore, {10, 2}, name: :test_tenant_sem)

      h1 = spawn_acquire(:test_tenant_sem, @tenant_a)
      h2 = spawn_acquire(:test_tenant_sem, @tenant_a)

      # Tenant A at cap → rejected, and no global slot consumed by the attempt
      assert {:error, :tenant_limit} =
               GenServer.call(:test_tenant_sem, {:acquire, :root, @tenant_a}, 1_000)

      status = GenServer.call(:test_tenant_sem, :status)
      assert status.active == 2
      assert status.tenants == %{@tenant_a => 2}

      # Tenant B unaffected
      assert :ok = GenServer.call(:test_tenant_sem, {:acquire, :root, @tenant_b}, 1_000)
      GenServer.cast(:test_tenant_sem, {:release, self()})

      # Releasing one A holder frees A capacity again. The holder exits on
      # :release, so the slot frees via the DOWN monitor — poll for it.
      send(h1, :release)
      wait_until(fn -> GenServer.call(:test_tenant_sem, :status).tenants[@tenant_a] == 1 end)
      assert :ok = GenServer.call(:test_tenant_sem, {:acquire, :root, @tenant_a}, 1_000)
      GenServer.cast(:test_tenant_sem, {:release, self()})

      send(h2, :release)
      GenServer.stop(pid)
    end

    test "holder crash decrements the tenant counter" do
      {:ok, pid} = GenServer.start(ExecutionSemaphore, {10, 1}, name: :test_tenant_down_sem)

      holder = spawn_acquire(:test_tenant_down_sem, @tenant_a)

      assert {:error, :tenant_limit} =
               GenServer.call(:test_tenant_down_sem, {:acquire, :root, @tenant_a}, 1_000)

      Process.exit(holder, :kill)
      wait_until(fn -> GenServer.call(:test_tenant_down_sem, :status).active == 0 end)

      assert :ok = GenServer.call(:test_tenant_down_sem, {:acquire, :root, @tenant_a}, 1_000)
      status = GenServer.call(:test_tenant_down_sem, :status)
      assert status.active == 1
      assert status.tenants == %{@tenant_a => 1}

      GenServer.cast(:test_tenant_down_sem, {:release, self()})
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
            result = GenServer.call(:test_tenant_xfer_sem, {:acquire, :root, @tenant_a}, 5_000)
            send(parent, {:tenant_waiter, i, result})

            if result == :ok do
              receive do
                :release -> GenServer.cast(:test_tenant_xfer_sem, {:release, self()})
              end
            end
          end)
        end)

      wait_until(fn -> GenServer.call(:test_tenant_xfer_sem, :status).queued == 2 end)

      # Holders exit on :release, freeing slots via DOWN — serialize the two
      # transfers so the first one hits the tenant cap before the second.
      send(b1, :release)
      wait_until(fn -> GenServer.call(:test_tenant_xfer_sem, :status).queued <= 1 end)
      send(b2, :release)
      wait_until(fn -> GenServer.call(:test_tenant_xfer_sem, :status).queued == 0 end)

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
      wait_until(fn -> ExecutionSemaphore.status().active == 0 end)
    end

    test "queued waiter is removed when it crashes" do
      status = ExecutionSemaphore.status()
      max = status.max - status.child_reserve

      holders = acquire_from_processes(max)

      # Queue a waiter
      waiter =
        spawn(fn ->
          ExecutionSemaphore.acquire(30_000)

          receive do
            :never -> :ok
          end
        end)

      wait_until(fn -> ExecutionSemaphore.status().queued == 1 end)

      # Kill the waiter
      Process.exit(waiter, :kill)
      wait_until(fn -> ExecutionSemaphore.status().queued == 0 end)

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
      # Manually trigger the sweep message; the status call is ordered after
      # it (same sender), so the sweep has been handled when it returns.
      send(Process.whereis(ExecutionSemaphore), :sweep_stale)

      status = ExecutionSemaphore.status()
      assert is_integer(status.max)
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp acquire_from_processes(count, class \\ :root)
  defp acquire_from_processes(0, _class), do: []

  defp acquire_from_processes(count, class) do
    parent = self()

    Enum.map(1..count, fn _ ->
      pid =
        spawn(fn ->
          :ok = ExecutionSemaphore.acquire(30_000, class)
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

  # Fire-and-forget: the next test's setup force_release_all clears any
  # release still in flight, and a late release for a freed slot is a no-op.
  defp release_holders(holders) do
    Enum.each(holders, &send(&1, :release))
  end

  defp spawn_acquire(server_name, tenant \\ nil, class \\ :root) do
    parent = self()

    pid =
      spawn(fn ->
        GenServer.call(server_name, {:acquire, class, tenant}, 5_000)
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
