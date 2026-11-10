# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Backends.Owners do
  @moduledoc """
  The owner table of the backends service: one owner per athanor and
  `mcp_servers` row, running at the generation `g` and epoch `e` its last
  sync named, with the programs that sync defined and the sessions opened
  on them (`Locus.Backends.Backend`, under
  `Locus.Backends.BackendSupervisor`). An owner lives while its lease
  does; nothing about it is persisted. The table's lifetime is the
  service's: `boot/1` names it, and a restart forgets every owner under a
  new one. A kept home outlives all of it: it is the launcher's.

  ## Control messages

  `control/4` applies one control message at a time, in the order they
  arrive, each only if its `(generation, seq)` is above every one applied
  before (`fresh/2` is the same check, made before a body is read):

  | Message | Rule |
  |---|---|
  | `sync` lower than the held `(g, e)` | `stale_epoch` |
  | `sync` equal, another definition | `conflict` |
  | `sync` equal while the owner drains | `lapsed` |
  | `sync` equal | the lease extended and the idle period set |
  | `sync` higher, or no owner | the held owner retired, then the new one admitted |
  | `renew` | each owner running at exactly `(g, e)` with a live lease is `renewed`; the rest `unknown` |
  | `release` | each owner at or below `(g, e)` retired |
  | `reconcile` | each owner not at exactly `g` and its kept `e` retired |
  | `status` | each named owner present, its programs as their sessions report them |
  | `home` | every session of the home among the athanor's owners ended, then the home reset or retired |

  A sync starts nothing: it is answered on admission with every program
  `idle`, or `failed` for none. A retired owner leaves routing at once and
  ends its sessions; a lapsed one stays routed, answering `lapsed`, until
  they are gone.

  ## Sessions

  `open/3` opens a session at exactly the owner's `(g, e)`. A `run` open
  attaches to the session running for its `(program, home, key)`
  (`resumed: true`) or starts one (`resumed: false`); a `sign_in` open
  does the same for the program's login command on a pseudo-terminal,
  which needs a kept home and a login command (`bad_request`). A program
  whose home is kept needs a `home_id` and a scratch one none
  (`bad_request`); a program the owner does not define is
  `unknown_program`; one failed, `program_failed`. An owner holds at most
  `Prima.LocusBackends.max_sessions/0` sessions, running or ended: the
  oldest ended one whose process is gone is forgotten for a new one, and
  with none such an open is `capacity`.

  ## Admission by memory

  Every session reserves its memory bound (the program's `memory_bytes`,
  or `:memory_bytes` for one that names none) from the moment its open is
  admitted, before its home is made or its pool read, until nothing of its
  process is left (its `:vacated`, or its session process gone): an open
  being prepared, a session running and one ended whose process has not
  yet gone all hold theirs. An open is admitted while

      held + requested <= floor(B * F)

  for the box, `B` being `:memory_budget` and `F` `:overcommit`
  (`Locus.Config.backends_memory_budget/0` and
  `backends_memory_overcommit/0`), and while the same sum over the
  sessions of the owner's athanor, every owner of it on this box, stays
  within that athanor's ceiling `A`, the `athanor_memory_bytes` its last
  sync named (`B` when it named none); past either it is `capacity`. A
  program whose bound alone is past the box's admission limit can never
  be admitted: a sync and a status report it `failed`, and a status names
  its bound and the limit as its `error`, while each of its opens is still
  `capacity`. An
  open that attaches to the session already running for its key reserves
  nothing more, and one that found it started while it was prepared drops
  its reservation. A session's process is gone only when its launcher says
  so: the session's own `:vacated`, or the launcher's word to this table as
  the spawn's heir (`t:Locus.Launcher.spec/0`). A held session this table
  stops following first, its session process dead or its owner retired,
  keeps its bound, and a scratch session's uid of the pool, in the table's
  endings, and the launcher is asked to fence it (`c:Locus.Launcher.fence/2`):
  an ending is cleared by the heir's word, or by the fence's `:none`, which
  proves no process of it exists or will start; a fence not answered is
  asked again at the next sweep. A release timeout never clears one. On
  start the table adopts, as heir, every process the launcher still holds
  for its ledger (`:ledger`, its name by default), so a table that restarts
  holds what its predecessor followed, and admits nothing until the
  launcher has answered. A hello and a status report the box's
  `memory{budget_bytes, admission_limit_bytes, held_bytes}`.

  Before a scratch session's process starts it holds a uid of the pool
  `backends`: the claim is made after one read of the pool
  (`Locus.Launcher.pool_stats/2`), with the check and the claim in one
  step of this process, and the uids held never exceed the pool's size
  less its quarantined uids (`capacity`; a pool the launcher does not
  answer is `unavailable`). The uid is freed when the session's process
  is gone. A kept session holds no uid of the pool: its home is made if it
  is absent (`Locus.Launcher.home_ensure/2`) and the process runs under
  the home's own uid.

  `session/3` names the running or ended session a `send`, `recv` or
  `close` reaches, at exactly the owner's version; one the owner does not
  hold is `unknown_session`. Nothing waits on a session here: those calls
  go to the session itself.

  ## Crashes

  A session whose process crashed (`Locus.Backends.Backend`) counts
  against its session key, `(program, home_id, key, mode)`, within
  `crash_window_ms/0`: the next open of that key starts its process only
  once the backoff's wait for that many crashes (`restart_backoff_ms/0`)
  has passed since the last, and the `max_crashes/0`-th fails that key,
  refusing its opens `program_failed` until a sync at a new version. One
  key's crashes never fail another's open: one home's sign-ins, or one
  caller's crashing session, leave every other key's process alone. A
  status reports the program `failed` while any of its keys is.

  ## A program's hosts

  A program that names `hosts` has each session's process started with
  them (`t:Locus.Launcher.spec/0`): the launcher resolves them as the
  process starts and has the island's guard hold its uid to their
  addresses. An open whose process the launcher refused for them answers
  `hosts_unresolved` (a name resolved to no address) or `guard_unavailable`
  (the guard did not confirm), each counted as a crash of its key.

  ## Kept homes and their bound

  A program with a kept home and a `home_max_bytes` has its home measured
  before each session's process starts (`Locus.Launcher.home_measure/2`)
  and, while one of its sessions runs, every `:measure_interval_ms`
  (10 s): a home at or past the bound has every session in it ended and is
  over its cap, refusing every open `home_over_cap` until a `home` reset.
  A measure fails closed: one that fails, or that the launcher could not
  take over the whole home, ends the home's sessions and leaves it
  unmeasurable, refused `home_over_cap` alike until a reset.

  Every running kept home is also checked on the same interval against the
  homes the launcher lists (`Locus.Launcher.home_list/1`): a session whose
  home's folder is gone is ended, never left running under a uid the
  launcher may give another home. A `homes` control message is answered
  with that list.

  ## Sleeping on nothing

  This process waits on no launcher and no session, but once, as it starts,
  for the launcher's answer to its adoption: a pool read, a home's making
  or measuring, a fence, an adoption asked again, the stopping of an
  owner's sessions and the collection of a status run in processes of
  their own and report back.
  The lease, idle and measuring checks run when `sweep/1` asks
  (`Locus.Backends.LeaseSweeper`).
  """

  use GenServer

  require Logger

  alias Locus.Backends.Backend
  alias Prima.LocusBackends

  @pool "backends"

  # The keeper answers a pool read within its own 5 s; this bound covers a
  # launcher that never answers at all.
  @pool_timeout_ms 6_000
  # A home's making, measuring, reset or retirement is the launcher's work
  # as the home's own uid, which may take it up to 120 s.
  @home_timeout_ms 130_000
  @status_timeout_ms 5_000
  @stop_grace_ms 2_000
  @measure_interval_ms 10_000
  @call_timeout_ms 120_000
  # An open may make and measure a kept home before its process starts.
  @open_timeout_ms 300_000

  @typedoc "An owner as a message names it: its athanor and server row."
  @type key :: {String.t(), String.t()}

  # ————— the interface —————

  @doc """
  Starts the table. Options: `:name`; `:boot` (a lifetime minted here by
  default); `:launcher` and `:launcher_server` (`Locus.Executor.executor/0`'s
  by default); `:supervisor`, the `DynamicSupervisor` sessions start
  under; `:clock`, the milliseconds leases, crashes and idle periods are
  read on (monotonic by default); `:memory_bytes` (`Locus.Config`'s by
  default), the bound of a program that names none; `:memory_budget` and
  `:overcommit` (`Locus.Config`'s by default), the box's `B` and `F`;
  `:cpu_quota` (`Locus.Config.backends_cpu_quota/0` by default), every
  session's CPU; `:ledger`, the name its sessions' heir tags carry, which
  a restarted table adopts back (its `:name`, else its own); `:stop_grace_ms`;
  `:pool_timeout_ms`; `:status_timeout_ms`; `:measure_interval_ms`;
  `:bounds`, overriding `Prima.LocusBackends`' `restart_backoff_ms`,
  `crash_window_ms` and `max_crashes`; and `:session_opts`, more options
  for every session.
  """
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "The service's lifetime: the id every answer names."
  @spec boot(GenServer.server()) :: String.t()
  def boot(server \\ __MODULE__), do: GenServer.call(server, :boot)

  @doc "Whether a control message at `(generation, seq)` is above every one applied."
  @spec fresh(GenServer.server(), %{generation: pos_integer(), seq: non_neg_integer()}) ::
          :ok | {:error, :stale_control}
  def fresh(server \\ __MODULE__, %{generation: generation, seq: seq}),
    do: GenServer.call(server, {:fresh, {generation, seq}})

  @doc """
  Applies a control message whose header carried `fields`, after every one
  that arrived before it. `open_env`, for a sync, answers the sync's
  opened environment (`{:ok, %{program => %{name => value}}}` or `:error`)
  and is called only for a version not yet held.
  """
  @spec control(
          GenServer.server(),
          map(),
          LocusBackends.control_message(),
          (-> {:ok, map()} | :error) | nil
        ) :: {:ok, LocusBackends.answer()} | {:error, LocusBackends.code()}
  def control(server \\ __MODULE__, fields, message, open_env \\ nil) do
    GenServer.call(server, {:control, fields, message, open_env}, @call_timeout_ms)
  catch
    :exit, _reason -> {:error, :internal}
  end

  @doc "Whether the owner a session message's header names runs at exactly its version, or the refusal."
  @spec admit(GenServer.server(), map()) :: :ok | {:error, LocusBackends.code()}
  def admit(server \\ __MODULE__, %{athanor: _, server: _, generation: _, epoch: _} = invoke),
    do: GenServer.call(server, {:admit, invoke})

  @doc "Opens a session as `message` asks, for the owner `invoke` names."
  @spec open(GenServer.server(), map(), map()) ::
          {:ok, %{status: :running, session: String.t(), resumed: boolean(), pty: boolean()}}
          | {:error, LocusBackends.code()}
  def open(server \\ __MODULE__, invoke, message) do
    GenServer.call(server, {:open, invoke, message}, @open_timeout_ms)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc "The session `id` of the owner `invoke` names: its process and the owner's secrets."
  @spec session(GenServer.server(), map(), String.t()) ::
          {:ok, pid() | nil, [String.t()]} | {:error, LocusBackends.code()}
  def session(server \\ __MODULE__, invoke, id),
    do: GenServer.call(server, {:session, invoke, id})

  @doc """
  Retires every owner whose lease has passed, asks every running session
  of the rest to end if no send and no recv used it within its owner's
  idle period, and measures every capped kept home a session runs in
  whose interval has passed.
  """
  @spec sweep(GenServer.server()) :: :ok
  def sweep(server \\ __MODULE__), do: GenServer.call(server, :sweep)

  # ————— the server —————

  @impl GenServer
  def init(opts) do
    with {:ok, launcher} <- launcher(opts) do
      state = %{
        boot: Keyword.get_lazy(opts, :boot, &mint_boot/0),
        launcher: launcher,
        launcher_server: Keyword.get(opts, :launcher_server, launcher),
        supervisor: Keyword.get(opts, :supervisor, Locus.Backends.BackendSupervisor),
        clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
        memory_bytes:
          Keyword.get_lazy(opts, :memory_bytes, &Locus.Config.backends_memory_bytes/0),
        memory: memory(opts),
        cpu_quota: Keyword.get_lazy(opts, :cpu_quota, &Locus.Config.backends_cpu_quota/0),
        stop_grace_ms: Keyword.get(opts, :stop_grace_ms, @stop_grace_ms),
        pool_timeout_ms: Keyword.get(opts, :pool_timeout_ms, @pool_timeout_ms),
        status_timeout_ms: Keyword.get(opts, :status_timeout_ms, @status_timeout_ms),
        measure_interval_ms: Keyword.get(opts, :measure_interval_ms, @measure_interval_ms),
        session_opts: Keyword.get(opts, :session_opts, []),
        bounds:
          Map.merge(
            Map.take(LocusBackends.bounds(), [
              :restart_backoff_ms,
              :crash_window_ms,
              :max_crashes
            ]),
            Map.new(Keyword.get(opts, :bounds, []))
          ),
        high_water: {0, 0},
        owners: %{},
        routes: %{},
        pids: %{},
        homes: %{},
        homes_checked_at: nil,
        # The sessions whose process this table no longer follows but whose
        # end the launcher has not confirmed: {owner id, session id} =>
        # their heir tag and whether their fence is :unasked, :asking or
        # :pending.
        ending: %{},
        ledger: Keyword.get_lazy(opts, :ledger, fn -> Keyword.get(opts, :name, make_ref()) end),
        adopted: false,
        adopting: false,
        queue: :queue.new(),
        busy: nil,
        pending: %{},
        drainers: %{}
      }

      {:ok, adopt_at_start(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # What the launcher still holds for this ledger, asked once before the
  # table answers anything, within the launcher's own bound; unanswered,
  # the table admits nothing and asks again at each sweep.
  defp adopt_at_start(state) do
    {launcher, server} = session_launcher(state)

    case launcher.adopt(server, state.ledger, self()) do
      {:ok, tags} when is_list(tags) -> adopted(state, tags)
      _failed -> state
    end
  catch
    :exit, _reason -> state
  end

  defp launcher(opts) do
    case Keyword.fetch(opts, :launcher) do
      {:ok, launcher} -> {:ok, launcher}
      :error -> Locus.Executor.executor()
    end
  end

  defp mint_boot, do: "bb_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  # The box's budget `B` and its admission limit, `floor(B * F)`.
  defp memory(opts) do
    budget = Keyword.get_lazy(opts, :memory_budget, &Locus.Config.backends_memory_budget/0)

    overcommit = Keyword.get_lazy(opts, :overcommit, &Locus.Config.backends_memory_overcommit/0)

    %{
      budget_bytes: budget,
      admission_limit_bytes: Locus.Config.admission_limit_bytes(budget, overcommit)
    }
  end

  @impl GenServer
  def handle_call(:boot, _from, state), do: {:reply, state.boot, state}

  def handle_call({:fresh, version}, _from, state) do
    if version > state.high_water,
      do: {:reply, :ok, state},
      else: {:reply, {:error, :stale_control}, state}
  end

  def handle_call({:control, fields, message, open_env}, from, state) do
    state = %{state | queue: :queue.in({from, fields, message, open_env}, state.queue)}
    {:noreply, next_control(state)}
  end

  def handle_call({:admit, invoke}, _from, state) do
    case admit_owner(state, invoke) do
      {:ok, _owner, state} -> {:reply, :ok, state}
      {:error, code, state} -> {:reply, {:error, code}, state}
    end
  end

  def handle_call({:open, invoke, message}, from, state) do
    case admit_owner(state, invoke) do
      {:ok, owner, state} -> open_session(state, owner, message, from)
      {:error, code, state} -> {:reply, {:error, code}, state}
    end
  end

  def handle_call({:session, invoke, id}, _from, state) do
    case admit_owner(state, invoke) do
      {:ok, owner, state} ->
        case Map.fetch(owner.sessions, id) do
          {:ok, session} -> {:reply, {:ok, session.pid, owner.secrets}, state}
          :error -> {:reply, {:error, :unknown_session}, state}
        end

      {:error, code, state} ->
        {:reply, {:error, code}, state}
    end
  end

  def handle_call(:sweep, _from, state), do: {:reply, :ok, sweep_owners(state)}

  @impl GenServer
  def handle_info({:done, ref, result}, state) do
    case Map.pop(state.pending, ref) do
      {nil, _pending} ->
        {:noreply, state}

      {entry, pending} ->
        Process.demonitor(entry.monitor, [:flush])
        Process.cancel_timer(entry.timer)
        {:noreply, continue(%{state | pending: pending}, entry.continuation, result)}
    end
  end

  def handle_info({:pending_timeout, ref}, state) do
    case Map.pop(state.pending, ref) do
      {nil, _pending} ->
        {:noreply, state}

      {entry, pending} ->
        Process.demonitor(entry.monitor, [:flush])
        Process.exit(entry.pid, :kill)
        {:noreply, continue(%{state | pending: pending}, entry.continuation, {:error, :timeout})}
    end
  end

  def handle_info({Backend, pid, event}, state), do: {:noreply, on_session(state, pid, event)}

  # The launcher, as a spawn's heir: nothing of that session's process is
  # left.
  def handle_info(
        {_launcher, {:heir, %{session: {owner_id, session_id} = key}}, :released},
        state
      ) do
    state = %{state | ending: Map.delete(state.ending, key)}

    state =
      with {:ok, owner} <- Map.fetch(state.owners, owner_id),
           {:ok, session} <- Map.fetch(owner.sessions, session_id) do
        put_session(state, owner, session_id, %{session | gone: true, held: false})
      else
        _ -> state
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    cond do
      Map.has_key?(state.drainers, monitor) ->
        {id, drainers} = Map.pop(state.drainers, monitor)
        {:noreply, drained(%{state | drainers: drainers}, id)}

      Map.has_key?(state.pids, pid) ->
        {:noreply, session_down(state, pid)}

      ref = pending_by_monitor(state, monitor) ->
        {entry, pending} = Map.pop(state.pending, ref)
        Process.cancel_timer(entry.timer)
        {:noreply, continue(%{state | pending: pending}, entry.continuation, {:error, :down})}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(message, state) do
    Prima.LoggerContext.unexpected(__MODULE__, message)
    {:noreply, state}
  end

  # An owner's environment and secret values are credentials, and so is
  # work pending on a sync: no status or crash report shows more of them
  # than their count, or the kind of work pending.
  @impl GenServer
  def format_status(status) do
    Map.new(status, fn
      {:state, %{owners: owners, pending: pending} = state} ->
        {:state,
         %{
           state
           | owners: Map.new(owners, fn {id, owner} -> {id, redacted(owner)} end),
             pending: Map.new(pending, fn {ref, entry} -> {ref, elem(entry.continuation, 0)} end)
         }}

      other ->
        other
    end)
  end

  defp redacted(owner) do
    %{
      owner
      | secrets: {:redacted, length(owner.secrets)},
        env: Map.new(owner.env, fn {name, block} -> {name, {:redacted, map_size(block)}} end)
    }
  end

  # ————— control, one at a time —————

  defp next_control(%{busy: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, {from, fields, message, open_env}}, queue} ->
        state = %{state | queue: queue}
        version = {fields.generation, fields.seq}

        if version > state.high_water do
          case apply_control(%{state | high_water: version}, from, fields, message, open_env) do
            {:reply, reply, state} ->
              GenServer.reply(from, reply)
              next_control(state)

            {:wait, ref, state} ->
              %{state | busy: ref}
          end
        else
          GenServer.reply(from, {:error, :stale_control})
          next_control(state)
        end

      {:empty, _queue} ->
        state
    end
  end

  defp next_control(state), do: state

  defp control_done(state), do: next_control(%{state | busy: nil})

  defp apply_control(state, from, fields, %{type: :hello} = message, _open_env) do
    if message.g == fields.generation and message.cyfr_boot == fields.cyfr_boot do
      Logger.info(
        "[Locus.Backends.Owners] hello from #{message.cyfr_boot} at generation #{message.g}"
      )

      {ref, state} = read_pool(state, {:hello, from})
      {:wait, ref, state}
    else
      {:reply, {:error, :bad_request}, state}
    end
  end

  defp apply_control(state, _from, fields, %{type: :reconcile, keep: keep}, _open_env) do
    kept = Map.new(keep, &{{&1.athanor, &1.server}, &1.e})
    g = fields.generation

    retired =
      state.routes
      |> Enum.map(fn {key, id} -> {key, Map.fetch!(state.owners, id)} end)
      |> Enum.reject(fn {key, owner} ->
        owner.state == :draining or (owner.g == g and Map.get(kept, key) == owner.e)
      end)
      |> Enum.map(&elem(&1, 1))

    {:reply, {:ok, %{released: Enum.map(retired, &version/1)}}, retire_all(state, retired)}
  end

  defp apply_control(state, _from, fields, %{type: :release, owners: entries}, _open_env) do
    g = fields.generation

    retired =
      entries
      |> Enum.map(&routed(state, {&1.athanor, &1.server}))
      |> Enum.zip(entries)
      |> Enum.filter(fn {owner, entry} ->
        owner != nil and owner.state != :draining and {owner.g, owner.e} <= {g, entry.e}
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq_by(& &1.id)

    {:reply, {:ok, %{released: Enum.map(retired, &version/1)}}, retire_all(state, retired)}
  end

  defp apply_control(state, _from, fields, %{type: :renew} = message, _open_env) do
    now = state.clock.()
    g = fields.generation

    {renewed, unknown, state} =
      Enum.reduce(message.owners, {[], [], state}, fn entry, {renewed, unknown, state} ->
        ref = %{athanor: entry.athanor, server: entry.server, e: entry.e}

        case routed(state, {entry.athanor, entry.server}) do
          %{state: :running, g: ^g, e: e} = owner
          when e == entry.e and owner.lease_until > now ->
            owner = %{owner | lease_until: now + message.lease_ms}
            {[Map.put(ref, :state, owner.state) | renewed], unknown, put_owner(state, owner)}

          _other ->
            {renewed, [ref | unknown], state}
        end
      end)

    {:reply, {:ok, %{renewed: Enum.reverse(renewed), unknown: Enum.reverse(unknown)}}, state}
  end

  defp apply_control(state, from, _fields, %{type: :status, owners: entries}, _open_env) do
    now = state.clock.()

    snapshots =
      entries
      |> Enum.map(&routed(state, {&1.athanor, &1.server}))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&snapshot(state, &1, now))

    {ref, state} = gather(state, from, snapshots)
    {:wait, ref, state}
  end

  defp apply_control(state, _from, fields, %{type: :sync} = message, open_env) do
    key = {message.owner.athanor, message.owner.server}
    version = {fields.generation, message.e}
    definition = definition(message.programs)
    existing = routed(state, key)

    case existing && compare(version, existing, definition) do
      :stale ->
        {:reply, {:error, :stale_epoch}, state}

      :conflict ->
        {:reply, {:error, :conflict}, state}

      :draining ->
        {:reply, {:error, :lapsed}, state}

      :held ->
        owner = %{
          existing
          | lease_until: state.clock.() + message.lease_ms,
            idle_ms: message.idle_ms,
            athanor_memory_bytes: Map.get(message, :athanor_memory_bytes)
        }

        {:reply, {:ok, sync_answer(state, owner)}, put_owner(state, owner)}

      _new ->
        admit_sync(state, message, version, definition, existing, open_env)
    end
  end

  defp apply_control(state, from, _fields, %{type: :homes}, _open_env) do
    %{launcher: launcher, launcher_server: server} = state

    {ref, state} =
      run(state, {:homes, from}, @home_timeout_ms, fn -> home_list(launcher, server) end)

    {:wait, ref, state}
  end

  defp apply_control(state, from, _fields, %{type: :home} = message, _open_env) do
    pids =
      for {_id, owner} <- state.owners,
          owner.athanor == message.athanor,
          {_sid, %{home_id: home_id, pid: pid}} <- owner.sessions,
          home_id == message.home_id,
          pid != nil,
          do: pid

    home = Map.get(state.homes, message.home_id, new_home())
    state = %{state | homes: Map.put(state.homes, message.home_id, %{home | busy: true})}
    %{launcher: launcher, launcher_server: server, stop_grace_ms: grace_ms} = state

    {ref, state} =
      run(state, {:home, from, message}, @home_timeout_ms + grace_ms + 30_000, fn ->
        stop_all(pids, nil, grace_ms)

        case message.op do
          :reset -> launcher.home_reset(server, message.home_id)
          :retire -> launcher.home_retire(server, message.home_id)
        end
      end)

    {:wait, ref, state}
  end

  defp compare(version, owner, definition) do
    cond do
      version < {owner.g, owner.e} -> :stale
      version > {owner.g, owner.e} -> :newer
      owner.definition != definition -> :conflict
      owner.state == :draining -> :draining
      true -> :held
    end
  end

  # A version not held: its environment opened and checked against its
  # definitions; the version it replaces is retired on admission.
  defp admit_sync(state, message, {g, e}, definition, existing, open_env) do
    with true <- length(definition) <= LocusBackends.max_programs() || :error,
         {:ok, env} <- open(open_env),
         :ok <- environment(definition, env) do
      state = if existing, do: retire(state, existing), else: state
      owner = new_owner(state, message, {g, e}, definition, env)

      state = %{
        state
        | owners: Map.put(state.owners, owner.id, owner),
          routes: Map.put(state.routes, {owner.athanor, owner.server}, owner.id)
      }

      {:reply, {:ok, sync_answer(state, owner)}, state}
    else
      :error -> {:reply, {:error, :bad_request}, state}
    end
  end

  defp open(open_env) when is_function(open_env, 0) do
    case open_env.() do
      {:ok, %{} = env} -> {:ok, env}
      _ -> :error
    end
  end

  defp open(_open_env), do: :error

  # The definitions as they are compared: each program's variable names
  # sorted, the programs in the order the sync named them.
  defp definition(programs),
    do: Enum.map(programs, &%{&1 | env_names: Enum.sort(&1.env_names)})

  # The opened environment names exactly the programs, each block exactly
  # its program's variables, every value a string.
  defp environment(definition, env) do
    names = definition |> Enum.map(& &1.name) |> Enum.sort()

    exact? =
      Enum.sort(Map.keys(env)) == names and
        Enum.all?(definition, fn %{name: name, env_names: env_names} ->
          case env[name] do
            %{} = block ->
              Enum.sort(Map.keys(block)) == env_names and
                Enum.all?(Map.values(block), &is_binary/1)

            _ ->
              false
          end
        end)

    if exact?, do: :ok, else: :error
  end

  # ————— continuations —————

  defp continue(state, {:hello, from}, result) do
    reply =
      case pool(result) do
        {:ok, pool} ->
          {:ok,
           %{
             boot: state.boot,
             pool: %{size: pool.size, free: pool.free},
             memory: memory_report(state)
           }}

        :error ->
          {:error, :unavailable}
      end

    GenServer.reply(from, reply)
    control_done(state)
  end

  defp continue(state, {:status, from}, {:ok, owners}) do
    GenServer.reply(from, {:ok, %{owners: owners, memory: memory_report(state)}})
    control_done(state)
  end

  defp continue(state, {:status, from}, _result) do
    GenServer.reply(from, {:error, :internal})
    control_done(state)
  end

  defp continue(state, {:home, from, message}, result) do
    home = Map.get(state.homes, message.home_id, new_home())

    {reply, homes} =
      case {message.op, result} do
        {:reset, :ok} ->
          {{:ok, %{home_id: message.home_id, state: :empty}},
           Map.put(state.homes, message.home_id, new_home())}

        {:retire, :ok} ->
          {{:ok, %{home_id: message.home_id, state: :absent}},
           Map.delete(state.homes, message.home_id)}

        {_op, _failed} ->
          {{:error, :unavailable}, Map.put(state.homes, message.home_id, %{home | busy: false})}
      end

    GenServer.reply(from, reply)
    control_done(%{state | homes: homes})
  end

  defp continue(state, {:open, from, ask}, result), do: opened(state, from, ask, result)

  defp continue(state, {:fenced, key}, result) do
    case {state.ending[key], result} do
      {nil, _result} -> state
      {_ending, :none} -> %{state | ending: Map.delete(state.ending, key)}
      {ending, :pending} -> put_in(state.ending[key], %{ending | fence: :pending})
      {ending, _failed} -> put_in(state.ending[key], %{ending | fence: :unasked})
    end
  end

  defp continue(state, :adopted, {:ok, tags}) when is_list(tags), do: adopted(state, tags)
  defp continue(state, :adopted, _failed), do: %{state | adopting: false}

  defp continue(state, {:measured, home_id}, result), do: measured(state, home_id, result)

  defp continue(state, {:homes, from}, result) do
    reply =
      case result do
        {:ok, ids} when is_list(ids) -> {:ok, %{homes: Enum.sort(ids)}}
        _failed -> {:error, :unavailable}
      end

    GenServer.reply(from, reply)
    control_done(state)
  end

  defp continue(state, {:present, running}, {:ok, ids}) when is_list(ids) do
    listed = MapSet.new(ids)

    Enum.reduce(running, state, fn home_id, state ->
      if MapSet.member?(listed, home_id) do
        state
      else
        Logger.warning(
          "[Locus.Backends.Owners] a kept home's folder is gone; ending its sessions"
        )

        end_home(state, home_id, "home_absent")
      end
    end)
  end

  # A list that did not answer tells nothing of any home: the next interval
  # asks again.
  defp continue(state, {:present, _running}, _failed), do: state

  defp pool({:ok, %{size: size, free: free, quarantined: quarantined} = pool})
       when is_integer(size) and size >= 0 and is_integer(free) and free >= 0 and
              is_integer(quarantined) and quarantined >= 0,
       do: {:ok, pool}

  defp pool(_result), do: :error

  # The uids a session may hold: every uid of the pool not quarantined.
  defp capacity(%{size: size, quarantined: quarantined}), do: size - quarantined

  # ————— opening a session —————

  defp open_session(state, owner, message, from) do
    case Enum.find(owner.definition, &(&1.name == message.program)) do
      nil -> {:reply, {:error, :unknown_program}, state}
      program -> open_program(state, owner, program, message, from)
    end
  end

  defp open_program(state, owner, program, message, from) do
    ask = %{
      owner: owner.id,
      athanor: owner.athanor,
      program: program.name,
      home_id: message.home_id,
      key: {program.name, message.home_id, message.key, message.mode},
      mode: message.mode,
      argv: message.argv,
      memory_bytes: program.memory_bytes || state.memory_bytes
    }

    with :ok <- shape(program, message),
         :ok <- not_failed(owner, program, ask.key),
         :error <- running(owner, ask.key),
         :ok <- home_open(state, message.home_id),
         :ok <- memory_room(state, owner, ask.memory_bytes),
         {:ok, admitted} <- room(state, owner) do
      state = put_owner(state, admitted)
      %{launcher: launcher, launcher_server: server} = state

      case program.home do
        :kept ->
          cap = program.home_max_bytes
          state = put_home(state, message.home_id, &%{&1 | athanor: admitted.athanor, cap: cap})

          {_ref, state} =
            run(state, {:open, from, ask}, @home_timeout_ms * 2, fn ->
              kept_ready(launcher, server, message.home_id, cap)
            end)

          {:noreply, state}

        :scratch ->
          {_ref, state} = read_pool(state, {:open, from, ask})
          {:noreply, state}
      end
    else
      {:ok, session_id} ->
        session = owner.sessions[session_id]
        {:reply, {:ok, opened_answer(session_id, true, session.mode)}, state}

      {:error, code} ->
        {:reply, {:error, code}, state}
    end
  end

  # A kept program's sessions need a home, and a scratch one's none; a
  # sign-in runs a login command in a kept home.
  defp shape(%{home: :kept}, %{home_id: nil}), do: {:error, :bad_request}

  defp shape(%{home: :scratch}, %{home_id: home_id}) when home_id != nil,
    do: {:error, :bad_request}

  defp shape(%{home: :scratch}, %{mode: :sign_in}), do: {:error, :bad_request}
  defp shape(%{login_command: nil}, %{mode: :sign_in}), do: {:error, :bad_request}
  defp shape(_program, %{mode: :sign_in, argv: [_ | _]}), do: {:error, :bad_request}
  defp shape(_program, _message), do: :ok

  defp not_failed(owner, program, key) do
    if MapSet.member?(owner.programs[program.name].failed_keys, key),
      do: {:error, :program_failed},
      else: :ok
  end

  defp running(owner, key) do
    with {:ok, session_id} <- Map.fetch(owner.keys, key),
         %{running: true} <- owner.sessions[session_id] do
      {:ok, session_id}
    else
      _ -> :error
    end
  end

  defp home_open(_state, nil), do: :ok

  defp home_open(state, home_id) do
    case state.homes[home_id] do
      %{over_cap: true} -> {:error, :home_over_cap}
      %{busy: true} -> {:error, :unavailable}
      _ -> :ok
    end
  end

  # Room for one more session: the oldest ended one forgotten if the owner
  # holds its bound, `capacity` with every one of them running. A session
  # whose process is still going holds its place until it is gone.
  defp room(state, owner) do
    if map_size(owner.sessions) < LocusBackends.max_sessions() do
      {:ok, owner}
    else
      oldest =
        owner.sessions
        |> Enum.filter(fn {_id, session} -> not session.running and not session.held end)
        |> Enum.min_by(fn {_id, session} -> session.opened end, fn -> nil end)

      case oldest do
        nil ->
          {:error, :capacity}

        {id, session} ->
          if session.pid, do: forget(state, session.pid)
          {:ok, %{owner | sessions: Map.delete(owner.sessions, id)}}
      end
    end
  end

  # Room for `requested` more bytes: within the box's admission limit, and
  # within the ceiling of the owner's athanor over every owner of it here.
  # Until the launcher has answered what it still holds for this ledger,
  # nothing is known to be free.
  defp memory_room(%{adopted: false}, _owner, _requested), do: {:error, :unavailable}

  defp memory_room(state, owner, requested) do
    ceiling = owner.athanor_memory_bytes || state.memory.budget_bytes

    if held_bytes(state, & &1) + requested <= state.memory.admission_limit_bytes and
         held_bytes(state, &(&1 == owner.athanor)) + requested <= ceiling,
       do: :ok,
       else: {:error, :capacity}
  end

  # The bytes reserved by the athanors `athanor?` takes: every session
  # whose process is not yet gone, every open being prepared and every
  # ending.
  defp held_bytes(state, athanor?) do
    sessions =
      for {_id, owner} <- state.owners,
          athanor?.(owner.athanor),
          {_sid, %{held: true, memory_bytes: bytes}} <- owner.sessions,
          reduce: 0,
          do: (sum -> sum + bytes)

    pending =
      for {_ref, %{continuation: {:open, _from, ask}}} <- state.pending,
          athanor?.(ask.athanor),
          reduce: sessions,
          do: (sum -> sum + ask.memory_bytes)

    for {_key, %{tag: tag}} <- state.ending,
        athanor?.(tag.athanor),
        reduce: pending,
        do: (sum -> sum + tag.memory_bytes)
  end

  defp memory_report(state), do: Map.put(state.memory, :held_bytes, held_bytes(state, & &1))

  defp forget(state, pid) do
    DynamicSupervisor.terminate_child(state.supervisor, pid)
  catch
    :exit, _reason -> :ok
  end

  # Run in a process of its own: a kept home made if it is absent, and
  # measured against its bound when it has one.
  defp kept_ready(launcher, server, home_id, cap) do
    with {:ok, _uid} <- launcher.home_ensure(server, home_id),
         :ok <- under_cap(launcher, server, home_id, cap) do
      :kept
    end
  end

  defp under_cap(_launcher, _server, _home_id, nil), do: :ok

  defp under_cap(launcher, server, home_id, cap) do
    case launcher.home_measure(server, home_id) do
      {:ok, bytes} when bytes >= cap -> {:over_cap, bytes}
      {:ok, _bytes} -> :ok
      other -> other
    end
  end

  # The open's work done: the session started, or the refusal.
  defp opened(state, from, ask, result) do
    with {:ok, owner} <- still_open(state, ask),
         program = Enum.find(owner.definition, &(&1.name == ask.program)),
         :ok <- claimed(state, program, ask, result) do
      case running(owner, ask.key) do
        {:ok, session_id} ->
          GenServer.reply(from, {:ok, opened_answer(session_id, true, ask.mode)})
          state

        :error ->
          start_session(state, owner, program, ask, from)
      end
    else
      {:error, code, state} ->
        GenServer.reply(from, {:error, code})
        state

      {:error, code} ->
        GenServer.reply(from, {:error, code})
        state
    end
  end

  defp still_open(state, ask) do
    case Map.fetch(state.owners, ask.owner) do
      {:ok, %{state: :running} = owner} -> {:ok, owner}
      _gone -> {:error, :lapsed}
    end
  end

  # A scratch session's uid of the pool, claimed in this step; a kept
  # session's home ready under its bound.
  defp claimed(state, %{home: :scratch}, _ask, result) do
    case pool(result) do
      {:ok, pool} ->
        if slots_held(state) + 1 > capacity(pool),
          do: {:error, :capacity},
          else: :ok

      :error ->
        {:error, :unavailable}
    end
  end

  defp claimed(state, %{home: :kept}, ask, result) do
    case result do
      :kept ->
        :ok

      {:over_cap, bytes} ->
        {:error, :home_over_cap,
         put_home(state, ask.home_id, &%{&1 | bytes: bytes, over_cap: true})}

      {:error, {:refused, "capacity"}} ->
        {:error, :capacity}

      _failed ->
        {:error, :unavailable}
    end
  end

  defp start_session(state, owner, program, ask, from) do
    session_id = "ss_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    record = owner.programs[program.name]

    opts =
      [
        owner: %{athanor: owner.athanor, server: owner.server, g: owner.g, e: owner.e},
        session: session_id,
        program: program.name,
        spec: spec(state, owner, program, ask, session_id),
        secrets: owner.secrets,
        launcher: state.launcher,
        launcher_server: state.launcher_server,
        notify: self(),
        delay_ms: backoff(state, Map.get(record.crashes, ask.key, [])),
        stop_grace_ms: state.stop_grace_ms,
        clock: state.clock
      ]
      |> Keyword.merge(state.session_opts)

    case DynamicSupervisor.start_child(state.supervisor, {Backend, opts}) do
      {:ok, pid} ->
        Process.monitor(pid)

        session = %{
          pid: pid,
          program: program.name,
          key: ask.key,
          home_id: ask.home_id,
          mode: ask.mode,
          running: true,
          started: false,
          held: true,
          gone: false,
          memory_bytes: ask.memory_bytes,
          opened: System.unique_integer([:monotonic]),
          waiting: [from]
        }

        owner = %{
          owner
          | sessions: Map.put(owner.sessions, session_id, session),
            keys: Map.put(owner.keys, ask.key, session_id),
            programs:
              Map.put(owner.programs, program.name, %{
                record
                | last: session_id,
                  homes:
                    if(ask.home_id, do: MapSet.put(record.homes, ask.home_id), else: record.homes)
              })
        }

        %{state | pids: Map.put(state.pids, pid, {owner.id, session_id})} |> put_owner(owner)

      {:error, _reason} ->
        Logger.error(
          "[Locus.Backends.Owners] #{owner.athanor}/#{owner.server} #{program.name}: " <>
            "a session did not start"
        )

        GenServer.reply(from, {:error, :internal})
        state
    end
  end

  # What a session's process runs: a run's command with the open's
  # arguments as its own, `"$@"` (the administrator allowed the program;
  # its arguments shape only what runs inside its box), or a sign-in's
  # login command on a pseudo-terminal.
  defp spec(state, owner, program, ask, session_id) do
    argv =
      case ask.mode do
        :run -> ["/bin/sh", "-c", program.command <> " \"$@\"", "sh" | ask.argv]
        :sign_in -> ["/bin/sh", "-c", program.login_command]
      end

    %{
      argv: argv,
      env: Map.fetch!(owner.env, program.name),
      pool: @pool,
      memory_bytes: ask.memory_bytes,
      cpu_quota: state.cpu_quota,
      heir: {self(), heir_tag(state, owner, session_id, ask)}
    }
    |> put_given(:home, ask.home_id)
    |> put_given(:home_max_bytes, program.home_max_bytes)
    |> put_given(:pty, if(ask.mode == :sign_in, do: true))
    |> put_given(:hosts, program.hosts)
  end

  defp put_given(map, _key, nil), do: map
  defp put_given(map, key, value), do: Map.put(map, key, value)

  # The wait before a program's next process after its crashes: the
  # backoff's wait for their count, less the time since the last.
  defp backoff(_state, []), do: 0

  defp backoff(state, [last | _] = crashes) do
    waits = state.bounds.restart_backoff_ms
    wait = Enum.at(waits, min(length(crashes), length(waits)) - 1)
    max(wait - (state.clock.() - last), 0)
  end

  defp opened_answer(session_id, resumed?, mode),
    do: %{status: :running, session: session_id, resumed: resumed?, pty: mode == :sign_in}

  # ————— what sessions report —————

  defp on_session(state, pid, event) do
    case locate(state, pid) do
      {:ok, owner, session_id, session} -> session_event(state, owner, session_id, session, event)
      :error -> state
    end
  end

  defp session_event(state, owner, session_id, session, :started) do
    Enum.each(
      session.waiting,
      &GenServer.reply(&1, {:ok, opened_answer(session_id, false, session.mode)})
    )

    put_session(state, owner, session_id, %{session | started: true, waiting: []})
  end

  defp session_event(state, owner, session_id, session, {:ended, ended}) do
    refusal =
      if String.contains?(ended.error || "", "home_over_cap"),
        do: :home_over_cap,
        else: spawn_refusal(ended)

    Enum.each(session.waiting, &GenServer.reply(&1, {:error, refusal}))
    session = %{session | running: false, waiting: []}
    state = put_session(state, owner, session_id, session)
    owner = Map.fetch!(state.owners, owner.id)
    if ended.crash, do: crashed(state, owner, session, ended.error), else: state
  end

  defp session_event(state, owner, session_id, session, :vacated),
    do: put_session(state, owner, session_id, %{session | held: false})

  defp session_event(state, _owner, _session_id, _session, _event), do: state

  defp spawn_refusal(%{error: "spawn refused: home_over_cap"}), do: :home_over_cap
  defp spawn_refusal(%{error: "spawn refused: capacity"}), do: :capacity
  defp spawn_refusal(%{error: "spawn refused: hosts_unresolved"}), do: :hosts_unresolved
  defp spawn_refusal(%{error: "spawn refused: guard_unavailable"}), do: :guard_unavailable
  defp spawn_refusal(_ended), do: :unavailable

  # A crash counts against its session's key within the window; the
  # window's last crash fails that key alone.
  defp crashed(state, owner, %{program: name, key: key}, error) do
    now = state.clock.()
    window = state.bounds.crash_window_ms
    record = owner.programs[name]
    crashes = [now | Enum.filter(Map.get(record.crashes, key, []), &(now - &1 < window))]
    failed? = length(crashes) >= state.bounds.max_crashes

    if failed?,
      do:
        Logger.error(
          "[Locus.Backends.Owners] #{owner.athanor}/#{owner.server} #{name}: " <>
            "a session key failed after #{length(crashes)} crashes"
        )

    failed_keys = if failed?, do: MapSet.put(record.failed_keys, key), else: record.failed_keys

    record = %{
      record
      | crashes: Map.put(record.crashes, key, crashes),
        restarts: record.restarts + 1,
        error: LocusBackends.mask(error, owner.secrets),
        failed_keys: failed_keys
    }

    put_owner(state, %{owner | programs: Map.put(owner.programs, name, record)})
  end

  # A session process that ended without saying so. If its launcher has not
  # said its process is gone, what the session holds moves to the endings
  # until the launcher says so.
  defp session_down(state, pid) do
    {{id, session_id}, pids} = Map.pop(state.pids, pid)
    state = %{state | pids: pids}

    case Map.fetch(state.owners, id) do
      {:ok, owner} ->
        case Map.fetch(owner.sessions, session_id) do
          {:ok, session} ->
            Enum.each(session.waiting, &GenServer.reply(&1, {:error, :internal}))
            running? = session.running
            state = end_unconfirmed(state, owner, session_id, session)
            session = %{session | pid: nil, running: false, held: false, waiting: []}
            state = put_session(state, owner, session_id, session)

            if running? and owner.state != :draining,
              do: crashed(state, Map.fetch!(state.owners, id), session, "session ended"),
              else: state

          :error ->
            state
        end

      :error ->
        state
    end
  end

  # ————— status —————

  defp gather(state, from, snapshots) do
    timeout = state.status_timeout_ms

    run(state, {:status, from}, timeout + 1_000, fn ->
      {:ok, Enum.map(snapshots, &report(&1, timeout))}
    end)
  end

  defp snapshot(state, owner, now) do
    programs =
      Enum.map(owner.definition, fn program ->
        record = owner.programs[program.name]
        sessions = for {_id, s} <- owner.sessions, s.program == program.name, s.running, do: s
        homes = Enum.map(record.homes, &Map.get(state.homes, &1, new_home()))
        last = record.last && owner.sessions[record.last]

        unadmittable = unadmittable(state, program)

        %{
          name: program.name,
          status:
            cond do
              MapSet.size(record.failed_keys) > 0 or unadmittable != nil -> :failed
              sessions != [] -> :running
              true -> :idle
            end,
          restarts: record.restarts,
          error: unadmittable || record.error,
          home: program.home,
          home_bytes: home_bytes(program.home, homes),
          over_cap: Enum.any?(homes, & &1.over_cap),
          sessions: length(sessions),
          last: last && last.pid
        }
      end)

    %{
      athanor: owner.athanor,
      server: owner.server,
      g: owner.g,
      e: owner.e,
      state: owner.state,
      lease_ms_left: max(0, owner.lease_until - now),
      programs: programs
    }
  end

  defp home_bytes(:scratch, _homes), do: nil

  defp home_bytes(:kept, homes) do
    case for(%{bytes: bytes} <- homes, bytes != nil, do: bytes) do
      [] -> nil
      measured -> Enum.sum(measured)
    end
  end

  # The stderr of each program's last session, asked at once, each within
  # the status bound; one that does not answer reports none. A scratch
  # program reports its masked tail; a kept one only its length, since a
  # kept session's stderr may carry its home's contents.
  defp report(snapshot, timeout) do
    programs =
      snapshot.programs
      |> Enum.map(fn program ->
        {program, Task.async(fn -> stderr(program.last, timeout) end)}
      end)
      |> Enum.map(fn {program, task} ->
        stderr =
          case Task.yield(task, timeout + 100) || Task.shutdown(task, :brutal_kill) do
            {:ok, stderr} -> stderr
            _ -> %{stderr_tail: "", stderr_bytes: 0}
          end

        program |> Map.delete(:last) |> Map.merge(stderr_of(program.home, stderr))
      end)

    %{snapshot | programs: programs}
  end

  defp stderr_of(:scratch, stderr),
    do: %{stderr_tail: stderr.stderr_tail || "", stderr_bytes: nil}

  defp stderr_of(:kept, stderr), do: %{stderr_tail: nil, stderr_bytes: stderr.stderr_bytes}

  defp stderr(nil, _timeout), do: %{stderr_tail: "", stderr_bytes: 0}

  defp stderr(pid, timeout) do
    Map.take(Backend.status(pid, timeout), [:stderr_tail, :stderr_bytes])
  catch
    :exit, _reason -> %{stderr_tail: "", stderr_bytes: 0}
  end

  # ————— work of its own, in processes of its own —————

  defp read_pool(state, continuation) do
    %{launcher: launcher, launcher_server: server} = state
    run(state, continuation, state.pool_timeout_ms, fn -> launcher.pool_stats(server, @pool) end)
  end

  defp run(state, continuation, timeout, fun) do
    ref = make_ref()
    owners = self()
    {pid, monitor} = spawn_monitor(fn -> send(owners, {:done, ref, fun.()}) end)
    timer = Process.send_after(self(), {:pending_timeout, ref}, timeout)
    entry = %{continuation: continuation, pid: pid, monitor: monitor, timer: timer}
    {ref, %{state | pending: Map.put(state.pending, ref, entry)}}
  end

  defp pending_by_monitor(state, monitor) do
    Enum.find_value(state.pending, fn {ref, entry} -> entry.monitor == monitor && ref end)
  end

  # ————— owners —————

  defp new_owner(state, message, {g, e}, definition, env) do
    %{
      id: make_ref(),
      athanor: message.owner.athanor,
      server: message.owner.server,
      g: g,
      e: e,
      definition: definition,
      env: env,
      secrets: secret_values(env),
      state: :running,
      lease_until: state.clock.() + message.lease_ms,
      idle_ms: message.idle_ms,
      athanor_memory_bytes: Map.get(message, :athanor_memory_bytes),
      programs:
        Map.new(definition, fn program ->
          {program.name,
           %{
             crashes: %{},
             restarts: 0,
             error: nil,
             failed_keys: MapSet.new(),
             last: nil,
             homes: MapSet.new()
           }}
        end),
      sessions: %{},
      keys: %{},
      drain_started: false
    }
  end

  # The values masked in everything an owner's sessions answer: every
  # value of its environment but the literal ones.
  defp secret_values(env) do
    literal = LocusBackends.literal_env_names()

    for {_program, block} <- env,
        {name, value} <- block,
        name not in literal,
        uniq: true,
        do: value
  end

  defp sync_answer(state, owner) do
    %{
      status: owner.state,
      programs:
        Enum.map(owner.definition, fn %{name: name} = program ->
          failed? =
            MapSet.size(owner.programs[name].failed_keys) > 0 or
              unadmittable(state, program) != nil

          %{name: name, status: if(failed?, do: :failed, else: :idle)}
        end)
    }
  end

  # Why a program can never be admitted on this box, or nil: its bound
  # alone is past the admission limit, so every open of it is `capacity`.
  # Its owner is told once, as the program's status and this sentence,
  # rather than reading busy on every retry.
  defp unadmittable(state, program) do
    bound = program.memory_bytes || state.memory_bytes
    limit = state.memory.admission_limit_bytes

    if bound > limit,
      do:
        "Its memory bound, #{size(bound)}, is above the #{size(limit)} this box admits: " <>
          "it cannot start here until its bound is lowered or the box's budget raised."
  end

  defp size(bytes) when rem(bytes, 1_048_576) == 0, do: "#{div(bytes, 1_048_576)} MiB"
  defp size(bytes), do: "#{bytes} bytes"

  defp version(owner), do: %{athanor: owner.athanor, server: owner.server, g: owner.g, e: owner.e}

  defp routed(state, key) do
    case Map.fetch(state.routes, key) do
      {:ok, id} -> Map.fetch!(state.owners, id)
      :error -> nil
    end
  end

  defp put_owner(state, owner), do: %{state | owners: Map.put(state.owners, owner.id, owner)}

  defp put_session(state, owner, session_id, session) do
    owner = Map.fetch!(state.owners, owner.id)
    put_owner(state, %{owner | sessions: Map.put(owner.sessions, session_id, session)})
  end

  defp locate(state, pid) do
    with {:ok, {id, session_id}} <- Map.fetch(state.pids, pid),
         {:ok, owner} <- Map.fetch(state.owners, id),
         {:ok, session} <- Map.fetch(owner.sessions, session_id) do
      {:ok, owner, session_id, session}
    else
      _ -> :error
    end
  end

  # The pool's uids held: a scratch session's (one with no home) until
  # nothing of its process is left, its ending's included.
  defp slots_held(state) do
    Enum.reduce(
      state.owners,
      map_size(Map.filter(state.ending, &(elem(&1, 1).tag.home_id == nil))),
      fn {_id, owner}, held ->
        held +
          Enum.count(owner.sessions, fn {_id, session} ->
            session.held and session.home_id == nil
          end)
      end
    )
  end

  # A held session whose process this table stops following before its
  # launcher said that process is gone: what it holds moves to the
  # endings, and the launcher is asked to fence it.
  defp end_unconfirmed(state, owner, session_id, %{held: true, gone: false} = session) do
    tag = heir_tag(state, owner, session_id, session)
    state = %{state | ending: Map.put(state.ending, tag.session, %{tag: tag, fence: :unasked})}
    ask_fence(state, tag.session)
  end

  defp end_unconfirmed(state, _owner, _session_id, _session), do: state

  # What a session's heir tag names: the ledger that may adopt it, the
  # session, and what it holds, so a table that adopts it holds the same.
  defp heir_tag(state, owner, session_id, session) do
    %{
      ledger: state.ledger,
      session: {owner.id, session_id},
      athanor: owner.athanor,
      memory_bytes: session.memory_bytes,
      home_id: session.home_id
    }
  end

  # The session launcher: the one a session's process is spawned through.
  defp session_launcher(state) do
    {Keyword.get(state.session_opts, :launcher, state.launcher),
     Keyword.get(state.session_opts, :launcher_server, state.launcher_server)}
  end

  defp ask_fence(state, key) do
    case state.ending[key] do
      %{fence: :unasked, tag: tag} = ending ->
        {launcher, server} = session_launcher(state)
        state = put_in(state.ending[key], %{ending | fence: :asking})

        {_ref, state} =
          run(state, {:fenced, key}, @pool_timeout_ms, fn -> launcher.fence(server, tag) end)

        state

      _asked ->
        state
    end
  end

  # What the launcher still holds for this ledger, adopted: each process
  # held as an ending its heir's word clears.
  defp adopted(state, tags) do
    ending =
      Enum.reduce(tags, state.ending, fn %{session: key} = tag, ending ->
        Map.put_new(ending, key, %{tag: tag, fence: :pending})
      end)

    %{state | ending: ending, adopted: true, adopting: false}
  end

  defp adopt(%{adopted: true} = state), do: state
  defp adopt(%{adopting: true} = state), do: state

  defp adopt(state) do
    {launcher, server} = session_launcher(state)
    ledger = state.ledger
    owners = self()

    {_ref, state} =
      run(state, :adopted, @pool_timeout_ms, fn -> launcher.adopt(server, ledger, owners) end)

    %{state | adopting: true}
  end

  defp unroute(state, owner) do
    key = {owner.athanor, owner.server}

    if Map.get(state.routes, key) == owner.id,
      do: %{state | routes: Map.delete(state.routes, key)},
      else: state
  end

  # ————— homes —————

  defp new_home,
    do: %{
      athanor: nil,
      cap: nil,
      over_cap: false,
      bytes: nil,
      busy: false,
      measuring: false,
      measured_at: nil,
      unmeasurable: false
    }

  defp put_home(state, home_id, fun),
    do: %{
      state
      | homes: Map.put(state.homes, home_id, fun.(Map.get(state.homes, home_id, new_home())))
    }

  # Every capped home a session runs in, measured once its interval has
  # passed, one measure at a time each.
  defp measure_homes(state) do
    now = state.clock.()

    running =
      for {_id, owner} <- state.owners,
          owner.state == :running,
          {_sid, %{running: true, home_id: home_id}} <- owner.sessions,
          home_id != nil,
          uniq: true,
          do: home_id

    Enum.reduce(running, state, fn home_id, state ->
      home = Map.get(state.homes, home_id, new_home())

      if home.cap != nil and not home.measuring and not home.over_cap and
           (home.measured_at == nil or now - home.measured_at >= state.measure_interval_ms) do
        %{launcher: launcher, launcher_server: server} = state
        state = put_home(state, home_id, &%{&1 | measuring: true})

        {_ref, state} =
          run(state, {:measured, home_id}, @home_timeout_ms, fn ->
            launcher.home_measure(server, home_id)
          end)

        state
      else
        state
      end
    end)
  end

  defp home_list(launcher, server) do
    if Code.ensure_loaded?(launcher) and function_exported?(launcher, :home_list, 1),
      do: launcher.home_list(server),
      else: {:error, :unavailable}
  end

  # Every running kept home, checked once an interval against the homes
  # the launcher lists, so a home whose folder vanished under its sessions
  # ends them.
  defp check_homes(state) do
    now = state.clock.()

    running =
      for {_id, owner} <- state.owners,
          owner.state == :running,
          {_sid, %{running: true, home_id: home_id}} <- owner.sessions,
          home_id != nil,
          uniq: true,
          do: home_id

    due? =
      state.homes_checked_at == nil or now - state.homes_checked_at >= state.measure_interval_ms

    if running != [] and due? do
      %{launcher: launcher, launcher_server: server} = state
      state = %{state | homes_checked_at: now}

      {_ref, state} =
        run(state, {:present, running}, @home_timeout_ms, fn -> home_list(launcher, server) end)

      state
    else
      state
    end
  end

  defp measured(state, home_id, result) do
    home = %{
      Map.get(state.homes, home_id, new_home())
      | measuring: false,
        measured_at: state.clock.()
    }

    case result do
      {:ok, bytes} when home.cap != nil and bytes >= home.cap ->
        Logger.warning(
          "[Locus.Backends.Owners] a kept home reached its bound; ending its sessions"
        )

        state = %{
          state
          | homes: Map.put(state.homes, home_id, %{home | bytes: bytes, over_cap: true})
        }

        end_home(state, home_id, "home_over_cap")

      {:ok, bytes} ->
        %{state | homes: Map.put(state.homes, home_id, %{home | bytes: bytes})}

      :absent ->
        Logger.warning(
          "[Locus.Backends.Owners] a kept home's folder is gone; ending its sessions"
        )

        state = %{state | homes: Map.put(state.homes, home_id, home)}
        end_home(state, home_id, "home_absent")

      # A home that cannot be measured whole is held to its cap all the
      # same: its sessions end and it is refused until a reset.
      _failed ->
        Logger.warning(
          "[Locus.Backends.Owners] a capped kept home could not be measured; ending its sessions"
        )

        state = %{
          state
          | homes: Map.put(state.homes, home_id, %{home | over_cap: true, unmeasurable: true})
        }

        end_home(state, home_id, "home_unmeasurable")
    end
  end

  defp end_home(state, home_id, reason) do
    for {_id, owner} <- state.owners,
        {_sid, %{running: true, home_id: ^home_id, pid: pid}} <- owner.sessions,
        pid != nil,
        do: Backend.end_session(pid, reason)

    state
  end

  # ————— retirement —————

  defp retire_all(state, owners), do: Enum.reduce(owners, state, &retire(&2, &1))

  # Leaves routing at once; its uids are held until its sessions stop.
  defp retire(state, owner), do: state |> unroute(owner) |> drain(owner.id)

  defp drain(state, id) do
    case Map.fetch!(state.owners, id) do
      %{drain_started: true} ->
        state

      owner ->
        state = put_owner(state, %{owner | state: :draining, drain_started: true})

        pids = for {_sid, %{pid: pid}} <- owner.sessions, pid != nil, do: pid

        for {_sid, session} <- owner.sessions,
            from <- session.waiting,
            do: GenServer.reply(from, {:error, :lapsed})

        %{supervisor: supervisor, stop_grace_ms: grace_ms} = state

        {_pid, monitor} = spawn_monitor(fn -> stop_all(pids, supervisor, grace_ms) end)

        %{state | drainers: Map.put(state.drainers, monitor, id)}
    end
  end

  # Every session stopped at once, each within its grace and its release
  # bound, then taken off the supervisor when one is named.
  defp stop_all(pids, supervisor, grace_ms) do
    pids
    |> Enum.map(fn pid -> Task.async(fn -> stop(pid, supervisor, grace_ms) end) end)
    |> Task.await_many(:infinity)
  end

  defp stop(pid, supervisor, grace_ms) do
    try do
      Backend.stop(pid, grace_ms)
    catch
      :exit, _reason -> :ok
    end

    if supervisor, do: DynamicSupervisor.terminate_child(supervisor, pid)
  catch
    :exit, _reason -> :ok
  end

  # An owner whose sessions are stopped leaves the table; a session of it
  # whose process its launcher has not yet said is gone stays held in the
  # endings.
  defp drained(state, id) do
    case Map.pop(state.owners, id) do
      {nil, _owners} ->
        state

      {owner, owners} ->
        state =
          Enum.reduce(owner.sessions, state, fn {session_id, session}, state ->
            end_unconfirmed(state, owner, session_id, session)
          end)

        pids =
          Enum.reduce(owner.sessions, state.pids, fn {_sid, session}, pids ->
            Map.delete(pids, session.pid)
          end)

        unroute(%{state | owners: owners, pids: pids}, owner)
    end
  end

  # ————— versions and the sweep —————

  defp admit_owner(state, %{generation: g, epoch: e} = invoke) do
    case routed(state, {invoke.athanor, invoke.server}) do
      nil ->
        {:error, :unknown_owner, state}

      owner ->
        cond do
          {g, e} < {owner.g, owner.e} -> {:error, :stale_epoch, state}
          {g, e} > {owner.g, owner.e} -> {:error, :epoch_ahead, state}
          owner.state == :draining -> {:error, :lapsed, state}
          owner.lease_until <= state.clock.() -> {:error, :lapsed, lapse(state, owner)}
          true -> {:ok, owner, state}
        end
    end
  end

  defp sweep_owners(state) do
    now = state.clock.()

    state =
      Enum.reduce(state.routes, state, fn {_key, id}, state ->
        owner = Map.fetch!(state.owners, id)

        cond do
          owner.state == :draining ->
            state

          owner.lease_until <= now ->
            lapse(state, owner)

          true ->
            for {_sid, %{running: true, pid: pid}} <- owner.sessions,
                pid != nil,
                do: Backend.retire_if_idle(pid, owner.idle_ms)

            state
        end
      end)

    state =
      Enum.reduce(Map.keys(state.ending), state, &ask_fence(&2, &1))

    state |> adopt() |> measure_homes() |> check_homes()
  end

  # A lapsed owner answers `lapsed` while it retires, then is gone.
  defp lapse(state, owner) do
    Logger.info(
      "[Locus.Backends.Owners] #{owner.athanor}/#{owner.server}: lease lapsed at " <>
        "g=#{owner.g} e=#{owner.e}; retiring"
    )

    drain(state, owner.id)
  end
end
