# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Authority.BudgetGuardTest do
  use ExUnit.Case, async: false

  alias Sanctum.Authority.Budget
  alias Sanctum.Authority.BudgetGuard

  setup do
    Sanctum.Authority.Budget.ensure_table()
    {:ok, budget: Budget.new(2)}
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  test "a brutally killed holder's slot is released by the :DOWN compensation", %{budget: budget} do
    :ok = Budget.try_acquire(budget)

    holder =
      spawn(fn ->
        BudgetGuard.guard(budget)

        receive do
          :never -> :ok
        end
      end)

    wait_until(fn -> Process.alive?(holder) end)
    # Let the guard register (a call from the holder, so once it is alive
    # and has run its first line the registration is in flight).
    Process.sleep(20)

    # The untrappable kill — the exact signal `Task.shutdown(:brutal_kill)`
    # sends, which skips every `after` in the holder.
    Process.exit(holder, :kill)

    wait_until(fn -> Budget.snapshot(budget).in_flight == 0 end)
  end

  test "an explicit release removes the guard — the death cannot release twice", %{budget: budget} do
    :ok = Budget.try_acquire(budget)
    :ok = Budget.try_acquire(budget)

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
    assert Budget.snapshot(budget).in_flight == 1

    # The holder dies AFTER its explicit release; the demonitored guard
    # must not release the second (still legitimately held) slot.
    Process.exit(holder, :kill)
    Process.sleep(50)
    assert Budget.snapshot(budget).in_flight == 1

    :ok = Budget.release(budget)
    assert Budget.snapshot(budget).in_flight == 0
  end

  test "a release with no guard registered releases directly", %{budget: budget} do
    :ok = Budget.try_acquire(budget)
    :ok = BudgetGuard.release(budget, self())
    assert Budget.snapshot(budget).in_flight == 0
  end

  describe "release_after_exit/2 — what a failed release call means for the slot" do
    test "a timeout does not release: the queued message still will", %{budget: budget} do
      :ok = Budget.try_acquire(budget)

      # The guard is alive and the `{:release, ...}` message is in its
      # mailbox; only the reply was given up on. Releasing here as well
      # decremented twice for one charge, handing a concurrent sibling's
      # slot back early and letting the root outrun its consented cap.
      assert :ok =
               BudgetGuard.release_after_exit(
                 budget,
                 {:timeout, {GenServer, :call, [BudgetGuard, {:release, budget, self()}, 5000]}}
               )

      assert Budget.snapshot(budget).in_flight == 1

      :ok = Budget.release(budget)
      assert Budget.snapshot(budget).in_flight == 0
    end

    test "an exit that means the call never landed releases directly", %{budget: budget} do
      :ok = Budget.try_acquire(budget)

      assert :ok = BudgetGuard.release_after_exit(budget, {:noproc, {GenServer, :call, []}})
      assert Budget.snapshot(budget).in_flight == 0
    end

    test "a guard that died mid-handling still gives the slot back", %{budget: budget} do
      :ok = Budget.try_acquire(budget)

      assert :ok = BudgetGuard.release_after_exit(budget, :shutdown)
      assert Budget.snapshot(budget).in_flight == 0
    end
  end
end
