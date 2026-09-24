# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.SlotsTest do
  # Every test starts its own instance, so nothing here is node-global.
  use ExUnit.Case, async: true

  alias Prima.Slots

  @moduletag :capture_log

  # ---------------------------------------------------------------------------
  # Configuration
  # ---------------------------------------------------------------------------

  describe "configuration" do
    test "the defaults are the execution slots' numbers" do
      assert Slots.default_max() == 128
      assert Slots.default_key_max() == 16
      assert Slots.child_reserve(128) == 32
      assert Slots.child_reserve(8) == 2
      assert Slots.child_reserve(2) == 0
      assert Slots.background_ceiling(16) == 8
      assert Slots.background_ceiling(1) == 1
      assert Slots.unreaped_threshold(16) == 8
      assert Slots.unreaped_threshold(2) == 2

      server = start_slots()

      assert %{max: 128, key_max: 16, child_reserve: 32, active: 0, available: 128} =
               Slots.status(server)
    end

    test "the authority depth cap fits inside the default child reserve" do
      # A parent holds its slot while blocking on a child, so a chain deeper
      # than the slots a child can always reach would self-deadlock. If this
      # is red the shipped numbers are unsafe; do not weaken it.
      assert Prima.Authority.depth_cap() <= Slots.child_reserve(Slots.default_max())
      assert Slots.max_key_footprint(16) == 16 * Prima.Authority.depth_cap()
    end

    test "the build slots are one configuration of the same server" do
      server = start_slots(max: 2, key_max: 1, child_reserve: 0, policy: :reject)
      assert %{max: 2, key_max: 1, child_reserve: 0} = Slots.status(server)
    end

    test "an invalid option is refused before anything starts" do
      for bad <- [
            [max: 0],
            [max: :lots],
            [key_max: 0],
            [child_reserve: 8, max: 8],
            [child_reserve: -1],
            [policy: :sometimes],
            [policy: %{root: :maybe}],
            [policy: %{grandchild: :wait}],
            [hold_ms: -1],
            [sweep_interval_ms: 0],
            [unreaped_ttl_ms: 0],
            [unreaped_max: 0]
          ] do
        assert_raise ArgumentError, fn -> Slots.start_link(bad) end
      end
    end

    test "a per-class policy map fills the classes it leaves out with :wait" do
      server = start_slots(max: 1, child_reserve: 0, policy: %{root: :reject})
      {:ok, _ref} = Slots.acquire(server, nil, :root)

      assert {:error, :capacity} = Slots.acquire(server, nil, :root)
      assert {:error, :timeout} = Slots.acquire(server, nil, :child, wait_ms: 20)
    end

    test "the child spec is keyed by the name so two instances share a supervisor" do
      assert %{id: :slots_a, start: {Slots, :start_link, [[name: :slots_a]]}} =
               Slots.child_spec(name: :slots_a)

      assert %{id: Slots} = Slots.child_spec([])

      a = :"slots_a_#{System.unique_integer([:positive])}"
      b = :"slots_b_#{System.unique_integer([:positive])}"
      start_supervised!({Slots, name: a, max: 1, child_reserve: 0})
      start_supervised!({Slots, name: b, max: 1, child_reserve: 0})

      assert {:ok, _} = Slots.acquire(a, nil, :root)
      assert {:ok, _} = Slots.acquire(b, nil, :root)
      assert {:error, :timeout} = Slots.acquire(a, nil, :root, wait_ms: 20)
    end

    test "a wait must be a non-negative integer or :infinity" do
      server = start_slots()
      assert_raise ArgumentError, fn -> Slots.acquire(server, nil, :root, wait_ms: -1) end
      assert_raise ArgumentError, fn -> Slots.acquire(server, nil, :root, wait_ms: "soon") end
    end
  end

  # ---------------------------------------------------------------------------
  # Acquire and release
  # ---------------------------------------------------------------------------

  describe "acquire and release" do
    test "an acquire answers a ref and a release frees the slot" do
      server = start_slots()
      assert {:ok, ref} = Slots.acquire(server, nil, :root)
      assert is_reference(ref)
      assert %{active: 1, available: 127, root_active: 1} = Slots.status(server)

      Slots.release(server, ref)
      # The status call is ordered after the release cast (same sender).
      assert %{active: 0, available: 128, holders: []} = Slots.status(server)
    end

    test "a process holding two slots gives them back one ref at a time" do
      server = start_slots()
      {:ok, root} = Slots.acquire(server, "ath_nested", :root)
      {:ok, child} = Slots.acquire(server, "ath_nested", :child)

      # Only the root is counted against the key.
      assert %{active: 2, root_active: 1, child_active: 1, keys: %{"ath_nested" => 1}} =
               Slots.status(server)

      Slots.release(server, root)
      assert %{active: 1, child_active: 1, keys: keys} = Slots.status(server)
      refute Map.has_key?(keys, "ath_nested")

      Slots.release(server, child)
      assert %{active: 0} = Slots.status(server)
    end

    test "a process that dies holding two slots gives both back" do
      server = start_slots()
      holder = hold(server, "ath_down", :root)
      {:ok, _} = acquire_in(holder, server, "ath_down", :child)
      assert %{active: 2, keys: %{"ath_down" => 1}} = Slots.status(server)

      Process.exit(holder, :kill)
      wait_until(fn -> Slots.status(server).active == 0 end)
      assert Slots.status(server).keys == %{}
    end

    test "a double release and a release of an unknown ref are no-ops" do
      server = start_slots(max: 1, child_reserve: 0)
      {:ok, ref} = Slots.acquire(server, nil, :root)

      Slots.release(server, ref)
      Slots.release(server, ref)
      Slots.release(server, make_ref())
      assert %{active: 0} = Slots.status(server)

      # The count did not underflow: exactly one slot is there to take.
      assert {:ok, _} = Slots.acquire(server, nil, :root)
      assert {:error, :timeout} = Slots.acquire(server, nil, :root, wait_ms: 20)
    end

    test "the same holder may take several slots and each counts on its own ref" do
      server = start_slots(max: 2, key_max: 1, child_reserve: 0, policy: :reject)
      assert {:ok, first} = Slots.acquire(server, nil, :root)
      assert {:ok, _second} = Slots.acquire(server, nil, :root)
      assert {:error, :capacity} = Slots.acquire(server, nil, :root)

      Slots.release(server, first)
      assert {:ok, _third} = Slots.acquire(server, nil, :root)
      assert %{active: 2} = Slots.status(server)
    end
  end

  # ---------------------------------------------------------------------------
  # The reject policy (the build slots)
  # ---------------------------------------------------------------------------

  describe "the reject policy" do
    test "grants up to the cap, refuses past it with :capacity, and frees on release" do
      server = start_slots(max: 2, key_max: 1, child_reserve: 0, policy: :reject)
      assert {:ok, a} = Slots.acquire(server, nil, :root)
      assert {:ok, _b} = Slots.acquire(server, nil, :root)
      assert {:error, :capacity} = Slots.acquire(server, nil, :root)

      Slots.release(server, a)
      assert {:ok, _c} = Slots.acquire(server, nil, :root)
    end

    test "a refused acquire does not eat a slot" do
      server = start_slots(max: 1, key_max: 1, child_reserve: 0, policy: :reject)
      assert {:ok, ref} = Slots.acquire(server, nil, :root)
      assert {:error, :capacity} = Slots.acquire(server, nil, :root)
      assert {:error, :capacity} = Slots.acquire(server, nil, :root)
      assert %{active: 1, queued: 0} = Slots.status(server)

      Slots.release(server, ref)
      assert {:ok, _} = Slots.acquire(server, nil, :root)
    end

    test "a key at its cap is refused :key_cap while another key still builds" do
      server = start_slots(max: 2, key_max: 1, child_reserve: 0, policy: :reject)
      assert {:ok, _} = Slots.acquire(server, "ath_a", :root)
      assert {:error, :key_cap} = Slots.acquire(server, "ath_a", :root)
      assert {:ok, _} = Slots.acquire(server, "ath_b", :root)
      assert {:error, :capacity} = Slots.acquire(server, "ath_c", :root)
      assert %{active: 2, keys: %{"ath_a" => 1, "ath_b" => 1}} = Slots.status(server)
    end

    test "a release without an acquire never underflows the count" do
      server = start_slots(max: 1, child_reserve: 0, policy: :reject)
      Slots.release(server, make_ref())
      Slots.release(server, make_ref())

      assert {:ok, _} = Slots.acquire(server, nil, :root)
      assert {:error, :capacity} = Slots.acquire(server, nil, :root)
    end

    test "a brutally killed holder frees its slot without calling release" do
      server = start_slots(max: 1, child_reserve: 0, policy: :reject)
      holder = hold(server, nil, :root)
      assert {:error, :capacity} = Slots.acquire(server, nil, :root)

      # A brutal kill and an exit signal both bypass `after`: only the
      # monitor can return the slot.
      Process.exit(holder, :kill)
      wait_until(fn -> match?({:ok, _}, Slots.acquire(server, nil, :root)) end)
    end

    test "a killed holder releases every slot it held" do
      server = start_slots(max: 2, child_reserve: 0, policy: :reject)
      holder = hold(server, nil, :root)
      {:ok, _} = acquire_in(holder, server, nil, :root)
      assert {:error, :capacity} = Slots.acquire(server, nil, :root)

      Process.exit(holder, :kill)
      wait_until(fn -> Slots.status(server).active == 0 end)
      assert {:ok, _} = Slots.acquire(server, nil, :root)
      assert {:ok, _} = Slots.acquire(server, nil, :root)
    end
  end

  # ---------------------------------------------------------------------------
  # The wait policy
  # ---------------------------------------------------------------------------

  describe "the wait policy" do
    test "callers queue when at capacity and are served in order on release" do
      server = start_slots(max: 4, child_reserve: 1)
      holders = for _ <- 1..3, do: hold(server, nil, :root)
      waiters = for i <- 1..3, do: wait_for(server, nil, :root, tag: i)
      wait_until(fn -> Slots.status(server).queued == 3 end)

      Enum.each(holders, &release_holder/1)

      for i <- 1..3 do
        assert_receive {:waited, ^i, {:ok, _ref}}, 2_000
      end

      assert %{active: 3, queued: 0} = Slots.status(server)
      Enum.each(waiters, &release_holder/1)
      wait_until(fn -> Slots.status(server).active == 0 end)
    end

    test "a waiter that times out is answered :timeout and leaves no slot behind" do
      server = start_slots(max: 1, child_reserve: 0)
      holder = hold(server, nil, :root)

      assert {:error, :timeout} = Slots.acquire(server, nil, :root, wait_ms: 30)
      assert %{active: 1, queued: 0} = Slots.status(server)

      release_holder(holder)
      wait_until(fn -> Slots.status(server).active == 0 end)
      assert %{holders: []} = Slots.status(server)
    end

    test "a wait of zero never queues" do
      server = start_slots(max: 1, child_reserve: 0)
      _holder = hold(server, nil, :root)

      assert {:error, :capacity} = Slots.acquire(server, nil, :root, wait_ms: 0)
      assert %{queued: 0} = Slots.status(server)
    end

    test "a wait of :infinity is served whenever a slot frees" do
      server = start_slots(max: 1, child_reserve: 0)
      holder = hold(server, nil, :root)
      waiter = wait_for(server, nil, :root, wait_ms: :infinity)
      wait_until(fn -> Slots.status(server).queued == 1 end)

      release_holder(holder)
      assert_receive {:waited, ^waiter, {:ok, _}}, 2_000
    end

    test "a queued waiter that dies leaves the queue and nothing is handed to it" do
      server = start_slots(max: 1, child_reserve: 0)
      holder = hold(server, nil, :root)
      waiter = wait_for(server, nil, :root)
      wait_until(fn -> Slots.status(server).queued == 1 end)

      Process.exit(waiter, :kill)
      wait_until(fn -> Slots.status(server).queued == 0 end)

      release_holder(holder)
      wait_until(fn -> Slots.status(server).active == 0 end)
    end

    test "a queued waiter cancelled from outside is answered :cancelled" do
      server = start_slots(max: 1, child_reserve: 0)
      holder = hold(server, nil, :root)
      waiter = wait_for(server, nil, :root)
      wait_until(fn -> Slots.status(server).queued == 1 end)

      assert :ok = Slots.cancel(server, waiter)
      assert_receive {:waited, ^waiter, {:error, :cancelled}}, 2_000
      assert %{queued: 0, active: 1} = Slots.status(server)

      # Cancelling a process with no wait is a no-op, and a slot the
      # process holds is not touched.
      assert :ok = Slots.cancel(server, holder)
      assert %{active: 1} = Slots.status(server)
    end

    test "a caller that stopped waiting has a slot granted meanwhile given straight back" do
      server = start_slots(max: 4)
      :ok = :sys.suspend(server)
      parent = self()

      # The server is wedged, so the call outlives its wait and grace; the
      # caller leaves with :timeout. When the server catches up it grants
      # the slot to nobody, and the abandon behind it gives it back.
      spawn(fn -> send(parent, {:gave_up, Slots.acquire(server, nil, :root, wait_ms: 0)}) end)
      assert_receive {:gave_up, {:error, :timeout}}, 3_000

      :ok = :sys.resume(server)
      assert %{active: 0, queued: 0, holders: []} = Slots.status(server)
    end

    test "the queue is bounded at four times the cap" do
      server = start_slots(max: 2, child_reserve: 0)
      _holders = for _ <- 1..2, do: hold(server, nil, :root)
      _waiters = for _ <- 1..8, do: wait_for(server, nil, :root)
      wait_until(fn -> Slots.status(server).queued == 8 end)

      assert {:error, :capacity} = Slots.acquire(server, nil, :root, wait_ms: 1_000)
      assert %{queued: 8} = Slots.status(server)
    end

    test "a key's background queue is bounded on its own" do
      server = start_slots(max: 8, key_max: 1, child_reserve: 0)
      # A root of ath_a puts the key at its background half (one of one).
      _root = hold(server, "ath_a", :root)
      _waiters = for _ <- 1..4, do: wait_for(server, "ath_a", :background)
      wait_until(fn -> Slots.status(server).queued_by_class.background == 4 end)

      assert {:error, :capacity} = Slots.acquire(server, "ath_a", :background, wait_ms: 1_000)
      # Another key's schedule is unaffected.
      assert {:ok, _} = Slots.acquire(server, "ath_b", :background)
    end
  end

  # ---------------------------------------------------------------------------
  # Classes and the reserve
  # ---------------------------------------------------------------------------

  describe "classes and the child reserve" do
    test "roots stop at the child reserve and children take the rest" do
      # 8 slots, reserve 2: six roots fit, the seventh queues.
      server = start_slots(max: 8, key_max: 16)
      roots = for _ <- 1..6, do: hold(server, nil, :root)
      assert %{root_active: 6, child_reserve: 2} = Slots.status(server)

      queued_root = wait_for(server, nil, :root)
      wait_until(fn -> Slots.status(server).queued_by_class.root == 1 end)

      # Children still get in: the reserve is theirs, and they are not
      # counted against the key.
      _c1 = hold(server, "ath_a", :child)
      _c2 = hold(server, "ath_a", :child)
      assert %{child_active: 2, active: 8, keys: %{}} = Slots.status(server)

      # The foreground line is on the total count and the two children sit
      # inside it, so the queued root gets in only once the count is back
      # under the line: after the third root release.
      [r1, r2, r3 | _rest] = roots
      release_holder(r1)
      release_holder(r2)
      refute_receive {:waited, ^queued_root, _}, 200
      release_holder(r3)
      assert_receive {:waited, ^queued_root, {:ok, _}}, 2_000
    end

    test "a queued child is served before a queued root, and a root before background" do
      # 8 slots, reserve 2: six roots and two children fill it.
      server = start_slots(max: 8, key_max: 16)
      roots = for _ <- 1..6, do: hold(server, nil, :root)
      _children = for _ <- 1..2, do: hold(server, nil, :child)

      order = :atomics.new(1, signed: false)
      queued = fn -> Slots.status(server).queued end

      background_waiter = wait_for(server, nil, :background, order: order)
      wait_until(fn -> queued.() == 1 end)
      root_waiter = wait_for(server, nil, :root, order: order)
      wait_until(fn -> queued.() == 2 end)
      child_waiter = wait_for(server, nil, :child, order: order)
      wait_until(fn -> queued.() == 3 end)

      # Roots leave one at a time. The child takes the first freed slot at
      # once (any slot is a child's); the root and then the background
      # waiter follow only when the count is back under the foreground line,
      # which the children now inside it hold up.
      [r1, r2, r3, r4, r5, _r6] = roots
      release_holder(r1)
      wait_until(fn -> queued.() == 2 end)
      release_holder(r2)
      release_holder(r3)
      wait_until(fn -> Slots.status(server).active == 6 end)
      assert queued.() == 2
      release_holder(r4)
      wait_until(fn -> queued.() == 1 end)
      release_holder(r5)
      wait_until(fn -> queued.() == 0 end)

      assert_receive {:waited, ^child_waiter, {:ok, _}, child_pos}, 2_000
      assert_receive {:waited, ^root_waiter, {:ok, _}, root_pos}, 2_000
      assert_receive {:waited, ^background_waiter, {:ok, _}, bg_pos}, 2_000
      assert child_pos < root_pos and root_pos < bg_pos
    end

    test "a queued child is served before a root queued earlier, even with no reserve" do
      server = start_slots(max: 1, child_reserve: 0)
      {:ok, ref} = Slots.acquire(server, nil, :root)

      root_waiter = wait_for(server, nil, :root)
      wait_until(fn -> Slots.status(server).queued == 1 end)
      child_waiter = wait_for(server, nil, :child)
      wait_until(fn -> Slots.status(server).queued == 2 end)

      Slots.release(server, ref)
      assert_receive {:waited, ^child_waiter, {:ok, _}}, 2_000
      refute_received {:waited, ^root_waiter, _}

      release_holder(child_waiter)
      assert_receive {:waited, ^root_waiter, {:ok, _}}, 2_000
    end

    test "a child is never refused for its key's cap" do
      server = start_slots(max: 8, key_max: 1)
      _root = hold(server, "ath_a", :root)

      assert {:error, :key_cap} = Slots.acquire(server, "ath_a", :root, wait_ms: 1_000)
      assert {:ok, _} = Slots.acquire(server, "ath_a", :child, wait_ms: 1_000)
    end

    test "a child acquire never sees :key_cap under the shipped defaults" do
      server = start_slots()
      key = "ath_depth"
      _roots = for _ <- 1..Slots.default_key_max(), do: hold(server, key, :root)

      assert {:error, :key_cap} = Slots.acquire(server, key, :root, wait_ms: 1_000)
      assert {:ok, _} = Slots.acquire(server, key, :child, wait_ms: 1_000)
    end

    test "background work at the key's cap waits instead of being refused, and another key is unaffected" do
      server = start_slots(max: 8, key_max: 1)
      root = hold(server, "ath_a", :root)

      bg = wait_for(server, "ath_a", :background)
      wait_until(fn -> Slots.status(server).queued_by_class.background == 1 end)
      refute_receive {:waited, ^bg, _}, 100

      assert {:ok, other} = Slots.acquire(server, "ath_b", :background, wait_ms: 1_000)
      Slots.release(server, other)

      release_holder(root)
      assert_receive {:waited, ^bg, {:ok, _}}, 2_000
    end

    test "schedules stop at half the key's cap so the next turn still finds a slot" do
      # 8 background holders against a cap of 8: they stop at half, so the
      # member's turn still finds a slot instead of :key_cap.
      server = start_slots(max: 64, key_max: 8)
      waiters = for _ <- 1..8, do: wait_for(server, "ath_share", :background)

      admitted =
        for _ <- 1..4 do
          assert_receive {:waited, pid, {:ok, _}}, 2_000
          pid
        end

      refute_receive {:waited, _, _}, 300
      assert length(waiters -- admitted) == 4

      assert {:ok, _} = Slots.acquire(server, "ath_share", :root, wait_ms: 2_000)
    end

    test "the half-cap holds when someone else's freed slot is handed to a schedule" do
      # Queue hand-off enforces the same background cap as admission.
      server = start_slots(max: 64, key_max: 4)
      _mine = for _ <- 1..4, do: wait_for(server, "ath_h", :background)
      for _ <- 1..2, do: assert_receive({:waited, _, {:ok, _}}, 2_000)
      refute_receive {:waited, _, _}, 300

      # A different key takes a slot, then gives it back.
      {:ok, other} = Slots.acquire(server, "ath_other", :background)
      Slots.release(server, other)

      # Whatever the hand-off does with that slot, ath_h must not pass its
      # ceiling on the strength of someone else's release.
      assert %{keys: %{"ath_h" => 2}, queued: 2} = Slots.status(server)
      assert {:ok, _} = Slots.acquire(server, "ath_h", :root, wait_ms: 2_000)
    end

    test "more than the key's cap of same-minute schedules all run and none is lost" do
      # 24 schedules of one key fire at once under a cap of 16: as background
      # work they wait for a slot rather than being refused (a root would be
      # told :key_cap), and every one of them completes.
      server = start_slots(max: 64, key_max: 16)
      parent = self()

      for i <- 1..24 do
        spawn(fn ->
          result = Slots.acquire(server, "ath_sched", :background, wait_ms: 30_000)

          with {:ok, ref} <- result do
            # Hold the slot a moment so the cap is really hit.
            Process.sleep(20)
            Slots.release(server, ref)
          end

          send(parent, {:fired, i, result})
        end)
      end

      for _ <- 1..24 do
        assert_receive {:fired, _i, {:ok, _}}, 10_000
      end

      wait_until(fn -> Slots.status(server).active == 0 end)
    end

    test "128 roots and 128 children all complete under the defaults" do
      server = start_slots()
      parent = self()

      workers =
        for i <- 1..128, class <- [:root, :child] do
          key = "ath_#{rem(i, 16)}"

          spawn(fn ->
            result = Slots.acquire(server, key, class, wait_ms: 30_000)
            with {:ok, ref} <- result, do: Slots.release(server, ref)
            send(parent, {:done, class, result})
          end)
        end

      results =
        for _ <- workers do
          assert_receive {:done, class, result}, 10_000
          {class, result}
        end

      # Roots may meet their key's cap when 128 arrive at once (16 keys, 16
      # each, and roots at the cap are refused), but every child gets
      # through and nothing hangs.
      assert Enum.all?(results, fn
               {:child, result} -> match?({:ok, _}, result)
               {:root, result} -> match?({:ok, _}, result) or result == {:error, :key_cap}
             end)

      wait_until(fn -> Slots.status(server).active == 0 end)
    end
  end

  # ---------------------------------------------------------------------------
  # Per-key cap
  # ---------------------------------------------------------------------------

  describe "per-key cap" do
    test "a key at its cap is refused while another key still acquires, and a release frees it" do
      server = start_slots(max: 10, key_max: 2)
      h1 = hold(server, "ath_a", :root)
      _h2 = hold(server, "ath_a", :root)

      # At cap: refused, and no slot consumed by the attempt.
      assert {:error, :key_cap} = Slots.acquire(server, "ath_a", :root, wait_ms: 1_000)
      assert %{active: 2, keys: %{"ath_a" => 2}} = Slots.status(server)

      # Another key is unaffected.
      assert {:ok, b} = Slots.acquire(server, "ath_b", :root, wait_ms: 1_000)
      Slots.release(server, b)

      release_holder(h1)
      wait_until(fn -> Slots.status(server).keys["ath_a"] == 1 end)
      assert {:ok, _} = Slots.acquire(server, "ath_a", :root, wait_ms: 1_000)
    end

    test "a holder crash decrements the key count" do
      server = start_slots(max: 10, key_max: 1)
      holder = hold(server, "ath_a", :root)
      assert {:error, :key_cap} = Slots.acquire(server, "ath_a", :root, wait_ms: 1_000)

      Process.exit(holder, :kill)
      wait_until(fn -> Slots.status(server).active == 0 end)

      assert {:ok, _} = Slots.acquire(server, "ath_a", :root, wait_ms: 1_000)
      assert %{active: 1, keys: %{"ath_a" => 1}} = Slots.status(server)
    end

    test "a queued root whose key reaches its cap mid-wait is refused at hand-off" do
      # Total 3, key cap 2. A holds 1, B holds 2 (total full). Two A roots
      # queue (A below its cap at queue time). As B releases, the first
      # hand-off brings A to its cap, so the second A waiter is refused
      # instead of breaching it.
      server = start_slots(max: 3, key_max: 2)
      _a1 = hold(server, "ath_a", :root)
      b1 = hold(server, "ath_b", :root)
      b2 = hold(server, "ath_b", :root)

      waiters = for _ <- 1..2, do: wait_for(server, "ath_a", :root)
      wait_until(fn -> Slots.status(server).queued == 2 end)

      release_holder(b1)
      wait_until(fn -> Slots.status(server).queued <= 1 end)
      release_holder(b2)
      wait_until(fn -> Slots.status(server).queued == 0 end)

      results =
        for pid <- waiters do
          assert_receive {:waited, ^pid, result}, 2_000
          result
        end

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert {:error, :key_cap} in results
      assert %{active: 2, keys: %{"ath_a" => 2}} = Slots.status(server)
    end
  end

  # ---------------------------------------------------------------------------
  # Holder death
  # ---------------------------------------------------------------------------

  describe "holder death" do
    test "a slot is released when its holder crashes and handed to a waiter" do
      server = start_slots(max: 1, child_reserve: 0)
      holder = hold(server, "ath_a", :root)
      waiter = wait_for(server, "ath_b", :root)
      wait_until(fn -> Slots.status(server).queued == 1 end)

      Process.exit(holder, :kill)
      assert_receive {:waited, ^waiter, {:ok, _}}, 2_000
      assert %{active: 1, queued: 0, keys: %{"ath_b" => 1}} = Slots.status(server)
    end

    test "a process both holding and waiting that dies gives back its slot and leaves the queue" do
      server = start_slots(max: 1, child_reserve: 0)
      holder = hold(server, nil, :root)
      # The holder queues for a second slot in its own process.
      send(holder, {:acquire, server, nil, :root, [wait_ms: 30_000], self()})
      wait_until(fn -> Slots.status(server).queued == 1 end)

      Process.exit(holder, :kill)
      wait_until(fn -> Slots.status(server).active == 0 end)
      assert %{queued: 0} = Slots.status(server)
    end
  end

  # ---------------------------------------------------------------------------
  # Unreaped kills
  # ---------------------------------------------------------------------------

  describe "unreaped kills" do
    test "a key past the threshold is refused for roots and background; children and other keys pass; a force-release keeps the penalty" do
      server = start_slots(max: 16, key_max: 4)
      key = "ath_unreaped"
      threshold = Slots.unreaped_threshold(4)

      for n <- 1..threshold do
        {:ok, ref} = Slots.acquire(server, key, :root)
        # Acknowledged before the release: the note names the key, so the
        # order of the release and its :DOWN cannot lose it.
        assert {:ok, ^n} = Slots.note_unreaped(server, key, "exec_probe")
        Slots.release(server, ref)
      end

      assert %{unreaped: %{^key => ^threshold}} = Slots.status(server)
      assert {:error, :key_unreaped} = Slots.acquire(server, key, :root, wait_ms: 1_000)
      assert {:error, :key_unreaped} = Slots.acquire(server, key, :background, wait_ms: 1_000)

      # Another key is untouched by this one's penalty box.
      assert {:ok, other} = Slots.acquire(server, "ath_other", :root, wait_ms: 1_000)
      Slots.release(server, other)

      # Children pass: their parent already holds a slot.
      assert {:ok, child} = Slots.acquire(server, key, :child, wait_ms: 1_000)
      Slots.release(server, child)

      # The operator's recovery gesture frees the slots, not the penalty.
      assert {:ok, _} = Slots.force_release_all(server)
      assert {:error, :key_unreaped} = Slots.acquire(server, key, :root, wait_ms: 1_000)
    end

    test "a note charges the key without the noter holding a slot" do
      # A cancel runs in the canceller's process, never the holder's. N
      # cancels of a spinning guest trip the box exactly as N timeouts do.
      server = start_slots(max: 16, key_max: 4)

      for _ <- 1..2,
          do: assert({:ok, _} = Slots.note_unreaped(server, "ath_cancelled", "exec_probe"))

      assert {:error, :key_unreaped} =
               Slots.acquire(server, "ath_cancelled", :root, wait_ms: 1_000)
    end

    test "a note with no key charges nobody" do
      server = start_slots()
      before = Slots.status(server).unreaped
      assert {:ok, 0} = Slots.note_unreaped(server, nil, "exec_probe")
      assert Slots.status(server).unreaped == before
    end

    test "a queued root whose key entered the penalty box mid-wait is refused at hand-off" do
      server = start_slots(max: 1, key_max: 4, child_reserve: 0)
      {:ok, ref} = Slots.acquire(server, "ath_other", :root)
      waiter = wait_for(server, "ath_late", :root)
      wait_until(fn -> Slots.status(server).queued == 1 end)

      for _ <- 1..2, do: {:ok, _} = Slots.note_unreaped(server, "ath_late", "exec_probe")
      Slots.release(server, ref)

      assert_receive {:waited, ^waiter, {:error, :key_unreaped}}, 2_000
      assert %{active: 0, queued: 0} = Slots.status(server)
    end

    test "notes decay after the ttl" do
      server = start_slots(max: 16, key_max: 4, unreaped_ttl_ms: 40)
      for _ <- 1..2, do: {:ok, _} = Slots.note_unreaped(server, "ath_decay", "exec_probe")
      assert {:error, :key_unreaped} = Slots.acquire(server, "ath_decay", :root)

      wait_until(fn -> match?({:ok, _}, Slots.acquire(server, "ath_decay", :root)) end)
      # The sweep drops the decayed entries from the status too.
      assert {:ok, _} = Slots.sweep(server)
      assert Slots.status(server).unreaped == %{}
    end

    test "forgiving a key clears its penalty at once" do
      server = start_slots(max: 16, key_max: 4)
      for _ <- 1..2, do: {:ok, _} = Slots.note_unreaped(server, "ath_forgiven", "exec_probe")
      assert {:error, :key_unreaped} = Slots.acquire(server, "ath_forgiven", :root)

      assert :ok = Slots.forgive_unreaped(server, "ath_forgiven")
      assert {:ok, _} = Slots.acquire(server, "ath_forgiven", :root)
      assert Slots.status(server).unreaped == %{}
    end

    test "the threshold is configurable" do
      server = start_slots(max: 16, key_max: 4, unreaped_max: 1)
      assert {:ok, 1} = Slots.note_unreaped(server, "ath_one", "exec_probe")
      assert {:error, :key_unreaped} = Slots.acquire(server, "ath_one", :root)
    end
  end

  # ---------------------------------------------------------------------------
  # Sweep
  # ---------------------------------------------------------------------------

  describe "the stale sweep" do
    # The sweep is a backstop for a holding whose :DOWN never arrived, not a
    # time limit on work. A consented long run must keep its slot however
    # long it runs, or the caps over-admit beside it.
    test "a live holder past the hold keeps its slot and is reported wedged" do
      server = start_slots(max: 4, hold_ms: 1)
      holder = hold(server, nil, :root)
      Process.sleep(10)

      assert {:ok, %{reclaimed: 0, wedged: 1}} = Slots.sweep(server)
      assert %{active: 1} = Slots.status(server)
      assert Process.alive?(holder)
    end

    test "a dead holder whose DOWN never arrived is reclaimed after the hold" do
      server = start_slots(max: 4, hold_ms: 1)
      holder = hold(server, "ath_a", :root)
      {:ok, _} = acquire_in(holder, server, "ath_a", :child)

      # Kill it with the server's monitor dropped first, so the :DOWN never
      # arrives: exactly the leak the sweep exists to clean up.
      swallow_down(server, holder)
      kill_and_wait(holder)
      Process.sleep(10)
      assert %{active: 2} = Slots.status(server)

      assert {:ok, %{reclaimed: 2, wedged: 0}} = Slots.sweep(server)
      assert %{active: 0, keys: %{}} = Slots.status(server)
    end

    test "a dead holder inside the hold is left for its DOWN" do
      server = start_slots(max: 4, hold_ms: 60_000)
      holder = hold(server, nil, :root)
      swallow_down(server, holder)
      kill_and_wait(holder)

      assert {:ok, %{reclaimed: 0, wedged: 0}} = Slots.sweep(server)
      assert %{active: 1} = Slots.status(server)
    end

    test "a reclaimed slot is handed to a waiter" do
      server = start_slots(max: 1, child_reserve: 0, hold_ms: 1)
      holder = hold(server, nil, :root)
      waiter = wait_for(server, nil, :root)
      wait_until(fn -> Slots.status(server).queued == 1 end)

      swallow_down(server, holder)
      kill_and_wait(holder)
      Process.sleep(10)

      assert {:ok, %{reclaimed: 1}} = Slots.sweep(server)
      assert_receive {:waited, ^waiter, {:ok, _}}, 2_000
    end

    test "the periodic sweep runs on its interval" do
      server = start_slots(max: 4, hold_ms: 1, sweep_interval_ms: 20)
      holder = hold(server, nil, :root)
      swallow_down(server, holder)
      kill_and_wait(holder)

      wait_until(fn -> Slots.status(server).active == 0 end)
    end

    test "an empty server sweeps to nothing" do
      server = start_slots()
      assert {:ok, %{reclaimed: 0, wedged: 0}} = Slots.sweep(server)
    end
  end

  # ---------------------------------------------------------------------------
  # Force release
  # ---------------------------------------------------------------------------

  describe "force_release_all/1" do
    test "drops every holding, cancels every waiter and answers what it did" do
      server = start_slots(max: 3, child_reserve: 0)
      holders = for _ <- 1..3, do: hold(server, "ath_a", :root)
      waiter = wait_for(server, "ath_b", :root)
      wait_until(fn -> Slots.status(server).queued == 1 end)

      assert {:ok, %{released: 3, cancelled: 1}} = Slots.force_release_all(server)
      assert_receive {:waited, ^waiter, {:error, :cancelled}}, 2_000
      assert %{active: 0, queued: 0, holders: [], keys: %{}} = Slots.status(server)

      # The old holders' own releases find nothing to give back; new work
      # is admitted.
      Enum.each(holders, &release_holder/1)
      assert {:ok, _} = Slots.acquire(server, "ath_a", :root)
      assert {:ok, _} = Slots.acquire(server, "ath_a", :root)
      assert {:ok, _} = Slots.acquire(server, "ath_a", :root)
      assert %{active: 3} = Slots.status(server)

      assert {:ok, %{released: 3, cancelled: 0}} = Slots.force_release_all(server)
      assert {:ok, %{released: 0, cancelled: 0}} = Slots.force_release_all(server)
    end
  end

  # ---------------------------------------------------------------------------
  # Status
  # ---------------------------------------------------------------------------

  describe "status/1" do
    test "reports the counts, the holders with their age, and the per-key numbers" do
      # Key cap 4: its background half is 2, so a root and a schedule of the
      # same key both hold.
      server = start_slots(max: 8, key_max: 4)
      {:ok, _} = Slots.acquire(server, "ath_a", :root)
      _bg = hold(server, "ath_a", :background)
      _child = hold(server, "ath_b", :child)

      status = Slots.status(server)
      assert status.max == 8
      assert status.active == 3
      assert status.available == 5
      assert status.child_reserve == 2
      assert status.key_max == 4
      assert status.root_active == 1
      assert status.background_active == 1
      assert status.child_active == 1
      assert status.queued == 0
      assert status.queued_by_class == %{root: 0, child: 0, background: 0}
      assert status.keys == %{"ath_a" => 2}
      assert status.unreaped == %{}
      refute Map.has_key?(status, :error)

      assert length(status.holders) == 3
      mine = Enum.find(status.holders, &(&1.pid == inspect(self())))
      assert %{alive: true, class: :root, key: "ath_a"} = mine
      assert is_integer(mine.held_ms) and mine.held_ms >= 0
    end

    test "the unavailable fallback carries the same keys as a live reply" do
      {:ok, server} = Slots.start_link(max: 4)
      live = Slots.status(server)
      :ok = GenServer.stop(server)

      down = Slots.status(server)
      assert down.error == :unavailable
      assert down.keys == %{}
      assert down.max == 0

      assert Map.keys(live) -- Map.keys(down) == [],
             "the fallback is missing keys the live reply has — a reader that narrows the live " <>
               "shape crashes on the fallback"
    end
  end

  # ---------------------------------------------------------------------------
  # Server down
  # ---------------------------------------------------------------------------

  describe "when the server is not running" do
    test "every call answers :unavailable and a release is a silent no-op" do
      {:ok, server} = Slots.start_link(max: 4)
      :ok = GenServer.stop(server)

      assert {:error, :unavailable} = Slots.acquire(server, "ath_a", :root)
      assert {:error, :unavailable} = Slots.acquire(server, "ath_a", :root, wait_ms: 0)
      assert :ok = Slots.release(server, make_ref())
      assert {:error, :unavailable} = Slots.cancel(server, self())
      assert {:error, :unavailable} = Slots.note_unreaped(server, "ath_a", "exec")
      assert {:ok, 0} = Slots.note_unreaped(server, nil, "exec")
      assert {:error, :unavailable} = Slots.forgive_unreaped(server, "ath_a")
      assert {:error, :unavailable} = Slots.force_release_all(server)
      assert {:error, :unavailable} = Slots.sweep(server)
    end

    test "a name nobody registered answers the same" do
      name = :"slots_nobody_#{System.unique_integer([:positive])}"
      assert {:error, :unavailable} = Slots.acquire(name, nil, :root)
      assert :ok = Slots.release(name, make_ref())
      assert {:error, :unavailable} = Slots.force_release_all(name)
      assert %{error: :unavailable} = Slots.status(name)
    end

    test "a waiter whose server stops mid-wait is answered :unavailable" do
      {:ok, server} = Slots.start_link(max: 1, child_reserve: 0)
      {:ok, _} = Slots.acquire(server, nil, :root)
      waiter = wait_for(server, nil, :root)
      wait_until(fn -> Slots.status(server).queued == 1 end)

      :ok = GenServer.stop(server)
      assert_receive {:waited, ^waiter, {:error, :unavailable}}, 2_000
    end
  end

  # ---------------------------------------------------------------------------
  # Refusals and stopping
  # ---------------------------------------------------------------------------

  describe "refusal/1" do
    test "every refusal has a sentence, and the execution ones read as before" do
      for reason <- [:capacity, :key_cap, :key_unreaped, :timeout, :cancelled, :unavailable] do
        sentence = Slots.refusal(reason)
        assert byte_size(sentence) > 0
      end

      assert Slots.refusal(:capacity) == "Server at maximum concurrent executions. Retry later."
      assert Slots.refusal(:key_cap) == "Athanor at maximum concurrent executions. Retry later."
      assert Slots.refusal(:key_unreaped) =~ "could not be reclaimed"
    end
  end

  describe "stopping" do
    test "stopping with holders and waiters is clean" do
      {:ok, server} = Slots.start_link(max: 1, child_reserve: 0)
      {:ok, _} = Slots.acquire(server, nil, :root)
      _waiter = wait_for(server, nil, :root)
      wait_until(fn -> Slots.status(server).queued == 1 end)

      assert :ok = GenServer.stop(server)
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp start_slots(opts \\ []) do
    start_supervised!(Supervisor.child_spec({Slots, opts}, id: make_ref()))
  end

  # A process that takes a slot, keeps it until told to release or is
  # killed, and can take more on request (`{:acquire, ...}`).
  defp hold(server, key, class) do
    parent = self()

    pid =
      spawn(fn ->
        result = Slots.acquire(server, key, class, wait_ms: 5_000)
        send(parent, {:held, self(), result})
        holder_loop(server, [ref!(result)])
      end)

    assert_receive {:held, ^pid, {:ok, _}}, 5_000
    pid
  end

  defp holder_loop(server, refs) do
    receive do
      {:acquire, ^server, key, class, opts, reply_to} ->
        result = Slots.acquire(server, key, class, opts)
        send(reply_to, {:acquired, self(), result})

        case result do
          {:ok, ref} -> holder_loop(server, [ref | refs])
          _ -> holder_loop(server, refs)
        end

      :release ->
        Enum.each(refs, &Slots.release(server, &1))
    end
  end

  # Take another slot in `holder`'s process.
  defp acquire_in(holder, server, key, class, opts \\ []) do
    send(holder, {:acquire, server, key, class, opts, self()})
    assert_receive {:acquired, ^holder, result}, 5_000
    result
  end

  defp release_holder(pid), do: send(pid, :release)

  # A process that queues for a slot and reports the answer as
  # `{:waited, tag, result}` (`{:waited, tag, result, position}` when an
  # `:order` counter is given); the tag defaults to the pid. On success it
  # holds the slot until told to release.
  defp wait_for(server, key, class, opts \\ []) do
    parent = self()
    {tag, opts} = Keyword.pop(opts, :tag)
    {order, opts} = Keyword.pop(opts, :order)
    opts = Keyword.put_new(opts, :wait_ms, 10_000)

    spawn(fn ->
      result = Slots.acquire(server, key, class, opts)
      tag = tag || self()

      if order,
        do: send(parent, {:waited, tag, result, :atomics.add_get(order, 1, 1)}),
        else: send(parent, {:waited, tag, result})

      with {:ok, ref} <- result do
        receive do
          :release -> Slots.release(server, ref)
        end
      end
    end)
  end

  defp ref!({:ok, ref}), do: ref

  # Demonitor the server's own watch on `pid` so its :DOWN never arrives,
  # leaving the entry behind for the sweep to find.
  defp swallow_down(server, pid) do
    :sys.replace_state(server, fn state ->
      case state.pids[pid] do
        %{monitor: monitor} -> Process.demonitor(monitor, [:flush])
        _ -> :ok
      end

      state
    end)
  end

  defp kill_and_wait(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline, timeout)
  end

  defp poll(fun, deadline, timeout) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("waited #{timeout}ms for a condition which never held")

      true ->
        Process.sleep(10)
        poll(fun, deadline, timeout)
    end
  end
end
