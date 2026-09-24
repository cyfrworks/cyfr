# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Slots do
  @moduledoc """
  Shared runtime primitive, with each process instance owned by its application.

  Held concurrency: a supervised count of slots that processes take, hold
  and give back, with a total cap, a cap per key, a reserve for child work
  and waiter queues served in class order. One implementation, configured
  once per use.

  A slot is **held**: the holder keeps it for as long as its work runs and
  the count drops only when the holder gives it back, dies, or is swept.
  That is a different thing from a consumed **rate allowance**
  (`Cyfr.Execution.Rates`): an allowance is spent at admission and comes
  back with the clock, whether or not the work still runs. Nothing in this
  module counts rates.

  ## Classes

  Every acquisition names what it is:

  - `:root` — work somebody is waiting on: a chat turn, an `execution.run`,
    a build. It counts against its key's cap and is **refused** at that cap
    (`{:error, :key_cap}`) rather than queued: the person is waiting, and
    one key's backlog must not interleave with everyone's queue.
  - `:child` — a hop a running root makes under its parent's authority. The
    parent holds its slot while it waits on the child, so a child that could
    not get one would deadlock the chain; children therefore take any free
    slot, are never counted against the key, and `child_reserve` of the
    total is theirs alone: roots and background work stop at
    `max - child_reserve`.
  - `:background` — a schedule firing, a webhook; nobody is watching. It
    counts against its key's cap but stops at **half** of it
    (`background_ceiling/1`), waiting rather than being refused, so a flock
    of same-minute schedules can never turn the next turn into a refusal.

  A released slot is handed to a queued child first, then a root, then
  background work. A queued root whose key reached its cap meanwhile is
  refused at hand-off, so the key cap holds across transfers too; a queued
  background waiter whose key is at its half stays queued in order.

  ## Waiting

  Each class has a policy. `:wait` queues the caller for at most `wait_ms`
  and answers `{:error, :timeout}` when nothing was freed in time; the queue
  is bounded (`4 * max` waiters in all, `4 * key_max` background waiters per
  key) and `wait_ms: 0` never queues, both answered `{:error, :capacity}`.
  `:reject` answers `{:error, :capacity}` at once. A waiter that dies leaves
  the queue; one cancelled with `cancel/2` is answered
  `{:error, :cancelled}`; a caller that stopped waiting has any slot handed
  to it meanwhile given straight back. No waiter leaves a slot behind.

  ## Release

  A slot is given back by its ref (`release/2`, idempotent), by the holder's
  death (a monitor), or by the sweep: every `sweep_interval_ms` a holding
  older than `hold_ms` whose holder is **dead** is reclaimed — the backstop
  for a `:DOWN` that never arrived, not a time limit on work. A live holder
  keeps its slot however long it has held it: reclaiming a running holder's
  slot admits a second beside it, a silent capacity breach; the sweep warns
  about it instead. `force_release_all/1` is the operator's recovery
  gesture: every holding is dropped and every waiter cancelled.

  ## Unreaped kills

  A kill that leaves native work running is noted against its key with
  `note_unreaped/3`, by name: the noting process need not be the holder, and
  the note is acknowledged before the kill it precedes. A key with
  `unreaped_max` live notes is in a penalty box and refused
  `{:error, :key_unreaped}` for roots and background work; children pass,
  since their parent already holds a slot. Notes decay after
  `unreaped_ttl_ms`, because native completion is not observable;
  `forgive_unreaped/2` clears them early, and a force-release keeps them.

  ## Configuration

  `start_link/1` takes a name and the numbers. Every option defaults to what
  the execution slots use, so one implementation serves each use:

  - The execution slots (CYFR's instance, `Cyfr.Execution.Slots`):
    `max: 128, key_max: 16` and every other option default — a quarter of
    the slots reserved for children, every class waits, a 30 s sweep with a
    10 min hold, a 10 min unreaped decay with a threshold of half the key
    cap and never below 2. The key is the athanor id. Registering the
    execution for cancellation stays with the caller, as does emitting the
    unreaped-kill telemetry from the count `note_unreaped/3` answers.
  - The build slots (Locus's instance, `Locus.BuildSlots`): `max: 2,
    key_max: 1, child_reserve: 0, policy: :reject`, the sweep and hold
    default. A caller past the total cap is answered `:capacity` at once
    and one past its key's cap `:key_cap`; the same holder may take several
    slots, each released on its own ref, and its death releases them all.

  One instance is one process on one node: nothing is shared across nodes
  or persisted, and a restart loses every hold and wait. It is not a
  cluster authority; a limit that must hold across boots belongs to a lease.
  """

  use GenServer

  require Logger

  @classes [:root, :child, :background]
  @policies [:wait, :reject]
  @default_max 128
  @default_key_max 16
  @default_wait_ms 30_000
  @default_sweep_interval_ms 30_000
  @default_hold_ms 10 * 60 * 1000
  @default_unreaped_ttl_ms 10 * 60 * 1000
  # The server answers a wait itself when it expires; the caller waits this
  # much longer before giving up on a server that is wedged, not full.
  @call_grace_ms 1_000

  @type class :: :root | :child | :background
  @type key :: term()
  @type policy :: :wait | :reject
  @type refusal :: :capacity | :key_cap | :key_unreaped | :timeout | :cancelled | :unavailable
  @type server :: GenServer.server()
  @type option ::
          {:name, GenServer.name()}
          | {:max, pos_integer()}
          | {:key_max, pos_integer()}
          | {:child_reserve, non_neg_integer()}
          | {:policy, policy() | %{optional(class()) => policy()}}
          | {:sweep_interval_ms, pos_integer()}
          | {:hold_ms, non_neg_integer()}
          | {:unreaped_ttl_ms, pos_integer()}
          | {:unreaped_max, pos_integer()}
  @type holder :: %{
          pid: String.t(),
          alive: boolean(),
          held_ms: non_neg_integer(),
          class: class(),
          key: key()
        }
  @type status :: %{
          optional(:error) => :unavailable,
          max: non_neg_integer(),
          active: non_neg_integer(),
          available: non_neg_integer(),
          child_reserve: non_neg_integer(),
          key_max: non_neg_integer(),
          root_active: non_neg_integer(),
          child_active: non_neg_integer(),
          background_active: non_neg_integer(),
          queued: non_neg_integer(),
          queued_by_class: %{
            root: non_neg_integer(),
            child: non_neg_integer(),
            background: non_neg_integer()
          },
          holders: [holder()],
          keys: %{optional(key()) => pos_integer()},
          unreaped: %{optional(key()) => pos_integer()}
        }

  # ============================================================================
  # Derived numbers
  # ============================================================================

  @doc "The total cap the execution slots ship with."
  @spec default_max() :: pos_integer()
  def default_max, do: @default_max

  @doc "The per-key cap the execution slots ship with."
  @spec default_key_max() :: pos_integer()
  def default_key_max, do: @default_key_max

  @doc "The slots kept for children out of `max`: a quarter."
  @spec child_reserve(pos_integer()) :: non_neg_integer()
  def child_reserve(max) when is_integer(max) and max > 0, do: div(max, 4)

  @doc """
  How many of a key's slots background work may hold: half its cap, and
  never less than one, so a key with a cap of one still runs its schedules,
  just never alongside a turn.
  """
  @spec background_ceiling(pos_integer()) :: pos_integer()
  def background_ceiling(key_max) when is_integer(key_max) and key_max > 0,
    do: max(1, div(key_max, 2))

  @doc """
  The live unreaped notes that put a key in the penalty box: half its cap,
  and never less than two, so a couple of benign timeouts cannot trip it
  while half a cap of spinning cores must.
  """
  @spec unreaped_threshold(pos_integer()) :: pos_integer()
  def unreaped_threshold(key_max) when is_integer(key_max) and key_max > 0,
    do: max(2, div(key_max, 2))

  @doc """
  The most slots one key can hold at once: each of its roots may carry a
  chain down to the authority depth cap, and children are exempt from the
  key count on purpose (a chain must be able to finish, or it blocks holding
  its own root slot). With the shipped defaults — 128 slots, 16 per key,
  depth cap 8 — it comes to 128, the whole node: the key cap bounds a key's
  roots, not its footprint. The boot that configures the numbers compares
  this with `max` and warns the operator.
  """
  @spec max_key_footprint(pos_integer()) :: pos_integer()
  def max_key_footprint(key_max) when is_integer(key_max) and key_max > 0,
    do: key_max * Prima.Authority.depth_cap()

  # ============================================================================
  # Lifecycle
  # ============================================================================

  @doc """
  A worker child spec whose id is the instance's `:name`, so several
  instances sit under one supervisor.
  """
  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Start an instance. See the moduledoc for the options and their defaults;
  an invalid option raises `ArgumentError` before anything is started,
  since a wrong cap admits work nobody sized for.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    config = config!(opts)

    case Keyword.fetch(opts, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, config, name: name)
      :error -> GenServer.start_link(__MODULE__, config)
    end
  end

  # ============================================================================
  # Slots
  # ============================================================================

  @doc """
  Take a slot of `class` for `key` in the calling process. `key` is opaque
  (the athanor id, or nil for work that belongs to no key and is counted
  against the total only).

  Answers `{:ok, ref}`, the ref `release/2` takes back, or a refusal:
  `:capacity` (the total cap or the queue is full, the class rejects, or
  `wait_ms` was 0), `:key_cap` (a root at its key's cap), `:key_unreaped`
  (the key is in the penalty box), `:timeout` (waited `wait_ms` and nothing
  was freed), `:cancelled` (`cancel/2` or a force-release ended the wait),
  or `:unavailable` (the server is not running). `refusal/1` gives each
  its sentence.

  ## Options

  - `:wait_ms` — how long to queue under the `:wait` policy: a non-negative
    integer or `:infinity`, default #{@default_wait_ms}.
  """
  @spec acquire(server(), key(), class(), [{:wait_ms, non_neg_integer() | :infinity}]) ::
          {:ok, reference()} | {:error, refusal()}
  def acquire(server, key, class, opts \\ []) when class in @classes and is_list(opts) do
    wait_ms = wait_ms!(Keyword.get(opts, :wait_ms, @default_wait_ms))
    ref = make_ref()

    try do
      GenServer.call(server, {:acquire, ref, key, class, wait_ms}, call_timeout(wait_ms))
    catch
      :exit, {:timeout, _} ->
        # The server did not answer inside the wait and its grace. The
        # caller leaves now; whatever the server grants this ref later goes
        # straight back rather than to a process that has moved on.
        GenServer.cast(server, {:abandon, ref})
        {:error, :timeout}

      :exit, _reason ->
        {:error, :unavailable}
    end
  end

  @doc """
  Give a slot back. From any process, idempotent: a ref already released,
  swept or never granted releases nothing, so the count never underflows.
  """
  @spec release(server(), reference()) :: :ok
  def release(server, ref) when is_reference(ref), do: GenServer.cast(server, {:release, ref})

  @doc """
  End every wait `pid` has queued; each is answered `{:error, :cancelled}`.
  A slot `pid` already holds is not touched — `release/2` gives that back.
  """
  @spec cancel(server(), pid()) :: :ok | {:error, :unavailable}
  def cancel(server, pid) when is_pid(pid), do: call(server, {:cancel, pid})

  @doc """
  Note that `execution_id` of `key`'s was killed with its native work
  unreaped: a timeout, or a cancel. Charged to the key by name, from any
  process, and acknowledged before the kill it precedes, so no ordering
  between this and the holder's release — or its `:DOWN` — can lose it.
  Answers the key's live count, from which the caller emits its telemetry;
  a nil key charges nobody. `{:error, :unavailable}` means the kill goes
  uncharged, and the caller records that by execution.
  """
  @spec note_unreaped(server(), key(), term()) ::
          {:ok, non_neg_integer()} | {:error, :unavailable}
  def note_unreaped(_server, nil, _execution_id), do: {:ok, 0}

  def note_unreaped(server, key, execution_id),
    do: call(server, {:note_unreaped, key, execution_id})

  @doc """
  Clear one key's penalty box before it decays: the operator has dealt with
  the spinning work at the node level. A force-release does not do this.
  """
  @spec forgive_unreaped(server(), key()) :: :ok | {:error, :unavailable}
  def forgive_unreaped(server, key), do: call(server, {:forgive_unreaped, key})

  @doc """
  The instance's counts for diagnostics: totals, per class, per key, the
  holders with their age, the waiters per class and the live unreaped notes.
  A server that is not running answers the same keys with zeros and
  `error: :unavailable`, so a reader that narrows the live shape never
  crashes on the fallback.
  """
  @spec status(server()) :: status()
  def status(server) do
    case call(server, :status) do
      {:error, :unavailable} -> Map.put(empty_status(), :error, :unavailable)
      %{} = status -> status
    end
  end

  @doc """
  Emergency recovery: drop every holding and cancel every waiter, answering
  how many of each. The penalty box stays (`forgive_unreaped/2`). A server
  that is not running has nothing to release, and says so rather than
  reporting a recovery that did not happen.
  """
  @spec force_release_all(server()) ::
          {:ok, %{released: non_neg_integer(), cancelled: non_neg_integer()}}
          | {:error, :unavailable}
  def force_release_all(server), do: call(server, :force_release_all)

  @doc """
  Run the stale sweep now: reclaim the holdings of holders that are dead
  past the hold, count the live ones past it as wedged, and drop decayed
  unreaped notes. The periodic sweep does the same on its interval.
  """
  @spec sweep(server()) ::
          {:ok, %{reclaimed: non_neg_integer(), wedged: non_neg_integer()}}
          | {:error, :unavailable}
  def sweep(server), do: call(server, :sweep)

  @doc "The sentence a refusal means to the caller."
  @spec refusal(refusal()) :: String.t()
  def refusal(:capacity), do: "Server at maximum concurrent executions. Retry later."

  def refusal(:timeout),
    do: "Server at maximum concurrent executions, and none freed in time. Retry later."

  def refusal(:cancelled), do: "The wait for an execution slot was cancelled."
  def refusal(:key_cap), do: "Athanor at maximum concurrent executions. Retry later."

  def refusal(:key_unreaped),
    do:
      "Athanor has too many recently timed-out executions whose CPU could not be " <>
        "reclaimed. Wait a few minutes, and check for components that never yield."

  def refusal(:unavailable),
    do: "Execution slots are not being handed out right now. Retry later."

  defp call(server, request) do
    GenServer.call(server, request)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp wait_ms!(ms) when ms == :infinity or (is_integer(ms) and ms >= 0), do: ms

  defp wait_ms!(other),
    do:
      raise(
        ArgumentError,
        "wait_ms must be a non-negative integer or :infinity, got: #{inspect(other)}"
      )

  defp call_timeout(:infinity), do: :infinity
  defp call_timeout(wait_ms), do: wait_ms + @call_grace_ms

  # ============================================================================
  # Configuration
  # ============================================================================

  defp config!(opts) do
    max = positive!(opts, :max, @default_max)
    key_max = positive!(opts, :key_max, @default_key_max)
    child_reserve = Keyword.get(opts, :child_reserve, child_reserve(max))

    unless is_integer(child_reserve) and child_reserve >= 0 and child_reserve < max do
      raise ArgumentError,
            "child_reserve must be an integer from 0 below max (#{max}), got: #{inspect(child_reserve)}"
    end

    %{
      label: opts |> Keyword.get(:name) |> label(),
      max: max,
      key_max: key_max,
      child_reserve: child_reserve,
      policy: policy!(Keyword.get(opts, :policy, :wait)),
      sweep_interval_ms: positive!(opts, :sweep_interval_ms, @default_sweep_interval_ms),
      hold_ms: non_negative!(opts, :hold_ms, @default_hold_ms),
      unreaped_ttl_ms: positive!(opts, :unreaped_ttl_ms, @default_unreaped_ttl_ms),
      unreaped_max: positive!(opts, :unreaped_max, unreaped_threshold(key_max))
    }
  end

  defp label(nil), do: nil
  defp label(name), do: inspect(name)

  defp positive!(opts, option, default) do
    case Keyword.get(opts, option, default) do
      n when is_integer(n) and n > 0 -> n
      other -> raise ArgumentError, "#{option} must be a positive integer, got: #{inspect(other)}"
    end
  end

  defp non_negative!(opts, option, default) do
    case Keyword.get(opts, option, default) do
      n when is_integer(n) and n >= 0 ->
        n

      other ->
        raise ArgumentError, "#{option} must be a non-negative integer, got: #{inspect(other)}"
    end
  end

  defp policy!(policy) when policy in @policies, do: Map.new(@classes, &{&1, policy})

  defp policy!(%{} = per_class) do
    unless Enum.all?(per_class, fn {class, policy} ->
             class in @classes and policy in @policies
           end) do
      raise ArgumentError,
            "policy must be :wait, :reject, or a map of class to either, got: #{inspect(per_class)}"
    end

    Map.merge(policy!(:wait), per_class)
  end

  defp policy!(other),
    do:
      raise(
        ArgumentError,
        "policy must be :wait, :reject, or a map of class to either, got: #{inspect(other)}"
      )

  # ============================================================================
  # Server — state
  #
  #   holdings: ref => %{pid, key, class, since}
  #   waits:    ref => %{from, pid, key, class, timer}
  #   pids:     pid => %{monitor, holdings: [ref], waits: [ref]}, newest first,
  #             one monitor per process however many slots it holds or waits for
  #   queues:   class => queue of wait refs, in arrival order
  #   key_counts: key => roots and background held (children are exempt)
  #   background_waiting: key => background waiters queued (its own bound)
  #   unreaped: key => [expiry_ms], one per live note
  # ============================================================================

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    state = Map.put(config, :label, config.label || inspect(self()))

    Logger.info(
      "#{prefix(state)} started: max=#{state.max}, key_max=#{state.key_max}, " <>
        "child_reserve=#{state.child_reserve}, policy=#{inspect(state.policy)}"
    )

    schedule_sweep(state.sweep_interval_ms)

    {:ok,
     Map.merge(state, %{
       count: 0,
       holdings: %{},
       waits: %{},
       pids: %{},
       queues: new_queues(),
       key_counts: %{},
       background_waiting: %{},
       unreaped: %{},
       max_waiters: state.max * 4
     })}
  end

  @impl true
  def handle_call({:acquire, ref, key, class, wait_ms}, {pid, _} = from, state) do
    cond do
      class == :child and state.count < state.max ->
        {:reply, {:ok, ref}, grant(state, pid, ref, key, class)}

      class == :child ->
        queue_or_refuse(state, from, ref, key, class, wait_ms)

      # A key with too many recent unreaped kills is in a decay-timed
      # penalty box: its killed work is still burning cores, so fresh slots
      # compound the damage. Children passed above: their parent holds one.
      key_unreaped?(state, key) ->
        Logger.warning(
          "#{prefix(state)} key #{inspect(key)} refused: #{live_unreaped(state, key)} unreaped " <>
            "kills in the last #{div(state.unreaped_ttl_ms, 60_000)}min (threshold #{state.unreaped_max})"
        )

        {:reply, {:error, :key_unreaped}, state}

      class == :root and key_at_cap?(state, key) ->
        Logger.warning(
          "#{prefix(state)} key #{inspect(key)} at its cap (#{state.key_max}), refusing a root"
        )

        {:reply, {:error, :key_cap}, state}

      # Background work stops at half the key's cap: what is left is for
      # whoever is waiting at the glass.
      class == :background and key_at_background_cap?(state, key) ->
        queue_or_refuse(state, from, ref, key, class, wait_ms)

      foreground_free?(state) ->
        {:reply, {:ok, ref}, grant(state, pid, ref, key, class)}

      true ->
        queue_or_refuse(state, from, ref, key, class, wait_ms)
    end
  end

  def handle_call({:cancel, pid}, _from, state) do
    refs =
      case Map.get(state.pids, pid) do
        nil -> []
        %{waits: refs} -> refs
      end

    state = Enum.reduce(refs, state, &refuse_waiter(&2, &1, :cancelled))
    {:reply, :ok, prune_pid(state, pid)}
  end

  def handle_call({:note_unreaped, key, execution_id}, _from, state) do
    now = now_ms()
    entries = [now + state.unreaped_ttl_ms | live_entries(Map.get(state.unreaped, key, []), now)]

    Logger.warning(
      "#{prefix(state)} unreaped kill of #{inspect(execution_id)} noted for key #{inspect(key)} " <>
        "(#{length(entries)}/#{state.unreaped_max} in the decay window)"
    )

    {:reply, {:ok, length(entries)}, %{state | unreaped: Map.put(state.unreaped, key, entries)}}
  end

  def handle_call({:forgive_unreaped, key}, _from, state),
    do: {:reply, :ok, %{state | unreaped: Map.delete(state.unreaped, key)}}

  def handle_call(:status, _from, state) do
    now = now_ms()

    holders =
      for {_ref, holding} <- state.holdings do
        %{
          pid: inspect(holding.pid),
          alive: Process.alive?(holding.pid),
          held_ms: now - holding.since,
          class: holding.class,
          key: holding.key
        }
      end

    by_class = Enum.frequencies_by(holders, & &1.class)

    reply = %{
      max: state.max,
      active: state.count,
      available: max(state.max - state.count, 0),
      child_reserve: state.child_reserve,
      key_max: state.key_max,
      root_active: Map.get(by_class, :root, 0),
      child_active: Map.get(by_class, :child, 0),
      background_active: Map.get(by_class, :background, 0),
      queued: map_size(state.waits),
      queued_by_class: Map.new(@classes, &{&1, :queue.len(state.queues[&1])}),
      holders: holders,
      keys: state.key_counts,
      unreaped:
        for {key, entries} <- state.unreaped,
            live = length(live_entries(entries, now)),
            live > 0,
            into: %{} do
          {key, live}
        end
    }

    {:reply, reply, state}
  end

  def handle_call(:force_release_all, _from, state) do
    released = map_size(state.holdings)
    cancelled = map_size(state.waits)

    if released > 0 or cancelled > 0 do
      Logger.warning(
        "#{prefix(state)} force-releasing #{released} held slot(s) and cancelling #{cancelled} waiter(s)"
      )
    end

    Enum.each(state.waits, fn {_ref, wait} ->
      cancel_timer(wait.timer)
      GenServer.reply(wait.from, {:error, :cancelled})
    end)

    Enum.each(state.pids, fn {_pid, %{monitor: monitor}} ->
      Process.demonitor(monitor, [:flush])
    end)

    # The penalty box stays: the spinning work a force-release cannot stop
    # is still charged to the keys that left it.
    {:reply, {:ok, %{released: released, cancelled: cancelled}},
     %{
       state
       | count: 0,
         holdings: %{},
         waits: %{},
         pids: %{},
         queues: new_queues(),
         key_counts: %{},
         background_waiting: %{}
     }}
  end

  def handle_call(:sweep, _from, state) do
    {state, report} = sweep_stale(state)
    {:reply, {:ok, report}, prune_unreaped(state)}
  end

  @impl true
  def handle_cast({:release, ref}, state), do: {:noreply, do_release(state, ref)}

  # A caller that gave up on its wait dequeues itself. If a hand-off already
  # won the race and made it a holder, that slot goes back: its `{:ok, ref}`
  # went to a caller that is no longer waiting for it.
  def handle_cast({:abandon, ref}, state) do
    case Map.get(state.waits, ref) do
      nil -> {:noreply, do_release(state, ref)}
      wait -> {:noreply, state |> detach_wait(ref) |> prune_pid(wait.pid)}
    end
  end

  @impl true
  def handle_info({:wait_expired, ref}, state) do
    case Map.get(state.waits, ref) do
      nil -> {:noreply, state}
      wait -> {:noreply, state |> refuse_waiter(ref, :timeout) |> prune_pid(wait.pid)}
    end
  end

  # A process that went away gives back everything it held and leaves every
  # queue it was waiting in: a holder can also be waiting for another slot.
  def handle_info({:DOWN, _monitor, :process, pid, _reason}, state),
    do: {:noreply, drop_pid(state, pid)}

  def handle_info(:sweep, state) do
    {state, _report} = sweep_stale(state)
    schedule_sweep(state.sweep_interval_ms)
    {:noreply, prune_unreaped(state)}
  end

  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if map_size(state.holdings) > 0 or map_size(state.waits) > 0 do
      Logger.info(
        "#{prefix(state)} terminating with #{map_size(state.holdings)} holding(s) and " <>
          "#{map_size(state.waits)} waiter(s)"
      )
    end

    Enum.each(state.pids, fn {_pid, %{monitor: monitor}} ->
      Process.demonitor(monitor, [:flush])
    end)

    :ok
  end

  # ============================================================================
  # Admission
  # ============================================================================

  defp queue_or_refuse(state, from, ref, key, class, wait_ms) do
    cond do
      Map.fetch!(state.policy, class) == :reject ->
        {:reply, {:error, :capacity}, state}

      wait_ms == 0 ->
        {:reply, {:error, :capacity}, state}

      map_size(state.waits) >= state.max_waiters ->
        Logger.warning(
          "#{prefix(state)} queue full (#{map_size(state.waits)}/#{state.max_waiters}), refusing"
        )

        {:reply, {:error, :capacity}, state}

      class == :background and background_queue_full?(state, key) ->
        Logger.warning("#{prefix(state)} background queue full for key #{inspect(key)}, refusing")
        {:reply, {:error, :capacity}, state}

      true ->
        {:noreply, enqueue(state, from, ref, key, class, wait_ms)}
    end
  end

  defp enqueue(state, {pid, _tag} = from, ref, key, class, wait_ms) do
    timer =
      if wait_ms == :infinity,
        do: nil,
        else: Process.send_after(self(), {:wait_expired, ref}, wait_ms)

    wait = %{from: from, pid: pid, key: key, class: class, timer: timer}

    Logger.debug(
      "#{prefix(state)} queued #{inspect(pid)} (class=#{class}, queue=#{map_size(state.waits) + 1})"
    )

    state
    |> ensure_pid(pid)
    |> update_pid(pid, &%{&1 | waits: [ref | &1.waits]})
    |> Map.update!(:waits, &Map.put(&1, ref, wait))
    |> Map.update!(:queues, &Map.update!(&1, class, fn queue -> :queue.in(ref, queue) end))
    |> bump_background_waiting(key, class, 1)
  end

  defp grant(state, pid, ref, key, class) do
    holding = %{pid: pid, key: key, class: class, since: now_ms()}

    Logger.debug(
      "#{prefix(state)} granted a #{class} slot to #{inspect(pid)} (#{state.count + 1}/#{state.max})"
    )

    %{state | count: state.count + 1, holdings: Map.put(state.holdings, ref, holding)}
    |> ensure_pid(pid)
    |> update_pid(pid, &%{&1 | holdings: [ref | &1.holdings]})
    |> bump_key(key, class, 1)
  end

  # Roots and background work stop short of the child reserve.
  defp foreground_free?(state), do: state.count < state.max - state.child_reserve

  defp key_at_cap?(_state, nil), do: false
  defp key_at_cap?(state, key), do: Map.get(state.key_counts, key, 0) >= state.key_max

  defp key_at_background_cap?(_state, nil), do: false

  defp key_at_background_cap?(state, key),
    do: Map.get(state.key_counts, key, 0) >= background_ceiling(state.key_max)

  defp background_queue_full?(_state, nil), do: false

  defp background_queue_full?(state, key),
    do: Map.get(state.background_waiting, key, 0) >= state.key_max * 4

  # ============================================================================
  # Release and hand-off
  # ============================================================================

  # Give back one holding; an unknown ref releases nothing.
  defp do_release(state, ref) do
    case Map.pop(state.holdings, ref) do
      {nil, _holdings} ->
        state

      {holding, holdings} ->
        Logger.debug(
          "#{prefix(state)} released a #{holding.class} slot of #{inspect(holding.pid)} (#{state.count - 1}/#{state.max})"
        )

        %{state | count: state.count - 1, holdings: holdings}
        |> update_pid(holding.pid, &%{&1 | holdings: List.delete(&1.holdings, ref)})
        |> prune_pid(holding.pid)
        |> bump_key(holding.key, holding.class, -1)
        |> hand_off()
    end
  end

  # Everything a process held or waited for, on its :DOWN or the sweep.
  defp drop_pid(state, pid) do
    case Map.pop(state.pids, pid) do
      {nil, _pids} ->
        state

      {%{monitor: monitor, holdings: holdings, waits: waits}, pids} ->
        Process.demonitor(monitor, [:flush])
        state = %{state | pids: pids}
        # The waiter is gone: nothing to answer.
        state = Enum.reduce(waits, state, &detach_wait(&2, &1))
        Enum.reduce(holdings, state, &do_release(&2, &1))
    end
  end

  # The freed slot goes to the next eligible waiter: a child first (any slot
  # is a child's), then a root, then background work. A waiter refused at
  # hand-off is answered and the next one tried.
  defp hand_off(state) do
    with :none <- next_child(state),
         :none <- next_root(state),
         :none <- next_background(state) do
      state
    else
      {:transferred, state} -> state
      {:retry, state} -> hand_off(state)
    end
  end

  defp next_child(state) do
    with true <- state.count < state.max,
         {:value, ref} <- :queue.peek(state.queues.child) do
      {:transferred, transfer(state, ref)}
    else
      _ -> :none
    end
  end

  defp next_root(state) do
    with true <- foreground_free?(state),
         {:value, ref} <- :queue.peek(state.queues.root) do
      admit_waiter(state, ref)
    else
      _ -> :none
    end
  end

  # The first background waiter whose key is under its half; the ones at it
  # stay queued in order. The same ceiling admission uses: handing a freed
  # slot to a waiter past the half would walk a key's schedules up to its
  # cap one release at a time, on other keys' releases too, and the next
  # turn would meet :key_cap anyway — what the half exists to prevent.
  defp next_background(state) do
    with true <- foreground_free?(state),
         ref when is_reference(ref) <-
           Enum.find(
             :queue.to_list(state.queues.background),
             &(not key_at_background_cap?(state, state.waits[&1].key))
           ) do
      admit_waiter(state, ref)
    else
      _ -> :none
    end
  end

  # A waiter taken off its queue is admitted unless its key was refused
  # meanwhile: then it is answered as it would have been at the door, so the
  # key cap and the penalty box hold across transfers too.
  defp admit_waiter(state, ref) do
    wait = Map.fetch!(state.waits, ref)

    cond do
      key_unreaped?(state, wait.key) ->
        {:retry, state |> refuse_waiter(ref, :key_unreaped) |> prune_pid(wait.pid)}

      wait.class == :root and key_at_cap?(state, wait.key) ->
        {:retry, state |> refuse_waiter(ref, :key_cap) |> prune_pid(wait.pid)}

      true ->
        {:transferred, transfer(state, ref)}
    end
  end

  defp transfer(state, ref) do
    wait = Map.fetch!(state.waits, ref)
    GenServer.reply(wait.from, {:ok, ref})
    Logger.debug("#{prefix(state)} handed a slot to queued #{wait.class} #{inspect(wait.pid)}")

    state
    |> detach_wait(ref)
    |> grant(wait.pid, ref, wait.key, wait.class)
  end

  # Answer a waiter with a refusal and take it off its queue. The process
  # entry is left for the caller to prune, since it may hold slots still.
  defp refuse_waiter(state, ref, reason) do
    wait = Map.fetch!(state.waits, ref)

    if reason in [:key_cap, :key_unreaped] do
      Logger.warning(
        "#{prefix(state)} refusing queued #{wait.class} #{inspect(wait.pid)} at hand-off: #{reason}"
      )
    end

    GenServer.reply(wait.from, {:error, reason})
    detach_wait(state, ref)
  end

  # Take a wait off every index; the process entry stays.
  defp detach_wait(state, ref) do
    case Map.pop(state.waits, ref) do
      {nil, _waits} ->
        state

      {wait, waits} ->
        cancel_timer(wait.timer)

        %{state | waits: waits}
        |> Map.update!(
          :queues,
          &Map.update!(&1, wait.class, fn queue -> :queue.delete(ref, queue) end)
        )
        |> update_pid(wait.pid, &%{&1 | waits: List.delete(&1.waits, ref)})
        |> bump_background_waiting(wait.key, wait.class, -1)
    end
  end

  # ============================================================================
  # Processes and counts
  # ============================================================================

  defp ensure_pid(state, pid) do
    if Map.has_key?(state.pids, pid) do
      state
    else
      entry = %{monitor: Process.monitor(pid), holdings: [], waits: []}
      %{state | pids: Map.put(state.pids, pid, entry)}
    end
  end

  defp update_pid(state, pid, fun) do
    case Map.get(state.pids, pid) do
      nil -> state
      entry -> %{state | pids: Map.put(state.pids, pid, fun.(entry))}
    end
  end

  # A process with nothing held and nothing waited for is no longer watched.
  defp prune_pid(state, pid) do
    case Map.get(state.pids, pid) do
      %{monitor: monitor, holdings: [], waits: []} ->
        Process.demonitor(monitor, [:flush])
        %{state | pids: Map.delete(state.pids, pid)}

      _ ->
        state
    end
  end

  # Only roots and background work count against the key; children run
  # inside a root's allowance.
  defp bump_key(state, nil, _class, _delta), do: state
  defp bump_key(state, _key, :child, _delta), do: state

  defp bump_key(state, key, _class, delta),
    do: %{state | key_counts: bump(state.key_counts, key, delta)}

  defp bump_background_waiting(state, key, :background, delta) when not is_nil(key),
    do: %{state | background_waiting: bump(state.background_waiting, key, delta)}

  defp bump_background_waiting(state, _key, _class, _delta), do: state

  defp bump(counts, key, delta) do
    case Map.get(counts, key, 0) + delta do
      n when n <= 0 -> Map.delete(counts, key)
      n -> Map.put(counts, key, n)
    end
  end

  # ============================================================================
  # Unreaped notes
  # ============================================================================

  defp key_unreaped?(_state, nil), do: false
  defp key_unreaped?(state, key), do: live_unreaped(state, key) >= state.unreaped_max

  # Counted live so admission stays a pure read; the sweep does the pruning.
  defp live_unreaped(state, key),
    do: state.unreaped |> Map.get(key, []) |> live_entries(now_ms()) |> length()

  defp live_entries(entries, now), do: Enum.filter(entries, &(&1 > now))

  defp prune_unreaped(%{unreaped: unreaped} = state) when map_size(unreaped) == 0, do: state

  defp prune_unreaped(state) do
    now = now_ms()

    pruned =
      for {key, entries} <- state.unreaped,
          live = live_entries(entries, now),
          live != [],
          into: %{} do
        {key, live}
      end

    %{state | unreaped: pruned}
  end

  # ============================================================================
  # Sweep
  # ============================================================================

  # The backstop for a holding whose :DOWN never arrived — not a time limit
  # on work. A holder still alive keeps its slot however long it has held
  # it: on an age test alone a consented long run would lose its slot while
  # still running, carry on uncounted past every cap, and later find nothing
  # to give back.
  defp sweep_stale(%{holdings: holdings} = state) when map_size(holdings) == 0,
    do: {state, %{reclaimed: 0, wedged: 0}}

  defp sweep_stale(state) do
    now = now_ms()

    {dead, wedged} =
      state.pids
      |> Enum.filter(fn {_pid, entry} ->
        entry.holdings != [] and past_hold?(state, entry, now)
      end)
      |> Enum.map(fn {pid, entry} -> {pid, length(entry.holdings)} end)
      |> Enum.split_with(fn {pid, _held} -> not Process.alive?(pid) end)

    if dead != [] do
      Logger.warning(
        "#{prefix(state)} sweeping #{length(dead)} abandoned holder(s) whose DOWN never arrived: " <>
          inspect(Enum.map(dead, &elem(&1, 0)))
      )
    end

    if wedged != [] do
      Logger.warning(
        "#{prefix(state)} #{length(wedged)} holder(s) alive but held >#{div(state.hold_ms, 60_000)}min, " <>
          "NOT reclaimed: #{inspect(Enum.map(wedged, &elem(&1, 0)))}"
      )
    end

    state = Enum.reduce(dead, state, fn {pid, _held}, acc -> drop_pid(acc, pid) end)
    reclaimed = Enum.reduce(dead, 0, fn {_pid, held}, n -> n + held end)
    {state, %{reclaimed: reclaimed, wedged: length(wedged)}}
  end

  # The oldest holding is the last of the newest-first list.
  defp past_hold?(state, %{holdings: refs}, now) do
    oldest = Map.fetch!(state.holdings, List.last(refs))
    now - oldest.since > state.hold_ms
  end

  defp schedule_sweep(interval_ms), do: Process.send_after(self(), :sweep, interval_ms)

  # ============================================================================
  # Small helpers
  # ============================================================================

  defp new_queues, do: Map.new(@classes, &{&1, :queue.new()})

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    Process.cancel_timer(timer)
    :ok
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp prefix(state), do: "[#{inspect(__MODULE__)} #{state.label}]"

  defp empty_status do
    %{
      max: 0,
      active: 0,
      available: 0,
      child_reserve: 0,
      key_max: 0,
      root_active: 0,
      child_active: 0,
      background_active: 0,
      queued: 0,
      queued_by_class: Map.new(@classes, &{&1, 0}),
      holders: [],
      keys: %{},
      unreaped: %{}
    }
  end
end
