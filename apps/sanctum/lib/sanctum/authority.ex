# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority do
  @moduledoc """
  The live half of `Prima.Authority`: what an authority does against this
  node's running state rather than as data.

    * `step/3` is `Prima.Authority.Transition.step/3` with the root budget
      charged. Every `spawn` outcome that starts work — a bound child, a
      zero child, or an allowed tool dispatch — takes one slot of the
      root-keyed invoke budget at this single chokepoint; exhaustion turns
      the outcome into `{:deny, :invoke_budget_exhausted}`. A denied or
      malformed spawn consumes nothing, and synchronous `call` is bounded
      by the depth cap instead: it adds no concurrency, the parent blocks.
      The caller releases the slot via `release_invoke/1` when the spawned
      work completes.
    * The invoke-budget counter (`Sanctum.Authority.BudgetCounter`) behind
      the budget id: `try_acquire_invoke/1`, `guard_invoke/1`,
      `take_over_invoke/2` and `release_invoke/1`. The id names the root's
      reservation row (`Arca.BudgetReservations`), which is the authority
      on what is in flight; the counter on this node is a pre-check.
  """

  alias Prima.Authority
  alias Prima.Authority.Budget
  alias Prima.Authority.Transition
  alias Sanctum.Authority.BudgetCounter
  alias Sanctum.Authority.BudgetGuard

  # ============================================================================
  # Charged transition
  # ============================================================================

  @doc """
  Apply one guest function to a target under an Authority, charging the
  root budget for every `spawn` that starts work.

  The decision is `Prima.Authority.Transition.step/3`'s; a caller that
  dispatches the outcome as spawned work steps through here so no handler
  can forget the charge and no deny path needs a rollback.

  With `:guarded`, a spawn's slot is taken and its holder guarded, the
  calling process, in one call of the guard (`guarded_acquire_invoke/1`),
  so a holder stopped at any point after leaves no slot behind; the
  holder releases it with `release_invoke/1`. Without, the caller guards
  the slot itself once it holds it (`guard_invoke/1`).
  """
  @spec step(Authority.t(), Transition.guest_fn(), Transition.target(), :guarded | :unguarded) ::
          Transition.outcome()
  def step(%Authority{} = auth, guest_fn, target, hold \\ :unguarded) do
    auth
    |> Transition.step(guest_fn, target)
    |> charge_spawn_budget(auth, guest_fn, hold)
  end

  defp charge_spawn_budget(outcome, auth, :spawn, hold)
       when elem(outcome, 0) in [:child, :child_zero, :allow_tool] do
    acquired =
      if hold == :guarded, do: guarded_acquire_invoke(auth), else: try_acquire_invoke(auth)

    case acquired do
      :ok -> outcome
      {:error, :invoke_budget_exhausted} -> {:deny, :invoke_budget_exhausted}
    end
  end

  defp charge_spawn_budget(outcome, _auth, _fun, _hold), do: outcome

  # ============================================================================
  # Root budget
  # ============================================================================

  @doc """
  Take one root-keyed invoke-budget slot. Every acquire must be paired with
  `release_invoke/1` when the spawned work completes — and the process
  doing the work registers itself with `guard_invoke/1` so a slot whose
  holder is brutally killed (the cancel and await-timeout paths) is
  released by the guard's `:DOWN` compensation instead of leaking.
  """
  @spec try_acquire_invoke(Authority.t()) :: :ok | {:error, :invoke_budget_exhausted}
  def try_acquire_invoke(%Authority{budget: %Budget{} = budget}),
    do: BudgetCounter.try_acquire(budget)

  @doc """
  Take one root-keyed invoke-budget slot held by the calling process,
  guarded in the same call (`Sanctum.Authority.BudgetGuard.acquire/2`):
  no instant exists at which the slot is taken and its holder's death
  would not give it back.
  """
  @spec guarded_acquire_invoke(Authority.t()) :: :ok | {:error, :invoke_budget_exhausted}
  def guarded_acquire_invoke(%Authority{budget: %Budget{} = budget}),
    do: BudgetGuard.acquire(budget, self())

  @doc """
  Register the calling process as the holder of one charged slot — see
  `Sanctum.Authority.BudgetGuard`.
  """
  @spec guard_invoke(Authority.t()) :: :ok
  def guard_invoke(%Authority{budget: %Budget{} = budget}),
    do: BudgetGuard.guard(budget, self())

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

  @doc """
  Give back the charge row `charge_id` of the authority's reservation, in
  `actor`'s athanor (`Arca.BudgetReservations.release/3`), idempotently:
  what a charged call's own end gives back (`Sanctum.Dispatch`), and what
  the caller that stopped a call with no effect to finish gives back for
  it, a call that waits (`waits: true`), whose worker's own release a stop
  skips. A call that does work is never given back for: its row stands
  until its window passes or its attempt ends, so a row reclaimed is
  never one whose handler can still act. The slot is the guard's to
  return (`release_invoke/1`, or its holder's death).
  """
  @spec release_charge(Prima.Actor.t(), Authority.t(), String.t()) :: :ok
  def release_charge(%Prima.Actor{} = actor, %Authority{budget: %Budget{id: id}}, charge_id)
      when is_binary(charge_id) do
    _ = Arca.BudgetReservations.release(actor, id, charge_id)
    :ok
  end
end
