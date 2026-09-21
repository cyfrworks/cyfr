# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Authority.BudgetGuardTest do
  use ExUnit.Case, async: false

  import Cyfr.Test.Wait

  alias Cyfr.Authority.Budget
  alias Sanctum.Authority.BudgetCounter
  alias Sanctum.Authority.BudgetGuard

  setup do
    BudgetCounter.ensure_table()
    {:ok, budget: Budget.new(2)}
  end

  test "a brutally killed holder's slot is released by the :DOWN compensation", %{budget: budget} do
    :ok = BudgetCounter.try_acquire(budget)
    test_pid = self()

    holder =
      spawn(fn ->
        # A synchronous call: when it returns the registration is recorded,
        # so the signal below is proof, not a guess. Sleeping "long enough"
        # for it instead is what made this test's ordering a coin flip.
        BudgetGuard.guard(budget)
        send(test_pid, :guarded)

        receive do
          :never -> :ok
        end
      end)

    assert_receive :guarded, 1_000

    # The untrappable kill — the exact signal `Task.shutdown(:brutal_kill)`
    # sends, which skips every `after` in the holder.
    Process.exit(holder, :kill)

    wait_until(
      fn -> BudgetCounter.snapshot(budget).in_flight == 0 end,
      2_000,
      "the killed holder's slot to come back"
    )
  end

  test "an explicit release removes the guard — the death cannot release twice", %{budget: budget} do
    :ok = BudgetCounter.try_acquire(budget)
    :ok = BudgetCounter.try_acquire(budget)

    test_pid = self()

    holder =
      spawn(fn ->
        BudgetGuard.guard(budget)
        :ok = BudgetGuard.release(budget, self())
        send(test_pid, :released)

        receive do
          :never -> :ok
        end
      end)

    assert_receive :released, 1000
    assert BudgetCounter.snapshot(budget).in_flight == 1

    # The holder dies AFTER its explicit release; the demonitored guard
    # must not release the second (still legitimately held) slot.
    ref = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^ref, :process, ^holder, :killed}, 1_000

    # Both monitors were notified when the holder terminated, so the guard's
    # own `:DOWN` is already in its mailbox; a synchronous call drains past
    # it. Asserting after a fixed sleep proved nothing — a sleep too short
    # for the compensation to run reads exactly like a compensation that
    # correctly did not fire.
    :sys.get_state(BudgetGuard)
    assert BudgetCounter.snapshot(budget).in_flight == 1

    :ok = BudgetCounter.release(budget)
    assert BudgetCounter.snapshot(budget).in_flight == 0
  end

  # A process that guards one charged slot and waits.
  defp holding!(budget) do
    :ok = BudgetCounter.try_acquire(budget)
    test_pid = self()

    holder =
      spawn(fn ->
        BudgetGuard.guard(budget)
        send(test_pid, :guarded)

        receive do
          :never -> :ok
        end
      end)

    assert_receive :guarded, 1_000
    holder
  end

  describe "handover/3" do
    test "the slot moves: the old holder's death releases nothing, the new holder's releases it",
         %{budget: budget} do
      from = holding!(budget)

      to =
        spawn(fn ->
          receive do
            :never -> :ok
          end
        end)

      assert :ok = BudgetGuard.handover(budget, from, to)

      ref = Process.monitor(from)
      Process.exit(from, :kill)
      assert_receive {:DOWN, ^ref, :process, ^from, :killed}, 1_000
      :sys.get_state(BudgetGuard)
      assert BudgetCounter.snapshot(budget).in_flight == 1

      Process.exit(to, :kill)

      wait_until(
        fn -> BudgetCounter.snapshot(budget).in_flight == 0 end,
        2_000,
        "the new holder's slot to come back"
      )
    end

    test "a slot its holder already gave back is not taken over", %{budget: budget} do
      from = holding!(budget)
      ref = Process.monitor(from)
      Process.exit(from, :kill)
      assert_receive {:DOWN, ^ref, :process, ^from, :killed}, 1_000
      :sys.get_state(BudgetGuard)
      assert BudgetCounter.snapshot(budget).in_flight == 0

      assert :released = BudgetGuard.handover(budget, from, self())
      refute Map.has_key?(:sys.get_state(BudgetGuard).guards, {budget.id, self()})
    end
  end

  test "a release with no guard registered releases directly", %{budget: budget} do
    :ok = BudgetCounter.try_acquire(budget)
    :ok = BudgetGuard.release(budget, self())
    assert BudgetCounter.snapshot(budget).in_flight == 0
  end

  describe "release_after_exit/2 — what a failed release call means for the slot" do
    test "a timeout does not release: the queued message still will", %{budget: budget} do
      :ok = BudgetCounter.try_acquire(budget)

      # The guard is alive and the `{:release, ...}` message is in its
      # mailbox; only the reply was given up on. Releasing here as well
      # decremented twice for one charge, handing a concurrent sibling's
      # slot back early and letting the root outrun its consented cap.
      assert :ok =
               BudgetGuard.release_after_exit(
                 budget,
                 {:timeout, {GenServer, :call, [BudgetGuard, {:release, budget, self()}, 5000]}}
               )

      assert BudgetCounter.snapshot(budget).in_flight == 1

      :ok = BudgetCounter.release(budget)
      assert BudgetCounter.snapshot(budget).in_flight == 0
    end

    test "an exit that means the call never landed releases directly", %{budget: budget} do
      :ok = BudgetCounter.try_acquire(budget)

      assert :ok = BudgetGuard.release_after_exit(budget, {:noproc, {GenServer, :call, []}})
      assert BudgetCounter.snapshot(budget).in_flight == 0
    end

    test "a guard that died mid-handling still gives the slot back", %{budget: budget} do
      :ok = BudgetCounter.try_acquire(budget)

      assert :ok = BudgetGuard.release_after_exit(budget, :shutdown)
      assert BudgetCounter.snapshot(budget).in_flight == 0
    end
  end
end
