# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ExecutionSemaphore do
  @moduledoc """
  Counting semaphore that limits concurrent WASM executions.

  Acts as a **memory/resource guard** — each WASM instance consumes ~2-5MB
  of RSS (demand-paged linear memory), so the semaphore prevents total
  memory consumption from exceeding safe limits. WASM execution itself
  runs on Wasmtime's Tokio thread pool and does not block BEAM schedulers.

  Callers that can't immediately acquire a slot are queued with deferred
  GenServer reply. High-priority callers (reagents, formulas) are served
  before normal-priority callers (catalysts) to prevent slow I/O-bound
  executions from starving fast pure-compute ones.

  Callers that crash are automatically released via process monitoring.

  ## Per-tenant cap

  In addition to the global cap, each tenant (keyed `{org_id, project_id}`)
  is limited to `:max_concurrent_executions_per_tenant` slots. A tenant at
  its cap is **rejected** with `{:error, :tenant_limit}` rather than queued —
  queuing per-tenant would let one tenant's backlog interleave with the
  global priority queue and starve others. This bounds the blast radius of
  a single tenant submitting many long-running (or non-preemptable
  tight-loop) executions: it can exhaust its own slots, never the node's.

  ## Configuration

      config :cyfr, :max_concurrent_executions, 128
      config :cyfr, :max_concurrent_executions_per_tenant, 16

  Defaults to 128 global slots and 16 per tenant. Can also be set via the
  `CYFR_MAX_CONCURRENT_EXECUTIONS` and
  `CYFR_MAX_CONCURRENT_EXECUTIONS_PER_TENANT` env vars.

  ## Staleness Sweeper

  A periodic sweep runs every 30 seconds, force-releasing any slots held
  longer than 10 minutes. This prevents leaked slots from permanently
  reducing capacity.
  """

  use GenServer

  require Logger

  @default_slots 128
  @default_tenant_slots 16
  @sweep_interval_ms 30_000
  @max_hold_ms 10 * 60 * 1000

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Default global execution slots. Single source for the fallback used both
  here and by the supervision tree's child spec.
  """
  def default_slots, do: @default_slots

  @doc """
  Default per-tenant execution slots. Single source for the fallback used both
  here and by the supervision tree's child spec.
  """
  def default_tenant_slots, do: @default_tenant_slots

  def start_link(opts) do
    max = Keyword.get(opts, :max, @default_slots)

    tenant_max =
      Keyword.get(
        opts,
        :tenant_max,
        Application.get_env(:cyfr, :max_concurrent_executions_per_tenant, @default_tenant_slots)
      )

    GenServer.start_link(__MODULE__, {max, tenant_max}, name: __MODULE__)
  end

  @doc """
  Acquire an execution slot, queuing if at capacity.

  Returns `:ok` when a slot is acquired. If the semaphore is full, the
  caller is queued and will receive a reply when a slot becomes available
  or the `timeout` expires.

  ## Options

  - `timeout` - Max time to wait in ms (default 30_000). If the caller
    times out before a slot is available, they exit with `{:timeout, _}`.
  - `priority` - `:high` (reagents, formulas) or `:normal` (catalysts, default).
    High-priority callers are served before normal-priority in the queue.
  - `tenant` - The caller's tenant key (`{org_id, project_id}`). `nil`
    skips per-tenant accounting (used by internal/test callers).

  Returns `{:error, :queue_full}` if the wait queue itself is at capacity,
  or `{:error, :tenant_limit}` if the tenant is at its per-tenant cap.
  """
  @spec acquire(timeout(), :high | :normal, term() | nil) ::
          :ok | {:error, :queue_full} | {:error, :tenant_limit}
  def acquire(timeout \\ 30_000, priority \\ :normal, tenant \\ nil) do
    try do
      GenServer.call(__MODULE__, {:acquire, priority, tenant}, timeout)
    catch
      :exit, {:timeout, _} ->
        {:error, :queue_full}

      :exit, _reason ->
        {:error, :queue_full}
    end
  end

  @doc """
  Release an execution slot. Must be called by the same process that acquired.
  """
  @spec release() :: :ok
  def release do
    GenServer.cast(__MODULE__, {:release, self()})
  end

  @doc """
  Returns the current semaphore status for diagnostics.

  ## Example

      %{max: 128, active: 3, available: 125, queued: 0, holders: [...],
        tenant_max: 16, tenants: %{{"local", "default"} => 3}}
  """
  @spec status() :: map()
  def status do
    try do
      GenServer.call(__MODULE__, :status)
    catch
      :exit, _reason ->
        %{max: 0, active: 0, available: 0, queued: 0, holders: [], error: :unavailable}
    end
  end

  @doc """
  Emergency recovery: force-release all held slots and clear the queue.
  """
  @spec force_release_all() :: :ok
  def force_release_all do
    try do
      GenServer.call(__MODULE__, :force_release_all)
    catch
      :exit, _reason -> :ok
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init({max, tenant_max})
      when is_integer(max) and max > 0 and is_integer(tenant_max) and tenant_max > 0 do
    Process.flag(:trap_exit, true)

    Logger.info(
      "[Opus.ExecutionSemaphore] Started with max_concurrent_executions=#{max}, per_tenant=#{tenant_max}"
    )

    schedule_sweep()

    {:ok,
     %{
       max: max,
       tenant_max: tenant_max,
       count: 0,
       tenant_counts: %{},
       monitors: %{},
       waiters_high: :queue.new(),
       waiters_normal: :queue.new(),
       waiter_monitors: %{},
       max_waiters: max * 4
     }}
  end

  @impl true
  def handle_call({:acquire, priority, tenant}, {caller_pid, _tag} = from, state) do
    cond do
      tenant_at_cap?(state, tenant) ->
        Logger.warning(
          "[Opus.ExecutionSemaphore] Tenant #{inspect(tenant)} at per-tenant cap (#{state.tenant_max}), rejecting"
        )

        {:reply, {:error, :tenant_limit}, state}

      state.count < state.max ->
        mon_ref = Process.monitor(caller_pid)
        acquired_at = System.monotonic_time(:millisecond)
        new_monitors = Map.put(state.monitors, caller_pid, {mon_ref, acquired_at, tenant})
        new_count = state.count + 1

        Logger.debug(
          "[Opus.ExecutionSemaphore] Acquired slot for #{inspect(caller_pid)} (#{new_count}/#{state.max})"
        )

        {:reply, :ok,
         %{state | count: new_count, monitors: new_monitors}
         |> inc_tenant(tenant)}

      true ->
        enqueue_waiter(state, from, priority, tenant)
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    now = System.monotonic_time(:millisecond)

    holders =
      Enum.map(state.monitors, fn {pid, {_ref, acquired_at, _tenant}} ->
        %{
          pid: inspect(pid),
          alive: Process.alive?(pid),
          held_ms: now - acquired_at
        }
      end)

    reply = %{
      max: state.max,
      active: state.count,
      available: max(state.max - state.count, 0),
      queued: total_waiter_count(state),
      holders: holders,
      tenant_max: state.tenant_max,
      tenants: state.tenant_counts
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:force_release_all, _from, state) do
    holder_count = map_size(state.monitors)
    waiter_count = total_waiter_count(state)

    if holder_count > 0 or waiter_count > 0 do
      Logger.warning(
        "[Opus.ExecutionSemaphore] Force-releasing #{holder_count} held slot(s) and #{waiter_count} queued waiter(s)"
      )

      Enum.each(state.monitors, fn {_pid, {mon_ref, _acquired_at, _tenant}} ->
        Process.demonitor(mon_ref, [:flush])
      end)

      Enum.each(state.waiter_monitors, fn {_pid, {_from, mon_ref, _priority, _tenant}} ->
        Process.demonitor(mon_ref, [:flush])
      end)
    end

    {:reply, :ok,
     %{
       state
       | count: 0,
         tenant_counts: %{},
         monitors: %{},
         waiters_high: :queue.new(),
         waiters_normal: :queue.new(),
         waiter_monitors: %{}
     }}
  end

  @impl true
  def handle_cast({:release, pid}, state) do
    {:noreply, do_release(state, pid)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Process could be a holder or a queued waiter
    case Map.get(state.waiter_monitors, pid) do
      nil ->
        # It's a holder — release the slot
        {:noreply, do_release(state, pid)}

      {_from, mon_ref, _priority, _tenant} ->
        # It's a queued waiter — remove from queue without affecting slot count
        Process.demonitor(mon_ref, [:flush])
        filter_fn = fn {f, _m, _p, _t} -> elem(f, 0) != pid end
        new_high = :queue.filter(filter_fn, state.waiters_high)
        new_normal = :queue.filter(filter_fn, state.waiters_normal)
        new_waiter_monitors = Map.delete(state.waiter_monitors, pid)

        {:noreply,
         %{
           state
           | waiters_high: new_high,
             waiters_normal: new_normal,
             waiter_monitors: new_waiter_monitors
         }}
    end
  end

  @impl true
  def handle_info(:sweep_stale, state) do
    state = sweep_stale_holders(state)
    schedule_sweep()
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("#{__MODULE__}: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    holder_count = map_size(state.monitors)
    waiter_count = total_waiter_count(state)

    if holder_count > 0 or waiter_count > 0 do
      Logger.info(
        "[Opus.ExecutionSemaphore] Terminating with #{holder_count} holder(s) and #{waiter_count} waiter(s)"
      )
    end

    # Demonitor all holders
    Enum.each(state.monitors, fn {_pid, {mon_ref, _acquired_at, _tenant}} ->
      Process.demonitor(mon_ref, [:flush])
    end)

    # Demonitor all waiters
    Enum.each(state.waiter_monitors, fn {_pid, {_from, mon_ref, _priority, _tenant}} ->
      Process.demonitor(mon_ref, [:flush])
    end)

    :ok
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp enqueue_waiter(state, {caller_pid, _tag} = from, priority, tenant) do
    waiter_count = total_waiter_count(state)

    if waiter_count >= state.max_waiters do
      Logger.warning(
        "[Opus.ExecutionSemaphore] Queue full (#{waiter_count}/#{state.max_waiters}), rejecting"
      )

      {:reply, {:error, :queue_full}, state}
    else
      mon_ref = Process.monitor(caller_pid)

      waiter = {from, mon_ref, priority, tenant}

      new_waiter_monitors =
        Map.put(state.waiter_monitors, caller_pid, {from, mon_ref, priority, tenant})

      state =
        case priority do
          :high ->
            %{
              state
              | waiters_high: :queue.in(waiter, state.waiters_high),
                waiter_monitors: new_waiter_monitors
            }

          _ ->
            %{
              state
              | waiters_normal: :queue.in(waiter, state.waiters_normal),
                waiter_monitors: new_waiter_monitors
            }
        end

      Logger.debug(
        "[Opus.ExecutionSemaphore] Queued #{inspect(caller_pid)} (priority=#{priority}, queue=#{waiter_count + 1})"
      )

      {:noreply, state}
    end
  end

  defp do_release(%{monitors: monitors} = state, pid) do
    case Map.pop(monitors, pid) do
      {nil, _monitors} ->
        # Already released or unknown caller — no-op
        state

      {{mon_ref, _acquired_at, tenant}, new_monitors} ->
        Process.demonitor(mon_ref, [:flush])

        %{state | monitors: new_monitors}
        |> dec_tenant(tenant)
        |> hand_off_slot(pid)
    end
  end

  # Try to hand the freed slot to the next eligible waiter (high priority
  # first). Waiters whose tenant has reached its cap since queuing are
  # rejected with {:error, :tenant_limit} and skipped, so the per-tenant
  # invariant holds across slot transfers too.
  defp hand_off_slot(state, released_pid) do
    case dequeue_next_waiter(state) do
      {{:value, {from, waiter_mon_ref, _priority, tenant}}, new_high, new_normal} ->
        {waiter_pid, _tag} = from

        state = %{
          state
          | waiters_high: new_high,
            waiters_normal: new_normal,
            waiter_monitors: Map.delete(state.waiter_monitors, waiter_pid)
        }

        if tenant_at_cap?(state, tenant) do
          Process.demonitor(waiter_mon_ref, [:flush])
          GenServer.reply(from, {:error, :tenant_limit})

          Logger.warning(
            "[Opus.ExecutionSemaphore] Skipping queued #{inspect(waiter_pid)}: tenant #{inspect(tenant)} at per-tenant cap"
          )

          hand_off_slot(state, released_pid)
        else
          # Transfer: don't decrement count, just swap the holder
          acquired_at = System.monotonic_time(:millisecond)

          new_holder_monitors =
            Map.put(state.monitors, waiter_pid, {waiter_mon_ref, acquired_at, tenant})

          GenServer.reply(from, :ok)

          Logger.debug(
            "[Opus.ExecutionSemaphore] Transferred slot to queued #{inspect(waiter_pid)} (#{state.count}/#{state.max})"
          )

          %{state | monitors: new_holder_monitors}
          |> inc_tenant(tenant)
        end

      {:empty, _, _} ->
        new_count = max(state.count - 1, 0)

        Logger.debug(
          "[Opus.ExecutionSemaphore] Released slot for #{inspect(released_pid)} (#{new_count}/#{state.max})"
        )

        %{state | count: new_count}
    end
  end

  defp tenant_at_cap?(_state, nil), do: false

  defp tenant_at_cap?(state, tenant) do
    Map.get(state.tenant_counts, tenant, 0) >= state.tenant_max
  end

  defp inc_tenant(state, nil), do: state

  defp inc_tenant(state, tenant) do
    %{state | tenant_counts: Map.update(state.tenant_counts, tenant, 1, &(&1 + 1))}
  end

  defp dec_tenant(state, nil), do: state

  defp dec_tenant(state, tenant) do
    new_counts =
      case Map.get(state.tenant_counts, tenant, 0) do
        n when n <= 1 -> Map.delete(state.tenant_counts, tenant)
        n -> Map.put(state.tenant_counts, tenant, n - 1)
      end

    %{state | tenant_counts: new_counts}
  end

  # Dequeue from high-priority queue first, then normal.
  defp dequeue_next_waiter(state) do
    case :queue.out(state.waiters_high) do
      {{:value, _} = result, remaining_high} ->
        {result, remaining_high, state.waiters_normal}

      {:empty, _} ->
        case :queue.out(state.waiters_normal) do
          {{:value, _} = result, remaining_normal} ->
            {result, state.waiters_high, remaining_normal}

          {:empty, _} ->
            {:empty, state.waiters_high, state.waiters_normal}
        end
    end
  end

  defp total_waiter_count(state) do
    :queue.len(state.waiters_high) + :queue.len(state.waiters_normal)
  end

  defp sweep_stale_holders(%{monitors: monitors} = state) when map_size(monitors) == 0, do: state

  defp sweep_stale_holders(state) do
    now = System.monotonic_time(:millisecond)

    stale_pids =
      Enum.filter(state.monitors, fn {_pid, {_ref, acquired_at, _tenant}} ->
        now - acquired_at > @max_hold_ms
      end)
      |> Enum.map(fn {pid, _} -> pid end)

    if stale_pids != [] do
      Logger.warning(
        "[Opus.ExecutionSemaphore] Sweeping #{length(stale_pids)} stale slot(s) held >#{div(@max_hold_ms, 60_000)}min: #{inspect(stale_pids)}"
      )
    end

    Enum.reduce(stale_pids, state, fn pid, acc -> do_release(acc, pid) end)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep_stale, @sweep_interval_ms)
  end
end