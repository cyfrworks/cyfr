# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Overlay.UnitLock do
  @moduledoc """
  Serializes writes to one unit, one unit at a time.

  Every mutating overlay callback takes the unit lock, including put,
  append, delete, and delete_tree.

  `Arca.Overlay.commit_unit/4` clears a unit, writes its contents, then
  writes its sentinel. Commits to the same unit must be serialized.

  The lock also serializes copy-on-write materialization with the write
  that triggered it, preserving successful writes by concurrent callers.

  Callers perform storage work in their own processes while holding
  the mutex. The coordinator only grants and releases locks.

  Locks are node-local and keyed by storage path; they do not coordinate
  writes from separate server processes.

  Shared overlaid storage requires one writer node for registration,
  pulls, builds, and other component mutations.
  """

  use GenServer

  require Logger

  @default_timeout_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Run `fun` with the lock on `key` held, waiting for it if another process
  holds it.

  Returns the result of `fun`, or `{:error, :unit_locked}` on timeout.
  Releases the lock when the function finishes, the caller dies, or
  a timed-out caller abandons a grant.
  """
  @spec with_lock(term(), (-> result), non_neg_integer()) :: result | {:error, :unit_locked}
        when result: term()
  def with_lock(key, fun, timeout_ms \\ @default_timeout_ms) do
    case acquire(key, timeout_ms) do
      :ok ->
        try do
          fun.()
        after
          GenServer.cast(__MODULE__, {:release, key, self()})
        end

      {:error, :unit_locked} = error ->
        Logger.warning("[Arca.Overlay.UnitLock] timed out waiting for #{inspect(key)}")
        error
    end
  end

  defp acquire(key, timeout_ms) do
    GenServer.call(__MODULE__, {:acquire, key}, timeout_ms)
  catch
    # A caller that gives up must not leave a grant waiting for it: the
    # server may hand the turn over at the same moment this call times out,
    # so tell it to drop us either way.
    :exit, _reason ->
      GenServer.cast(__MODULE__, {:abandon, key, self()})
      {:error, :unit_locked}
  end

  # ============================================================================
  # GenServer
  # ============================================================================

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:acquire, key}, {pid, _tag} = from, state) do
    case state[key] do
      nil ->
        {:reply, :ok, Map.put(state, key, {pid, Process.monitor(pid), :queue.new()})}

      {holder, ref, waiters} ->
        # The lock is not reentrant: a holder re-acquiring its own key can
        # only queue behind itself for the full timeout. Loud, because the
        # symptom (a 30s stall then :unit_locked) does not name the cause.
        if holder == pid do
          Logger.error(
            "[Arca.Overlay.UnitLock] #{inspect(pid)} re-acquiring #{inspect(key)} it " <>
              "already holds — the lock is not reentrant; this call can only time out"
          )
        end

        {:noreply, Map.put(state, key, {holder, ref, :queue.in(from, waiters)})}
    end
  end

  @impl true
  def handle_cast({:release, key, pid}, state) do
    case state[key] do
      {^pid, ref, waiters} ->
        Process.demonitor(ref, [:flush])
        {:noreply, hand_over(state, key, waiters)}

      _ ->
        # Not the holder — a late release after a monitor already reclaimed
        # the turn. Nothing to do.
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:abandon, key, pid}, state) do
    case state[key] do
      # The caller may time out after hand-over installs it as holder.
      # Release that abandoned grant as well as removing queued waiters.
      {^pid, ref, waiters} ->
        Process.demonitor(ref, [:flush])
        {:noreply, hand_over(state, key, waiters)}

      {holder, ref, waiters} ->
        kept = :queue.filter(fn {waiter, _tag} -> waiter != pid end, waiters)
        {:noreply, Map.put(state, key, {holder, ref, kept})}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Enum.find(state, fn {_key, {holder, held_ref, _}} ->
           holder == pid and held_ref == ref
         end) do
      {key, {_holder, _ref, waiters}} -> {:noreply, hand_over(state, key, waiters)}
      nil -> {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  # Give the turn to the next waiter that is still alive; drop the key when
  # nobody is left, so the map does not grow with every unit ever written.
  defp hand_over(state, key, waiters) do
    case :queue.out(waiters) do
      {{:value, {pid, _tag} = from}, rest} ->
        if Process.alive?(pid) do
          GenServer.reply(from, :ok)
          Map.put(state, key, {pid, Process.monitor(pid), rest})
        else
          hand_over(state, key, rest)
        end

      {:empty, _} ->
        Map.delete(state, key)
    end
  end
end
