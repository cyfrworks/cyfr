# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority do
  @moduledoc """
  The live half of `Cyfr.Authority`: what an authority does against this
  node's running state rather than as data.

    * `step/3` is `Cyfr.Authority.Transition.step/3` with the root budget
      charged. Every `spawn` outcome that starts work — a bound child, a
      zero child, or an allowed tool dispatch — takes one slot of the
      root-keyed invoke budget at this single chokepoint; exhaustion turns
      the outcome into `{:deny, :invoke_budget_exhausted}`. A denied or
      malformed spawn consumes nothing, and synchronous `call` is bounded
      by the depth cap instead: it adds no concurrency, the parent blocks.
      The caller releases the slot via `release_invoke/1` when the spawned
      work completes.
    * The invoke-budget counter (`Sanctum.Authority.BudgetCounter`) behind
      the budget id: `try_acquire_invoke/1`, `guard_invoke/2`,
      `take_over_invoke/2`, `release_invoke/1` and `budget/1`. The id names the root's reservation
      row (`Arca.BudgetReservations`), which is the authority on what is in
      flight; the counter on this node is a pre-check.
  """

  alias Cyfr.Authority
  alias Cyfr.Authority.Budget
  alias Cyfr.Authority.Transition
  alias Sanctum.Authority.BudgetCounter
  alias Sanctum.Authority.BudgetGuard

  # ============================================================================
  # Charged transition
  # ============================================================================

  @doc """
  Apply one guest function to a target under an Authority, charging the
  root budget for every `spawn` that starts work.

  The decision is `Cyfr.Authority.Transition.step/3`'s; a caller that
  dispatches the outcome as spawned work steps through here so no handler
  can forget the charge and no deny path needs a rollback.
  """
  @spec step(Authority.t(), Transition.guest_fn(), Transition.target()) :: Transition.outcome()
  def step(%Authority{} = auth, guest_fn, target) do
    auth
    |> Transition.step(guest_fn, target)
    |> charge_spawn_budget(auth, guest_fn)
  end

  defp charge_spawn_budget(outcome, auth, :spawn)
       when elem(outcome, 0) in [:child, :child_zero, :allow_tool] do
    case try_acquire_invoke(auth) do
      :ok -> outcome
      {:error, :invoke_budget_exhausted} -> {:deny, :invoke_budget_exhausted}
    end
  end

  defp charge_spawn_budget(outcome, _auth, _fun), do: outcome

  # ============================================================================
  # Root budget
  # ============================================================================

  @doc """
  Take one root-keyed invoke-budget slot. Every acquire must be paired with
  `release_invoke/1` when the spawned work completes — and the process
  doing the work registers itself with `guard_invoke/2` so a slot whose
  holder is brutally killed (the cancel and await-timeout paths) is
  released by the guard's `:DOWN` compensation instead of leaking.
  """
  @spec try_acquire_invoke(Authority.t()) :: :ok | {:error, :invoke_budget_exhausted}
  def try_acquire_invoke(%Authority{budget: %Budget{} = budget}),
    do: BudgetCounter.try_acquire(budget)

  @doc """
  Register the calling (or named) process as the holder of one charged
  slot — see `Sanctum.Authority.BudgetGuard`.
  """
  @spec guard_invoke(Authority.t(), pid()) :: :ok
  def guard_invoke(%Authority{budget: %Budget{} = budget}, pid \\ self()),
    do: BudgetGuard.guard(budget, pid)

  @doc """
  Take over the guard on one charged slot from `from`, the process that
  holds it: the calling process then holds the slot, and releases it with
  `release_invoke/1` or by dying. `:released` means `from` no longer held
  it, so the caller holds nothing (`Sanctum.Authority.BudgetGuard.handover/3`).
  """
  @spec take_over_invoke(Authority.t(), pid()) :: :ok | :released
  def take_over_invoke(%Authority{budget: %Budget{} = budget}, from) when is_pid(from),
    do: BudgetGuard.handover(budget, from, self())

  @spec release_invoke(Authority.t()) :: :ok
  def release_invoke(%Authority{budget: %Budget{} = budget}),
    do: BudgetGuard.release(budget, self())

  @spec budget(Authority.t()) :: %{in_flight: non_neg_integer(), cap: non_neg_integer()}
  def budget(%Authority{budget: %Budget{} = budget}), do: BudgetCounter.snapshot(budget)
end
