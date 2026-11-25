# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Authority.BudgetGuard do
  @moduledoc """
  Makes an invoke-budget slot survive its holder's death.

  It monitors slot holders, so cancellation or an untrappable task exit
  releases the root's budget even when the task cannot run cleanup.

  This process owns both release paths. A holder registers itself
  after the charge (`guard/2`); the slot comes back either when the holder
  releases explicitly — which removes the guard — or when the holder dies
  (the `:DOWN` compensation). Exactly once, whichever comes first. The
  pattern is `Emissary.External.Server`'s in-flight monitor, applied
  to the budget.

  Without a registered guard, release directly. If the guard process is
  unavailable, explicit releases still run but death monitoring is absent.
  A call timeout follows the separate handling in `release/2`.

  A slot taken for a call that waits (`waits: true`, `Prima.Operation`)
  is guarded with its charge's row (`acquire/3`): the holder's death
  gives the row back too, off this process, since such a call has no
  effect left to finish and its row has no window to pass. A give-back
  that fails is logged and leaves the row to its attempt's end
  (`Arca.BudgetReservations.sweep/1`). Any other call's row stands at its
  holder's death until its window passes, so a row reclaimed is never one
  whose handler can still act.
  """

  use GenServer

  require Logger

  alias Prima.Authority.Budget
  alias Sanctum.Authority.BudgetCounter

  @typedoc """
  A waiting call's charge row, given back at its holder's death: the
  actor whose athanor holds it, the reservation and the row's id.
  """
  @type charge :: {Prima.Actor.t(), String.t(), String.t()} | nil

  # Explicit rather than inherited: every charge and release in the system
  # funnels through this one process, so its call timeout is a parameter of
  # the spawn hot path and belongs in view.
  @call_timeout_ms 5_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register `pid` as the holder of one charged slot of `budget`. Call from
  the holding process right after it starts working; the slot is then
  released on the holder's death if it never releases explicitly.
  """
  @spec guard(Budget.t(), pid()) :: :ok
  def guard(%Budget{} = budget, pid \\ self()) do
    GenServer.call(__MODULE__, {:guard, budget, pid}, @call_timeout_ms)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Take one slot of `budget` for `pid` and guard it, in one call of this
  process (`Sanctum.Authority.BudgetCounter.try_acquire/1`, then the
  monitor): a holder that dies at any point after the call leaves no slot,
  and one that dies before it took none. With `charge`, a waiting call's
  row, the holder's death gives the row back too; a row not yet written
  then gives back nothing. `{:error, :invoke_budget_exhausted}` when no
  slot is free. A call that times out answers exhausted, its slot, if
  the call lands, given back at the holder's death; any other exit means
  the guard is gone, and the slot is taken unguarded, as `guard/2` leaves
  it.
  """
  @spec acquire(Budget.t(), pid(), charge()) :: :ok | {:error, :invoke_budget_exhausted}
  def acquire(%Budget{} = budget, pid, charge \\ nil) when is_pid(pid) do
    GenServer.call(__MODULE__, {:acquire, budget, pid, charge}, @call_timeout_ms)
  catch
    :exit, {:timeout, _} -> {:error, :invoke_budget_exhausted}
    :exit, _ -> BudgetCounter.try_acquire(budget)
  end

  @doc """
  Move the guard on one slot of `budget` from `from` to `to`, which then
  holds the slot: it is released when `to` releases it or dies. Answers
  `:ok` when the slot moved, and `:released` when `from` holds no guard on
  it — its holder released it, or died and the compensation released it —
  so `to` holds nothing.

  A call that times out answers `:released`: the move may still land, and
  a holder that released a slot it does not hold would free a sibling's.
  Any other exit means the call never landed and the guard's state is
  gone, so `to` holds the slot unguarded and releases it directly.
  """
  @spec handover(Budget.t(), pid(), pid()) :: :ok | :released
  def handover(%Budget{} = budget, from, to) when is_pid(from) and is_pid(to) do
    GenServer.call(__MODULE__, {:handover, budget, from, to}, @call_timeout_ms)
  catch
    :exit, {:timeout, _} -> :released
    :exit, _ -> :ok
  end

  @doc """
  Release one slot of `budget` held by `pid` — removing the guard so the
  death compensation cannot release it a second time. With no guard
  registered for `{budget, pid}`, releases directly.
  """
  @spec release(Budget.t(), pid()) :: :ok
  def release(%Budget{} = budget, pid \\ self()) do
    GenServer.call(__MODULE__, {:release, budget, pid}, @call_timeout_ms)
  catch
    :exit, reason -> release_after_exit(budget, reason)
  end

  @doc """
  What a failed `release/2` call means for the slot — the pure half, so the
  distinction is testable without staging a real timeout.

  A timeout is **not** a failed release: `GenServer.call` gives up on the
  reply, but the message is already in the guard's mailbox and `handle_call`
  releases the slot. Releasing again here would decrement the counter twice
  for one charge — freeing a concurrent sibling's slot and letting the root
  exceed the invoke cap it consented to. Under load is exactly when this
  call times out and exactly when the over-release matters.

  Any other exit means the call never landed (no such process, or the guard
  died before handling it), so the slot is released directly and is never
  lost.
  """
  @spec release_after_exit(Budget.t(), term()) :: :ok
  def release_after_exit(%Budget{}, {:timeout, _}), do: :ok
  def release_after_exit(%Budget{} = budget, _reason), do: BudgetCounter.release(budget)

  @impl true
  def init(_opts) do
    # guards: {budget_id, pid} => {monitor_ref, budget, charge};
    # refs: ref => key.
    {:ok, %{guards: %{}, refs: %{}}}
  end

  @impl true
  def handle_call({:guard, budget, pid}, _from, state) do
    {:reply, :ok, put_guard(state, budget, pid)}
  end

  def handle_call({:acquire, budget, pid, charge}, _from, state) do
    case BudgetCounter.try_acquire(budget) do
      :ok -> {:reply, :ok, put_guard(state, budget, pid, charge)}
      exhausted -> {:reply, exhausted, state}
    end
  end

  def handle_call({:handover, budget, from, to}, _from, state) do
    case Map.pop(state.guards, {budget.id, from}) do
      {nil, _} ->
        {:reply, :released, state}

      {{ref, guarded, charge}, guards} ->
        Process.demonitor(ref, [:flush])
        state = %{state | guards: guards, refs: Map.delete(state.refs, ref)}
        {:reply, :ok, put_guard(state, guarded, to, charge)}
    end
  end

  def handle_call({:release, budget, pid}, _from, state) do
    key = {budget.id, pid}

    case Map.pop(state.guards, key) do
      {nil, _} ->
        BudgetCounter.release(budget)
        {:reply, :ok, state}

      {{ref, guarded, _charge}, guards} ->
        Process.demonitor(ref, [:flush])
        BudgetCounter.release(guarded)
        {:reply, :ok, %{state | guards: guards, refs: Map.delete(state.refs, ref)}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {key, refs} ->
        {{^ref, budget, charge}, guards} = Map.pop(state.guards, key)
        BudgetCounter.release(budget)
        give_back(charge)
        {:noreply, %{state | guards: guards, refs: refs}}
    end
  end

  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  # A dead waiting holder's row, given back off this process: every charge
  # and release passes through it, and a store write has no place on that
  # path. Idempotent with the holder's own release, which a death after it
  # finds already made.
  defp give_back(nil), do: :ok

  defp give_back({actor, reservation_id, id}) do
    Task.Supervisor.start_child(Sanctum.TaskSupervisor, fn ->
      case released(actor, reservation_id, id) do
        :ok -> :ok
        failed -> not_given_back(failed)
      end
    end)
  catch
    :exit, reason -> not_given_back(reason)
  end

  defp released(actor, reservation_id, id) do
    Arca.BudgetReservations.release(actor, reservation_id, id)
  catch
    :exit, reason -> {:exit, reason}
  end

  defp not_given_back(reason) do
    Logger.warning(
      "[Sanctum.Authority.BudgetGuard] A dead holder's charge was not given back; " <>
        "its attempt's end reclaims it: #{Prima.LogFilter.inspect_reason(reason)}"
    )
  end

  # Re-guarding the same holder replaces the old monitor rather than
  # stacking a second release.
  defp put_guard(state, budget, pid, charge \\ nil) do
    key = {budget.id, pid}

    state =
      case Map.get(state.guards, key) do
        {old_ref, _, _} ->
          Process.demonitor(old_ref, [:flush])
          %{state | refs: Map.delete(state.refs, old_ref)}

        nil ->
          state
      end

    ref = Process.monitor(pid)

    %{
      state
      | guards: Map.put(state.guards, key, {ref, budget, charge}),
        refs: Map.put(state.refs, ref, key)
    }
  end
end
