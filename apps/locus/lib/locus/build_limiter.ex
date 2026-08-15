# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.BuildLimiter do
  @moduledoc """
  Fixed cap on concurrent toolchain builds.

  A `cargo component build` or npm bundle occupies a CPU core and hundreds
  of MB for minutes; nothing else bounds how many a node accepts at once.
  A caller past the cap is rejected, not queued — mirroring
  `Opus.ExecutionSemaphore`'s per-tenant posture: a backlog of
  multi-minute builds behind a synchronous tool call helps nobody.

  Slots are held by the acquiring process and released three ways, in
  order of preference: the caller's own `release/0` (the `after` fast
  path), a `:DOWN` from the monitor when the holder dies without reaching
  its `after` (the MCP tool layer brutal-kills its provider task on its
  5-minute deadline, an SSE disconnect exits it with `:cancelled`, and a
  crash in the builder's linked inner task propagates the same way —
  none of those run `after`), and a periodic sweep that reclaims slots
  from live-but-wedged holders. Without the monitor, two killed builds
  permanently exhausted the cap until the application restarted.

  A holder may acquire more than once (slots are refcounted per pid);
  its `:DOWN` releases everything it held. Locus is a library app with
  no process tree, so `Cyfr.Application` supervises this server — if it
  is not running, `acquire/0` fails closed with `{:error, :busy}` rather
  than admitting unbounded builds.
  """

  use GenServer

  require Logger

  @default_max 2
  @sweep_interval_ms 30_000
  # Well past the builder's own compile deadline and the tool layer's
  # 5-minute kill: a live holder this old is wedged, not working.
  @max_hold_ms 10 * 60 * 1000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Take a build slot. `{:error, :busy}` past the cap — callers surface a
  retryable message rather than queueing. Also `{:error, :busy}` when the
  limiter is not running: an unaccounted build is worse than a refused one.
  """
  @spec acquire() :: :ok | {:error, :busy}
  def acquire(server \\ __MODULE__) do
    GenServer.call(server, :acquire)
  catch
    :exit, _ -> {:error, :busy}
  end

  @doc """
  Return a slot. Callers pair this with `acquire/0` in an `after`; a holder
  that dies before reaching it is released by its monitor instead.
  """
  @spec release() :: :ok
  def release(server \\ __MODULE__) do
    GenServer.cast(server, {:release, self()})
  catch
    :exit, _ -> :ok
  end

  @doc "The configured cap (`:cyfr, :max_concurrent_builds`, default #{@default_max})."
  def max_builds, do: Application.get_env(:cyfr, :max_concurrent_builds, @default_max)

  # ---------------------------------------------------------------------------
  # Server — state: %{holders: %{pid => {monitor_ref, count, since_ms}}, in_use: n}
  # ---------------------------------------------------------------------------

  @impl true
  def init(:ok) do
    schedule_sweep()
    {:ok, %{holders: %{}, in_use: 0}}
  end

  @impl true
  def handle_call(:acquire, {pid, _tag}, state) do
    if state.in_use >= max_builds() do
      {:reply, {:error, :busy}, state}
    else
      holders =
        Map.update(
          state.holders,
          pid,
          {Process.monitor(pid), 1, System.monotonic_time(:millisecond)},
          fn {ref, count, since} -> {ref, count + 1, since} end
        )

      {:reply, :ok, %{state | holders: holders, in_use: state.in_use + 1}}
    end
  end

  @impl true
  def handle_cast({:release, pid}, state) do
    {:noreply, release_one(state, pid)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, drop_holder(state, pid)}
  end

  def handle_info(:sweep_stale, state) do
    now = System.monotonic_time(:millisecond)

    stale =
      for {pid, {_ref, _count, since}} <- state.holders, now - since > @max_hold_ms, do: pid

    if stale != [] do
      Logger.warning(
        "[Locus.BuildLimiter] Sweeping #{length(stale)} build slot holder(s) " <>
          "alive but held >#{div(@max_hold_ms, 60_000)}min: #{inspect(stale)}"
      )
    end

    state = Enum.reduce(stale, state, &drop_holder(&2, &1))
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("[Locus.BuildLimiter] unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Release a single slot: the holder's own release/0. A release without a
  # matching acquire (or after a sweep already reclaimed it) is a no-op —
  # never underflow the count.
  defp release_one(state, pid) do
    case Map.get(state.holders, pid) do
      nil ->
        state

      {ref, 1, _since} ->
        Process.demonitor(ref, [:flush])
        %{state | holders: Map.delete(state.holders, pid), in_use: state.in_use - 1}

      {ref, count, since} ->
        %{state | holders: Map.put(state.holders, pid, {ref, count - 1, since}), in_use: state.in_use - 1}
    end
  end

  # Release everything a holder held: its :DOWN, or the stale sweep.
  defp drop_holder(state, pid) do
    case Map.get(state.holders, pid) do
      nil ->
        state

      {ref, count, _since} ->
        Process.demonitor(ref, [:flush])
        %{state | holders: Map.delete(state.holders, pid), in_use: state.in_use - count}
    end
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep_stale, @sweep_interval_ms)
end
