# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Overlay.UnitLock do
  @moduledoc """
  Serializes writes to one unit, one unit at a time.

  Every mutating callback on `Arca.Overlay` takes this — `put`, `append`,
  `delete`, `delete_tree` — not only whole-unit replacement. The
  replacement case below is why it exists; the rest are why it is on the
  callbacks rather than on `commit_unit/4` alone.

  `Arca.Overlay.commit_unit/4` replaces a unit wholesale: it clears what is
  there, writes the new content, and lands the sentinel last. Two of those
  running against the same unit interleave, and the second one's clearing
  step deletes the first one's files.

  The sharp case is copy-on-write materialization, because nobody asked for
  it. Two writers touch a seed-backed unit the athanor has not materialized
  yet; both see it incomplete, both materialize, and the second one's clear
  removes the file the first writer had already been told was written. The
  caller had its `:ok`. The bytes are gone.

  A sentinel cannot close that window: it marks the end of a commit, and the
  damage happens at the start of the next one. What is needed is that the
  two commits do not overlap at all.

  So this is a mutex, not a single-flight — both commits are real writes and
  both must happen, in some order. Callers do their own work in their own
  process (storage I/O, the Ecto sandbox owner, the internal-writes process
  flag and Logger metadata all stay where they belong); this process only
  hands out the turn. Acquire and release are map operations, so the
  coordinator never sits in front of the I/O it is ordering.

  Node-local, like `Sanctum.OAuth.RefreshLock` and for the same reason:
  there is no clustering to be had (no distribution config, SQLite by
  default, bare-name singletons). A key is a storage path, so a
  deployment-wide version would only need a different holder.

  **Single-writer-node is therefore an invariant of overlaid storage**, not
  a convenience: `Arca.CronSchedule.claim/3` lets several nodes share one
  Postgres and race for schedules, but nothing serializes `commit_unit`
  across nodes — node B's clean-slate can delete files node A already
  acknowledged. Until this lock has a shared holder (a Postgres advisory
  lock is the natural one), a multi-node deployment must keep component
  writes — registration, pulls, builds — on one node.
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

  Returns whatever `fun` returns, or `{:error, :unit_locked}` if the wait
  times out. The lock is released when `fun` returns and when the caller
  dies, so a crash mid-commit cannot strand it.
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
