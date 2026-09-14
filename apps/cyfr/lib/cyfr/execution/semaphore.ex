# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Semaphore do
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
  backlog interleave with everyone's queue. Background work counts against
  the same cap but stops at **half** of it: it waits rather than being
  refused, so a flock of same-minute schedules can never turn the next
  message in the chat into a refusal.

  The per-tenant limit counts roots; child executions are exempt to avoid
  waiting for a child slot while holding a root slot. A tenant can therefore
  occupy up to `per_tenant * depth_cap` slots. `init/1` warns if this can
  exhaust the global pool; lower the per-tenant cap or enlarge the pool.

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

  ## Unreaped kills

  Wasmex has no epoch interruption: a timeout kill may leave native work
  running after the BEAM-side slot is released. `note_unreaped/2` records
  these kills, and excessive recent kills refuse new root/background slots
  with `{:error, :tenant_unreaped_limit}`. Entries expire after
  #{div(10 * 60 * 1000, 60_000)} minutes; native completion is not observable,
  so expiry does not confirm that the work has stopped. Each noted kill
  emits `[:cyfr, :opus, :execution, :unreaped_kill]` with the tenant's
  live `unreaped_count` and the killed execution in the metadata.
  """

  use GenServer

  require Logger

  @default_slots 128
  @default_tenant_slots 16
  @sweep_interval_ms 30_000
  @max_hold_ms 10 * 60 * 1000
  # How long a noted unreaped kill counts against its tenant. Decay-based
  # because nothing observable fires when (if ever) the native thread stops.
  @unreaped_ttl_ms 10 * 60 * 1000
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

  @doc """
  The most slots one athanor can hold at once: each of its root slots may
  carry a chain down to the authority depth cap, and children are deliberately
  exempt from the per-tenant count (a chain must be able to finish, or it
  would block holding its own root slot).

  This is what the per-tenant cap actually bounds. With the shipped defaults —
  128 slots, 16 per tenant, depth cap 8 — it comes to 128, which is the whole
  node, so the per-tenant cap bounds a tenant's *roots* and not its footprint.
  """
  @spec max_tenant_footprint(pos_integer()) :: pos_integer()
  def max_tenant_footprint(tenant_max) when is_integer(tenant_max),
    do: tenant_max * Cyfr.Authority.depth_cap()

  # Said once, at boot, where an operator can act on it. Capping children per
  # tenant is not the fix: a chain that cannot get a child slot waits while
  # holding its root slot, which is a deadlock, not a limit. The lever is the
  # ratio — lower `per_tenant`, or raise the global pool.
  defp warn_if_one_tenant_can_fill_the_node(max, tenant_max) do
    footprint = max_tenant_footprint(tenant_max)

    if footprint >= max do
      Logger.warning(
        "[Cyfr.Execution.Semaphore] one athanor can hold every slot on this node: " <>
          "#{tenant_max} roots x depth #{Cyfr.Authority.depth_cap()} = #{footprint} >= " <>
          "#{max} slots. Children are exempt from the per-tenant cap by design (a chain " <>
          "must be able to finish), so the cap bounds roots, not footprint. Lower " <>
          "CYFR_MAX_CONCURRENT_EXECUTIONS_PER_TENANT or raise " <>
          "CYFR_MAX_CONCURRENT_EXECUTIONS to keep one tenant off the whole pool."
      )
    end

    :ok
  end

  def start_link(opts) do
    max = Keyword.get(opts, :max, @default_slots)

    tenant_max =
      Keyword.get(
        opts,
        :tenant_max,
        Application.get_env(:cyfr, :max_concurrent_executions_per_tenant, @default_tenant_slots)
      )

    # The ratio warning is about what an operator configured, so it is raised
    # only for the deployment's own semaphore. Tests start instances with
    # deliberately tiny pools where the condition is trivially true and the
    # advice is meaningless.
    configured? = not Keyword.has_key?(opts, :max)

    GenServer.start_link(__MODULE__, {max, tenant_max, configured?}, name: __MODULE__)
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
  `{:error, :tenant_limit}` if a root's athanor is at its cap, or
  `{:error, :tenant_unreaped_limit}` if the athanor has too many recent
  unreaped timeout kills (see the moduledoc).
  """
  @spec acquire(timeout(), class(), term() | nil) ::
          :ok
          | {:error, :queue_full}
          | {:error, :tenant_limit}
          | {:error, :tenant_unreaped_limit}
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
  Note that execution `execution_id` of `tenant`'s was killed with its
  native thread unreaped (see the moduledoc): a timeout, or a cancel.
  Synchronous, and charged to the tenant by name rather than looked up
  from the caller's slot: the caller need not be the holder (a cancel runs
  in the canceller's process), and the note is acknowledged before the
  kill it precedes, so no ordering between this and the holder's release —
  or its `:DOWN` — can lose it. A nil tenant charges nobody.
  `{:error, :unavailable}` means the semaphore did not answer and the kill
  goes uncharged; the caller records that by execution.
  """
  @spec note_unreaped(String.t() | nil, String.t() | nil) :: :ok | {:error, :unavailable}
  def note_unreaped(nil, _execution_id), do: :ok

  def note_unreaped(tenant, execution_id) when is_binary(tenant) do
    GenServer.call(__MODULE__, {:unreaped, tenant, execution_id})
  catch
    :exit, _ -> {:error, :unavailable}
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
      # Keep the same reply keys, including per-tenant counts, when unavailable.
      :exit, _reason ->
        %{
          max: 0,
          active: 0,
          available: 0,
          child_reserve: 0,
          root_active: 0,
          child_active: 0,
          background_active: 0,
          queued: 0,
          queued_by_class: %{root: 0, child: 0, background: 0},
          holders: [],
          tenant_max: 0,
          tenants: %{},
          unreaped: %{},
          error: :unavailable
        }
    end
  end

  @doc """
  Clear one athanor's unreaped-kill penalty: the operator has dealt with
  the spinning threads at the node level, and the athanor may run roots
  again before the window decays. A force-release does not do this.
  """
  @spec forgive_unreaped(String.t()) :: :ok | {:error, :semaphore_unavailable}
  def forgive_unreaped(tenant) when is_binary(tenant) do
    try do
      GenServer.call(__MODULE__, {:forgive_unreaped, tenant})
    catch
      :exit, _ -> {:error, :semaphore_unavailable}
    end
  end

  @doc """
  Emergency recovery: force-release all held slots and clear the queue.
  The unreaped-kill penalty box stays (`forgive_unreaped/1`).
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

  # A caller that names its own pool — `GenServer.start_link(__MODULE__,
  # {max, tenant_max})` — is stating the sizes deliberately, so the
  # operator-facing ratio warning does not apply to it.
  @impl true
  def init({max, tenant_max}), do: init({max, tenant_max, false})

  def init({max, tenant_max, configured?})
      when is_integer(max) and max > 0 and is_integer(tenant_max) and tenant_max > 0 do
    Process.flag(:trap_exit, true)

    Logger.info(
      "[Cyfr.Execution.Semaphore] Started with max_concurrent_executions=#{max}, " <>
        "per_tenant=#{tenant_max}, child_reserve=#{child_reserve(max)}"
    )

    if configured?, do: warn_if_one_tenant_can_fill_the_node(max, tenant_max)

    schedule_sweep()

    {:ok,
     %{
       max: max,
       tenant_max: tenant_max,
       child_reserve: child_reserve(max),
       count: 0,
       # holder pid => {monitor, [{acquired_at, tenant, class}]}, newest
       # holding first: one process can hold several slots (a synchronous
       # child running in its parent's process), each counted and released
       # on its own.
       monitors: %{},
       # roots held per tenant (the per-athanor cap)
       tenant_roots: %{},
       # tenant => [expiry_ms] — one entry per recent unreaped timeout kill
       tenant_unreaped: %{},
       # refusal threshold: half the tenant cap, never below 2 — a couple
       # of benign timeouts must not trip it, half a cap of spinning cores
       # must
       unreaped_max: max(2, div(tenant_max, 2)),
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

      # Background work counts against the athanor's cap, so a flock of
      # same-minute schedules could fill it and turn the next chat turn into
      # a refusal. It stops at half: what is left is for whoever is waiting
      # at the glass.
      class == :background and tenant_at_background_cap?(state, tenant) ->
        enqueue_waiter(state, from, :background, tenant)

      # A tenant with too many recent unreaped kills is in a decay-timed
      # penalty box: its killed executions' native threads are still
      # burning cores, so handing it fresh slots compounds the damage.
      # Children pass — their parent already holds a slot.
      class in [:root, :background] and tenant_unreaped_at_cap?(state, tenant) ->
        Logger.warning(
          "[Cyfr.Execution.Semaphore] Tenant #{inspect(tenant)} refused: " <>
            "#{live_unreaped(state, tenant)} unreaped timeout kills in the last " <>
            "#{div(@unreaped_ttl_ms, 60_000)}min (threshold #{state.unreaped_max})"
        )

        {:reply, {:error, :tenant_unreaped_limit}, state}

      class == :root and tenant_at_cap?(state, tenant) ->
        Logger.warning(
          "[Cyfr.Execution.Semaphore] Tenant #{inspect(tenant)} at per-tenant cap " <>
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
      for {pid, {_ref, holdings}} <- state.monitors, {acquired_at, _tenant, class} <- holdings do
        %{
          pid: inspect(pid),
          alive: Process.alive?(pid),
          held_ms: now - acquired_at,
          class: class
        }
      end

    by_class = Enum.frequencies_by(holders, & &1.class)

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
      tenants: state.tenant_roots,
      unreaped: Map.new(state.tenant_unreaped, fn {t, _} -> {t, live_unreaped(state, t)} end)
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:force_release_all, _from, state) do
    holder_count = holding_count(state)
    waiter_count = total_waiter_count(state)

    if holder_count > 0 or waiter_count > 0 do
      Logger.warning(
        "[Cyfr.Execution.Semaphore] Force-releasing #{holder_count} held slot(s) and " <>
          "#{waiter_count} queued waiter(s)"
      )

      Enum.each(state.monitors, fn {_pid, {mon_ref, _holdings}} ->
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
         # The penalty box stays: the spinning threads a force-release
         # cannot stop are still charged to the tenants that left them.
         waiters: %{root: :queue.new(), child: :queue.new(), background: :queue.new()},
         waiter_monitors: %{},
         background_waiters: %{}
     }}
  end

  @impl true
  def handle_call({:forgive_unreaped, tenant}, _from, state) do
    {:reply, :ok, %{state | tenant_unreaped: Map.delete(state.tenant_unreaped, tenant)}}
  end

  def handle_call({:unreaped, tenant, execution_id}, _from, state) when is_binary(tenant) do
    expiry = System.monotonic_time(:millisecond) + @unreaped_ttl_ms

    entries = [expiry | prune_unreaped(Map.get(state.tenant_unreaped, tenant, []))]

    Logger.warning(
      "[Cyfr.Execution.Semaphore] Unreaped kill of #{inspect(execution_id)} noted for tenant " <>
        "#{inspect(tenant)} (#{length(entries)}/#{state.unreaped_max} " <>
        "in the decay window)"
    )

    :telemetry.execute(
      [:cyfr, :opus, :execution, :unreaped_kill],
      %{system_time: System.system_time(), unreaped_count: length(entries)},
      %{tenant: tenant, execution_id: execution_id}
    )

    {:reply, :ok, %{state | tenant_unreaped: Map.put(state.tenant_unreaped, tenant, entries)}}
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

  # A process that went away gives back everything it held and leaves any
  # queue it was waiting in: a holder can also be waiting for another slot.
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state =
      case Map.get(state.waiter_monitors, pid) do
        nil ->
          state

        {_from, mon_ref, _class, _tenant} ->
          Process.demonitor(mon_ref, [:flush])
          remove_waiter(state, pid)
      end

    {:noreply, release_all(state, pid)}
  end

  @impl true
  def handle_info(:sweep_stale, state) do
    state = state |> sweep_stale_holders() |> prune_all_unreaped()
    schedule_sweep()
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    holder_count = holding_count(state)
    waiter_count = total_waiter_count(state)

    if holder_count > 0 or waiter_count > 0 do
      Logger.info(
        "[Cyfr.Execution.Semaphore] Terminating with #{holder_count} holder(s) and " <>
          "#{waiter_count} waiter(s)"
      )
    end

    Enum.each(state.monitors, fn {_pid, {mon_ref, _holdings}} ->
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
    acquired_at = System.monotonic_time(:millisecond)
    new_count = state.count + 1

    Logger.debug(
      "[Cyfr.Execution.Semaphore] Acquired #{class} slot for #{inspect(pid)} " <>
        "(#{new_count}/#{state.max})"
    )

    %{state | count: new_count}
    |> add_holding(pid, nil, {acquired_at, tenant, class})
    |> inc_tenant(tenant, class)
  end

  # One more holding for `pid`, under the one monitor it keeps however many
  # slots it holds; `monitor` is one the caller already took, or nil.
  defp add_holding(state, pid, monitor, holding) do
    monitors =
      case Map.get(state.monitors, pid) do
        {mon_ref, holdings} ->
          if monitor, do: Process.demonitor(monitor, [:flush])
          Map.put(state.monitors, pid, {mon_ref, [holding | holdings]})

        nil ->
          Map.put(state.monitors, pid, {monitor || Process.monitor(pid), [holding]})
      end

    %{state | monitors: monitors}
  end

  defp holding_count(state),
    do: Enum.reduce(state.monitors, 0, fn {_pid, {_ref, holdings}}, n -> n + length(holdings) end)

  # A slot handed to a waiter: the count stays, the holder changes.
  defp transfer(state, from, waiter_mon_ref, tenant, class) do
    {waiter_pid, _tag} = from
    acquired_at = System.monotonic_time(:millisecond)
    GenServer.reply(from, :ok)

    Logger.debug(
      "[Cyfr.Execution.Semaphore] Transferred slot to queued #{class} #{inspect(waiter_pid)} " <>
        "(#{state.count}/#{state.max})"
    )

    state
    |> add_holding(waiter_pid, waiter_mon_ref, {acquired_at, tenant, class})
    |> inc_tenant(tenant, class)
  end

  defp enqueue_waiter(state, {caller_pid, _tag} = from, class, tenant) do
    waiter_count = total_waiter_count(state)

    cond do
      waiter_count >= state.max_waiters ->
        Logger.warning(
          "[Cyfr.Execution.Semaphore] Queue full (#{waiter_count}/#{state.max_waiters}), rejecting"
        )

        {:reply, {:error, :queue_full}, state}

      class == :background and background_queue_full?(state, tenant) ->
        Logger.warning(
          "[Cyfr.Execution.Semaphore] Background queue full for #{inspect(tenant)}, rejecting"
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
          "[Cyfr.Execution.Semaphore] Queued #{inspect(caller_pid)} " <>
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

  # Give back `pid`'s newest holding; an unknown caller releases nothing.
  defp do_release(%{monitors: monitors} = state, pid) do
    case Map.get(monitors, pid) do
      nil ->
        state

      {mon_ref, [{_acquired_at, tenant, class} | rest]} ->
        monitors =
          if rest == [] do
            Process.demonitor(mon_ref, [:flush])
            Map.delete(monitors, pid)
          else
            Map.put(monitors, pid, {mon_ref, rest})
          end

        %{state | monitors: monitors}
        |> dec_tenant(tenant, class)
        |> hand_off_slot(pid)
    end
  end

  defp release_all(state, pid) do
    case Map.get(state.monitors, pid) do
      nil -> state
      {_mon_ref, holdings} -> Enum.reduce(holdings, state, fn _, acc -> do_release(acc, pid) end)
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
        "[Cyfr.Execution.Semaphore] Released slot for #{inspect(released_pid)} " <>
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
              "[Cyfr.Execution.Semaphore] Skipping queued #{inspect(elem(from, 0))}: " <>
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

  # The first background waiter whose athanor is under its BACKGROUND cap;
  # the ones at cap stay queued in order.
  #
  # The same ceiling admission uses, not the athanor's full cap. Handing a
  # freed slot to a waiter past the half-cap walked an athanor's schedules up
  # to `tenant_max` one release at a time — including on slots released by
  # other athanors — and the member's next turn met `:tenant_limit` anyway,
  # which is exactly what the half exists to prevent.
  defp next_background(state) do
    if state.count - 1 < state.max - state.child_reserve do
      list = :queue.to_list(state.waiters.background)

      case Enum.split_while(list, fn {_f, _m, _c, tenant} ->
             tenant_at_background_cap?(state, tenant)
           end) do
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

  defp tenant_unreaped_at_cap?(_state, nil), do: false

  defp tenant_unreaped_at_cap?(state, tenant) do
    live_unreaped(state, tenant) >= state.unreaped_max
  end

  # Counted live (without mutating state) so the acquire path stays a pure
  # read; the periodic sweep does the actual pruning.
  defp live_unreaped(state, tenant) do
    state.tenant_unreaped |> Map.get(tenant, []) |> prune_unreaped() |> length()
  end

  defp prune_unreaped(entries) do
    now = System.monotonic_time(:millisecond)
    Enum.filter(entries, &(&1 > now))
  end

  defp prune_all_unreaped(%{tenant_unreaped: unreaped} = state) when map_size(unreaped) == 0,
    do: state

  defp prune_all_unreaped(state) do
    pruned =
      state.tenant_unreaped
      |> Enum.flat_map(fn {tenant, entries} ->
        case prune_unreaped(entries) do
          [] -> []
          live -> [{tenant, live}]
        end
      end)
      |> Map.new()

    %{state | tenant_unreaped: pruned}
  end

  defp tenant_at_background_cap?(_state, nil), do: false

  defp tenant_at_background_cap?(state, tenant) do
    Map.get(state.tenant_roots, tenant, 0) >= background_ceiling(state)
  end

  # Half an athanor's slots, and never less than one — a server with a cap
  # of one still runs its schedules, just never alongside a turn.
  defp background_ceiling(state), do: max(1, div(state.tenant_max, 2))

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

  # The backstop for a slot whose `:DOWN` never arrived — NOT a time limit on
  # execution. A holder that is still alive keeps its slot however long it
  # has held it: the platform ceiling allows a 30-minute timeout
  # (`Sanctum.Policy.Ceiling`) and this sweep runs at ten, so an age test
  # alone releases the slot of a consented execution that is still running.
  # The execution does not stop — it just stops being counted, which
  # over-admits past both the global cap and its tenant's, and its own
  # release then finds nothing to give back.
  #
  # `Opus.ExecutionSweeper` draws the same distinction for execution rows:
  # a lapsed lease is only swept once the process behind it is gone.
  defp sweep_stale_holders(state) do
    now = System.monotonic_time(:millisecond)

    stale_pids =
      for {pid, {_ref, holdings}} <- state.monitors,
          {acquired_at, _tenant, _class} = List.last(holdings),
          now - acquired_at > @max_hold_ms and not Process.alive?(pid),
          do: pid

    if stale_pids != [] do
      Logger.warning(
        "[Cyfr.Execution.Semaphore] Sweeping #{length(stale_pids)} abandoned slot(s) whose " <>
          "holder is gone and whose DOWN never arrived: #{inspect(stale_pids)}"
      )
    end

    Enum.reduce(stale_pids, state, fn pid, acc -> release_all(acc, pid) end)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep_stale, @sweep_interval_ms)
  end
end
