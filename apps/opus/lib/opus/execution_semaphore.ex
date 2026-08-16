# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ExecutionSemaphore do
  @moduledoc """
  Counting semaphore that limits concurrent WASM executions.

  Acts as a **memory/resource guard** — each WASM instance consumes ~2-5MB
  of RSS (demand-paged linear memory), so the semaphore prevents total
  memory consumption from exceeding safe limits. WASM execution itself
  runs on Wasmtime's Tokio thread pool and does not block BEAM schedulers.

  ## Classes

  Every acquisition names what it is:

  - `:root` — a turn someone is waiting on: a chat message, an
    `execution.run`, a tincture invoke.
  - `:child` — a hop a running formula makes under its parent's authority.
    A parent holds its slot while it waits on the child, so a child that
    could not get one would deadlock the chain; children therefore take
    any free slot, are never counted against the tenant, and a quarter of
    the slots (`child_reserve`) is theirs alone — roots and background
    work stop at `max - child_reserve`.
  - `:background` — a schedule firing, a webhook — nobody is watching, so
    it waits (per athanor, bounded) rather than being refused, and it is
    served after roots.

  Hand-off order on a release: child, then root, then background.

  ## Per-athanor cap

  An athanor is limited to `:max_concurrent_executions_per_tenant` root
  slots (children run under a root's cap; background waits). A root at the
  cap is **rejected** with `{:error, :tenant_limit}` rather than queued —
  the person is waiting, and queuing per athanor would let one athanor's
  backlog interleave with everyone's queue. This bounds the blast radius
  of one athanor submitting many long-running (or non-preemptable
  tight-loop) executions: it can exhaust its own slots, never the node's.

  ## Configuration

      config :cyfr, :max_concurrent_executions, 128
      config :cyfr, :max_concurrent_executions_per_tenant, 16

  Defaults to 128 global slots and 16 per athanor. Can also be set via the
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
  @classes [:root, :child, :background]

  @type class :: :root | :child | :background

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

  @doc "The slots kept for children out of `max`."
  @spec child_reserve(pos_integer()) :: non_neg_integer()
  def child_reserve(max) when is_integer(max), do: div(max, 4)

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
    times out before a slot is available, the reply is `{:error, :queue_full}`.
  - `class` - `:root` (default), `:child` or `:background` — see the
    moduledoc.
  - `tenant` - The caller's tenant key (the athanor id). `nil`
    skips per-tenant accounting (used by internal/test callers).

  Returns `{:error, :queue_full}` if the wait queue itself is at capacity,
  or `{:error, :tenant_limit}` if a root's athanor is at its cap.
  """
  @spec acquire(timeout(), class(), term() | nil) ::
          :ok | {:error, :queue_full} | {:error, :tenant_limit}
  def acquire(timeout \\ 30_000, class \\ :root, tenant \\ nil) when class in @classes do
    try do
      GenServer.call(__MODULE__, {:acquire, class, tenant}, timeout)
    catch
      :exit, {:timeout, _} ->
        # The caller is giving up but its waiter entry (and monitor) live on
        # in the server — without this, a later hand-off could grant a slot
        # to a process that already returned and will never release it.
        GenServer.cast(__MODULE__, {:abandon_wait, self()})
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
        root_active: 2, child_active: 1, background_active: 0,
        child_reserve: 32, queued_by_class: %{root: 0, child: 0, background: 0},
        tenant_max: 16, tenants: %{"ath_…" => 2}}
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
  @spec force_release_all() :: :ok | {:error, :semaphore_unavailable}
  def force_release_all do
    try do
      GenServer.call(__MODULE__, :force_release_all)
    catch
      # A dead semaphore has nothing to release — but reporting :ok would
      # tell the operator a recovery happened when it didn't.
      :exit, _reason -> {:error, :semaphore_unavailable}
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
      "[Opus.ExecutionSemaphore] Started with max_concurrent_executions=#{max}, " <>
        "per_tenant=#{tenant_max}, child_reserve=#{child_reserve(max)}"
    )

    schedule_sweep()

    {:ok,
     %{
       max: max,
       tenant_max: tenant_max,
       child_reserve: child_reserve(max),
       count: 0,
       # holder pid => {monitor, acquired_at, tenant, class}
       monitors: %{},
       # roots held per tenant (the per-athanor cap)
       tenant_roots: %{},
       waiters: %{root: :queue.new(), child: :queue.new(), background: :queue.new()},
       # waiter pid => {from, monitor, class, tenant}
       waiter_monitors: %{},
       # background waiters per tenant (its own bound)
       background_waiters: %{},
       max_waiters: max * 4
     }}
  end

  @impl true
  def handle_call({:acquire, class, tenant}, {caller_pid, _tag} = from, state)
      when class in @classes do
    cond do
      class == :child ->
        if state.count < state.max,
          do: {:reply, :ok, grant(state, caller_pid, tenant, :child)},
          else: enqueue_waiter(state, from, :child, tenant)

      class == :root and tenant_at_cap?(state, tenant) ->
        Logger.warning(
          "[Opus.ExecutionSemaphore] Tenant #{inspect(tenant)} at per-tenant cap " <>
            "(#{state.tenant_max}), rejecting"
        )

        {:reply, {:error, :tenant_limit}, state}

      foreground_slot_free?(state) and not tenant_at_cap?(state, tenant) ->
        {:reply, :ok, grant(state, caller_pid, tenant, class)}

      true ->
        enqueue_waiter(state, from, class, tenant)
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    now = System.monotonic_time(:millisecond)

    holders =
      Enum.map(state.monitors, fn {pid, {_ref, acquired_at, _tenant, class}} ->
        %{
          pid: inspect(pid),
          alive: Process.alive?(pid),
          held_ms: now - acquired_at,
          class: class
        }
      end)

    by_class = Enum.frequencies_by(state.monitors, fn {_pid, {_r, _at, _t, class}} -> class end)

    reply = %{
      max: state.max,
      active: state.count,
      available: max(state.max - state.count, 0),
      child_reserve: state.child_reserve,
      root_active: Map.get(by_class, :root, 0),
      child_active: Map.get(by_class, :child, 0),
      background_active: Map.get(by_class, :background, 0),
      queued: total_waiter_count(state),
      queued_by_class: %{
        root: :queue.len(state.waiters.root),
        child: :queue.len(state.waiters.child),
        background: :queue.len(state.waiters.background)
      },
      holders: holders,
      tenant_max: state.tenant_max,
      tenants: state.tenant_roots
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:force_release_all, _from, state) do
    holder_count = map_size(state.monitors)
    waiter_count = total_waiter_count(state)

    if holder_count > 0 or waiter_count > 0 do
      Logger.warning(
        "[Opus.ExecutionSemaphore] Force-releasing #{holder_count} held slot(s) and " <>
          "#{waiter_count} queued waiter(s)"
      )

      Enum.each(state.monitors, fn {_pid, {mon_ref, _at, _tenant, _class}} ->
        Process.demonitor(mon_ref, [:flush])
      end)

      Enum.each(state.waiter_monitors, fn {_pid, {_from, mon_ref, _class, _tenant}} ->
        Process.demonitor(mon_ref, [:flush])
      end)
    end

    {:reply, :ok,
     %{
       state
       | count: 0,
         monitors: %{},
         tenant_roots: %{},
         waiters: %{root: :queue.new(), child: :queue.new(), background: :queue.new()},
         waiter_monitors: %{},
         background_waiters: %{}
     }}
  end

  @impl true
  def handle_cast({:release, pid}, state) do
    {:noreply, do_release(state, pid)}
  end

  # A caller that timed out of `acquire/3` dequeues itself. If the hand-off
  # already won the race and made it a holder, release that slot — the :ok
  # reply went to a caller that is no longer waiting for it.
  @impl true
  def handle_cast({:abandon_wait, pid}, state) do
    case Map.get(state.waiter_monitors, pid) do
      nil ->
        if Map.has_key?(state.monitors, pid) do
          {:noreply, do_release(state, pid)}
        else
          {:noreply, state}
        end

      {_from, mon_ref, _class, _tenant} ->
        Process.demonitor(mon_ref, [:flush])
        {:noreply, remove_waiter(state, pid)}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Process could be a holder or a queued waiter
    case Map.get(state.waiter_monitors, pid) do
      nil ->
        {:noreply, do_release(state, pid)}

      {_from, mon_ref, _class, _tenant} ->
        Process.demonitor(mon_ref, [:flush])
        {:noreply, remove_waiter(state, pid)}
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
        "[Opus.ExecutionSemaphore] Terminating with #{holder_count} holder(s) and " <>
          "#{waiter_count} waiter(s)"
      )
    end

    Enum.each(state.monitors, fn {_pid, {mon_ref, _at, _tenant, _class}} ->
      Process.demonitor(mon_ref, [:flush])
    end)

    Enum.each(state.waiter_monitors, fn {_pid, {_from, mon_ref, _class, _tenant}} ->
      Process.demonitor(mon_ref, [:flush])
    end)

    :ok
  end

  # ============================================================================
  # Private
  # ============================================================================

  # Roots and background work stop short of the child reserve.
  defp foreground_slot_free?(state), do: state.count < state.max - state.child_reserve

  defp grant(state, pid, tenant, class) do
    mon_ref = Process.monitor(pid)
    acquired_at = System.monotonic_time(:millisecond)
    new_count = state.count + 1

    Logger.debug(
      "[Opus.ExecutionSemaphore] Acquired #{class} slot for #{inspect(pid)} " <>
        "(#{new_count}/#{state.max})"
    )

    %{
      state
      | count: new_count,
        monitors: Map.put(state.monitors, pid, {mon_ref, acquired_at, tenant, class})
    }
    |> inc_tenant(tenant, class)
  end

  # A slot handed to a waiter: the count stays, the holder changes.
  defp transfer(state, from, waiter_mon_ref, tenant, class) do
    {waiter_pid, _tag} = from
    acquired_at = System.monotonic_time(:millisecond)
    GenServer.reply(from, :ok)

    Logger.debug(
      "[Opus.ExecutionSemaphore] Transferred slot to queued #{class} #{inspect(waiter_pid)} " <>
        "(#{state.count}/#{state.max})"
    )

    %{
      state
      | monitors:
          Map.put(state.monitors, waiter_pid, {waiter_mon_ref, acquired_at, tenant, class})
    }
    |> inc_tenant(tenant, class)
  end

  defp enqueue_waiter(state, {caller_pid, _tag} = from, class, tenant) do
    waiter_count = total_waiter_count(state)

    cond do
      waiter_count >= state.max_waiters ->
        Logger.warning(
          "[Opus.ExecutionSemaphore] Queue full (#{waiter_count}/#{state.max_waiters}), rejecting"
        )

        {:reply, {:error, :queue_full}, state}

      class == :background and background_queue_full?(state, tenant) ->
        Logger.warning(
          "[Opus.ExecutionSemaphore] Background queue full for #{inspect(tenant)}, rejecting"
        )

        {:reply, {:error, :queue_full}, state}

      true ->
        mon_ref = Process.monitor(caller_pid)
        waiter = {from, mon_ref, class, tenant}

        state = %{
          state
          | waiters: Map.update!(state.waiters, class, &:queue.in(waiter, &1)),
            waiter_monitors: Map.put(state.waiter_monitors, caller_pid, waiter),
            background_waiters: bump_background(state.background_waiters, class, tenant, 1)
        }

        Logger.debug(
          "[Opus.ExecutionSemaphore] Queued #{inspect(caller_pid)} " <>
            "(class=#{class}, queue=#{waiter_count + 1})"
        )

        {:noreply, state}
    end
  end

  defp background_queue_full?(_state, nil), do: false

  defp background_queue_full?(state, tenant) do
    Map.get(state.background_waiters, tenant, 0) >= state.tenant_max * 4
  end

  defp bump_background(counts, :background, tenant, delta) when not is_nil(tenant) do
    case Map.get(counts, tenant, 0) + delta do
      n when n <= 0 -> Map.delete(counts, tenant)
      n -> Map.put(counts, tenant, n)
    end
  end

  defp bump_background(counts, _class, _tenant, _delta), do: counts

  defp remove_waiter(state, pid) do
    case Map.pop(state.waiter_monitors, pid) do
      {nil, _} ->
        state

      {{_from, _mon, class, tenant}, rest} ->
        filter_fn = fn {f, _m, _c, _t} -> elem(f, 0) != pid end

        %{
          state
          | waiters: Map.update!(state.waiters, class, &:queue.filter(filter_fn, &1)),
            waiter_monitors: rest,
            background_waiters: bump_background(state.background_waiters, class, tenant, -1)
        }
    end
  end

  defp do_release(%{monitors: monitors} = state, pid) do
    case Map.pop(monitors, pid) do
      {nil, _monitors} ->
        # Already released or unknown caller — no-op
        state

      {{mon_ref, _acquired_at, tenant, class}, new_monitors} ->
        Process.demonitor(mon_ref, [:flush])

        %{state | monitors: new_monitors}
        |> dec_tenant(tenant, class)
        |> hand_off_slot(pid)
    end
  end

  # Try to hand the freed slot to the next eligible waiter: a child first
  # (any slot is theirs), then a root, then background work. A queued root
  # whose athanor reached its cap since queuing is told `{:error,
  # :tenant_limit}` and skipped, so the per-athanor invariant holds across
  # transfers too; a background waiter in that position simply keeps
  # waiting. When nobody eligible waits, the slot is freed.
  defp hand_off_slot(state, released_pid) do
    # The slot being handed over is not counted while we decide: the count
    # still includes it, so "one fewer" is the level a foreground taker
    # would find.
    with :none <- next_child(state),
         :none <- next_root(state),
         :none <- next_background(state) do
      new_count = max(state.count - 1, 0)

      Logger.debug(
        "[Opus.ExecutionSemaphore] Released slot for #{inspect(released_pid)} " <>
          "(#{new_count}/#{state.max})"
      )

      %{state | count: new_count}
    else
      {:transferred, state} ->
        state

      {:retry, state} ->
        hand_off_slot(state, released_pid)
    end
  end

  defp next_child(state) do
    case :queue.out(state.waiters.child) do
      {{:value, {from, mon_ref, :child, tenant}}, rest} ->
        state = take_waiter(state, from, :child, tenant, rest)
        {:transferred, transfer(state, from, mon_ref, tenant, :child)}

      {:empty, _} ->
        :none
    end
  end

  defp next_root(state) do
    if state.count - 1 < state.max - state.child_reserve do
      case :queue.out(state.waiters.root) do
        {{:value, {from, mon_ref, :root, tenant}}, rest} ->
          state = take_waiter(state, from, :root, tenant, rest)

          if tenant_at_cap?(state, tenant) do
            Process.demonitor(mon_ref, [:flush])
            GenServer.reply(from, {:error, :tenant_limit})

            Logger.warning(
              "[Opus.ExecutionSemaphore] Skipping queued #{inspect(elem(from, 0))}: " <>
                "tenant #{inspect(tenant)} at per-tenant cap"
            )

            {:retry, state}
          else
            {:transferred, transfer(state, from, mon_ref, tenant, :root)}
          end

        {:empty, _} ->
          :none
      end
    else
      :none
    end
  end

  # The first background waiter whose athanor is under its cap; the ones at
  # cap stay queued in order.
  defp next_background(state) do
    if state.count - 1 < state.max - state.child_reserve do
      list = :queue.to_list(state.waiters.background)

      case Enum.split_while(list, fn {_f, _m, _c, tenant} -> tenant_at_cap?(state, tenant) end) do
        {_blocked, []} ->
          :none

        {blocked, [{from, mon_ref, :background, tenant} = _taken | after_taken]} ->
          rest = :queue.from_list(blocked ++ after_taken)
          state = take_waiter(state, from, :background, tenant, rest)
          {:transferred, transfer(state, from, mon_ref, tenant, :background)}
      end
    else
      :none
    end
  end

  defp take_waiter(state, {waiter_pid, _}, class, tenant, remaining_queue) do
    %{
      state
      | waiters: Map.put(state.waiters, class, remaining_queue),
        waiter_monitors: Map.delete(state.waiter_monitors, waiter_pid),
        background_waiters: bump_background(state.background_waiters, class, tenant, -1)
    }
  end

  defp tenant_at_cap?(_state, nil), do: false

  defp tenant_at_cap?(state, tenant) do
    Map.get(state.tenant_roots, tenant, 0) >= state.tenant_max
  end

  # Only roots and background work count against the athanor; children run
  # inside a root's allowance.
  defp inc_tenant(state, nil, _class), do: state
  defp inc_tenant(state, _tenant, :child), do: state

  defp inc_tenant(state, tenant, _class) do
    %{state | tenant_roots: Map.update(state.tenant_roots, tenant, 1, &(&1 + 1))}
  end

  defp dec_tenant(state, nil, _class), do: state
  defp dec_tenant(state, _tenant, :child), do: state

  defp dec_tenant(state, tenant, _class) do
    new_counts =
      case Map.get(state.tenant_roots, tenant, 0) do
        n when n <= 1 -> Map.delete(state.tenant_roots, tenant)
        n -> Map.put(state.tenant_roots, tenant, n - 1)
      end

    %{state | tenant_roots: new_counts}
  end

  defp total_waiter_count(state) do
    :queue.len(state.waiters.root) + :queue.len(state.waiters.child) +
      :queue.len(state.waiters.background)
  end

  defp sweep_stale_holders(%{monitors: monitors} = state) when map_size(monitors) == 0, do: state

  defp sweep_stale_holders(state) do
    now = System.monotonic_time(:millisecond)

    stale_pids =
      Enum.filter(state.monitors, fn {_pid, {_ref, acquired_at, _tenant, _class}} ->
        now - acquired_at > @max_hold_ms
      end)
      |> Enum.map(fn {pid, _} -> pid end)

    if stale_pids != [] do
      Logger.warning(
        "[Opus.ExecutionSemaphore] Sweeping #{length(stale_pids)} stale slot(s) held " <>
          ">#{div(@max_hold_ms, 60_000)}min: #{inspect(stale_pids)}"
      )
    end

    Enum.reduce(stale_pids, state, fn pid, acc -> do_release(acc, pid) end)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep_stale, @sweep_interval_ms)
  end
end
