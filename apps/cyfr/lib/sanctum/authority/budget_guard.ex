# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Authority.BudgetGuard do
  @moduledoc """
  Makes an invoke-budget slot survive its holder's death.

  A charged slot used to be released only by a `try/after` inside the
  holding task — and the runtime's cancel and await-timeout paths kill
  those tasks with an untrappable `:brutal_kill`, so the `after` never
  ran: the root's budget shrank permanently (one cancelled child could
  exhaust a ZeroAuthority root's whole budget) and the counter row could
  never return to zero, leaking one ETS row per affected root for the
  node's lifetime.

  This process owns both release paths instead. A holder registers itself
  after the charge (`guard/2`); the slot comes back either when the holder
  releases explicitly — which removes the guard — or when the holder dies
  (the `:DOWN` compensation). Exactly once, whichever comes first. The
  pattern is `Emissary.MCP.ExternalServer`'s in-flight monitor, applied
  to the budget.

  A release with no guard registered (a spawner's error arm, before the
  task existed) releases directly. If this process is *gone*, both verbs
  degrade to the old behaviour — the explicit release still runs, only the
  death compensation is lost — so the guard can never make the budget
  stricter than the charge, only tighter against leaks. A call that merely
  *times out* is a different case and is handled as such: see `release/2`.
  """

  use GenServer

  alias Sanctum.Authority.Budget

  # Explicit rather than inherited: every charge and release in the system
  # funnels through this one process, so its call timeout is a parameter of
  # the spawn hot path and belongs in view.
  @call_timeout_ms 5_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
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
  will release the slot. Releasing again here decremented the counter twice
  for one charge — freeing a concurrent sibling's slot and letting the root
  exceed the invoke cap it consented to. Under load is exactly when this
  call times out and exactly when the over-release matters.

  Any other exit means the call never landed (no such process, or the guard
  died before handling it), so the slot is released directly as the
  pre-guard code did and is never lost.
  """
  @spec release_after_exit(Budget.t(), term()) :: :ok
  def release_after_exit(%Budget{}, {:timeout, _}), do: :ok
  def release_after_exit(%Budget{} = budget, _reason), do: Budget.release(budget)

  @impl true
  def init(_opts) do
    # guards: {budget_id, pid} => {monitor_ref, budget}; refs: ref => key.
    {:ok, %{guards: %{}, refs: %{}}}
  end

  @impl true
  def handle_call({:guard, budget, pid}, _from, state) do
    key = {budget.id, pid}

    # Re-guarding the same holder replaces the old monitor rather than
    # stacking a second release.
    state =
      case Map.get(state.guards, key) do
        {old_ref, _} ->
          Process.demonitor(old_ref, [:flush])
          %{state | refs: Map.delete(state.refs, old_ref)}

        nil ->
          state
      end

    ref = Process.monitor(pid)

    {:reply, :ok,
     %{
       state
       | guards: Map.put(state.guards, key, {ref, budget}),
         refs: Map.put(state.refs, ref, key)
     }}
  end

  def handle_call({:release, budget, pid}, _from, state) do
    key = {budget.id, pid}

    case Map.pop(state.guards, key) do
      {nil, _} ->
        Budget.release(budget)
        {:reply, :ok, state}

      {{ref, guarded}, guards} ->
        Process.demonitor(ref, [:flush])
        Budget.release(guarded)
        {:reply, :ok, %{state | guards: guards, refs: Map.delete(state.refs, ref)}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {key, refs} ->
        {{^ref, budget}, guards} = Map.pop(state.guards, key)
        Budget.release(budget)
        {:noreply, %{state | guards: guards, refs: refs}}
    end
  end

  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end
end
