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
  before (`fresh/2` is the same check, made before a body is read). A
  `home` or `homes` is applied in that order too, but its work, up to the
  stop grace and the launcher's bound on a home's change, runs in a
  process of its own: the next message is applied at once, and the call
  is answered when that work is done. So a slow removal holds nobody
  else's renewal.

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
  | `home` while an open prepares in it, or while a change of it runs | `conflict`, nothing changed |
  | `home` | every session of the home among the athanor's owners ended, then the home reset or retired; `conflict` if a launcher's request will still make it |

  A sync starts nothing: it is answered on admission with every program
  `idle`, or `failed` for none. A retired owner leaves routing at once and
  ends its sessions; a lapsed one stays routed, answering `lapsed`, until
  they are gone.

  ## Sessions

  `open/3` opens a session at exactly the owner's `(g, e)` and for one
  lifetime (`Prima.LocusBackends`, "A lifetime"). An open answers the
  session running for its lifetime (`resumed: true`), admitting nothing,
  or starts one (`resumed: false`): a `run` session's
  process on pipes, a `terminal` one's on a pseudo-terminal of the open's
  size. A program whose home is kept needs a `home_id` and a scratch one
  none (`bad_request`); a program the owner does not define is
  `unknown_program`; one failed, `program_failed`. An owner holds at most
  `Prima.LocusBackends.max_sessions/0` sessions, running or ended: the
  oldest ended one whose process is gone is forgotten for a new one, and
  with none such an open is `capacity`.

  A key runs one process at a time. An open that would start one while a
  process of the same key of the same row may still run (another
  lifetime's, running or ended, of this owner or of the one it replaced,
  whose launcher has not yet said nothing of its process is left, or a
  process a table no longer follows) is held, and holds nothing: no
  reservation, no uid and no place among the owner's sessions. The key is
  asked twice: as the open is admitted, so a held open never competes for
  the place and uid its key's last process is about to give back, and as
  its process is about to start once its preparation ends, which finds a
  process that began meanwhile, its reservation given back before it is
  held. Once no process of its key may run, or its owner is retired, it is
  opened again from the start, so it meets every refusal an open meets.
  It is held at most the stop grace and the
  release bound together (`Prima.LocusBackends.close_wait_ms/0`),
  then refused `unavailable`, and its caller's exit withdraws it. So a
  program started again under its key, a coding harness's driver among
  them, starts only after the last write of the process before it.

  ## Lifetimes and closes

  A lifetime starts one process and is then spent, and it belongs to the
  boot it was minted for (`Prima.LocusBackends.lifetime_of?/2`). This
  table fences one as its process starts and as it is closed, and keeps
  the fence for as long as the table runs, by no clock: a digest of the
  lifetime's name, 32 bytes however long its key. So an open of a lifetime
  of another boot, or of one closed or ended, is `lifetime_over` wherever
  it is met: as it is admitted, as a held one is asked again and as its
  process is about to start. The fences end with the table, whose
  replacement is another boot and admits none of their lifetimes. They
  grow by one for each lifetime started or closed in a boot, and an open
  that arrives long after its lifetime was minted is admitted if that was
  neither.

  `close/3` ends the one lifetime its caller names and asks nothing of
  that owner's standing, which may be replaced, lapsed, released or gone.
  It fences the lifetime, refuses its held opens, asks the process
  of each of its reservations that has one to end (its session, or the
  fence where no session follows it; `Reservations.of_lifetime/2`, an
  adopted ending's included) and is held as an open is, under the same
  bound, until none of it is reserved: then `:ok`, the place back. A
  preparation in flight has its place dropped at once: one still waiting
  for room is answered at once and leaves the pool's queue, and one placed
  gives its memory back. It keeps its reservation until its work answers,
  since until then it may still make the row's home, and then starts
  nothing: the home stays the row's, and only a preparation this table
  follows is waited for. The lifetime may be of an earlier boot, whose
  process the table adopted. Past the bound, or before the table has
  adopted, it is `unavailable` and the reservation stays.

  ## Places

  Every session runs in a place (`Locus.Launcher`, "Places") named by its
  session id: a `program`'s, or a `terminal`'s for a terminal session, of
  the owner's athanor and row, naming the athanor's ceiling `A` where its
  last sync named one (at most the keeper's `max_athanor_bytes`). The
  table makes it as the first step of the open's preparation, before the
  home is made or the pool read, and for itself, and the session's spawn
  names it. The keeper answers it once it has room for the session, with
  the memory bound the session's process will have, which may be after
  its room's wait: the preparation's bound outlasts it
  (`Locus.Launcher.place_wait_ms/0`). The keeper's answer is the only
  admission of a session's memory: an open whose place it refused for room
  (`no_memory`) is refused `capacity` with what the keeper says holds the
  pool (`held`, `Prima.LocusPool`): its need, what was free, the charges
  of the owner's own athanor, and everyone else's as one sum, passed on as
  the keeper gave it and logged by its need and free alone. Any other place
  not made is `unavailable`. A preparation that fails,
  is held back or is answered while the table no longer follows it, and a
  session that never spawns, leave nothing of the place: whenever a
  session's reservation is released, the table drops its place, which
  frees one no spawn named, and cyfr-locus frees one a spawn named when
  that spawn is released. A preparation killed while its place is still
  being made, its drop already sent, has the place dropped by the keeper's
  client, which follows the preparation until a spawn names the place
  (`Locus.Launcher`, "Places"). A session whose place was not made is
  `unavailable` and starts nothing.

  ## Reservations

  What a session holds, from its open's admission until its launcher says
  nothing of its process is left (an open being prepared, a session
  running and one ended whose process has not yet gone), is its
  reservation, in the one lifecycle `Locus.Backends.Reservations` writes,
  each state moved by one authority: this table for an open it never
  started, the launcher through the session (`:vacated`) or to the
  spawn's heir (`t:Locus.Launcher.spec/0`), and the launcher's fence
  (`c:Locus.Launcher.fence/2`) for a process no session follows. A
  reservation holds the session's place and, for a scratch session, its
  uid; the memory is the pool's to count. An open of a lifetime being
  prepared, starting or running reserves nothing more: it waits for that
  preparation and that launch and is answered what they came to,
  `resumed: true` only of a launch that succeeded. A reservation this
  table stops following, its session process dead, its spawn's answer
  lost (`:unconfirmed`) or its owner retired, is an ending, fenced at once
  and at every sweep until it is settled. A release timeout settles
  nothing. On start the table adopts, as heir, every process the launcher
  still holds for its ledger (`:ledger`, its name by default), each an
  ending, so a table that restarts holds what its predecessor followed,
  and admits nothing until the launcher has answered.

  Before a scratch session's process starts it holds a uid of the pool
  `backends`: the claim is made after one read of the pool
  (`Locus.Launcher.pool_stats/2`), with the check and the claim in one
  step of this process, and the uids held never exceed the pool's size
  less its quarantined uids (`capacity`; a pool the launcher does not
  answer is `unavailable`). The uid is freed when the session's process
  is gone. A kept session holds no uid of the pool: its home is made if it
  is absent (`Locus.Launcher.home_ensure/2`) and the process runs under
  the home's own uid.

  `session/3` names the running or ended session every other session
  message reaches, and its mode, at exactly the owner's version; one the
  owner does not hold is `unknown_session`. Nothing waits on a session
  here: those calls go to the session itself.

  ## Crashes

  A session whose process crashed (`Locus.Backends.Backend`) counts
  against its session key, `(program, home_id, key, mode)`, within
  `crash_window_ms/0`: the next open of that key starts its process only
  once the backoff's wait for that many crashes (`restart_backoff_ms/0`)
  has passed since the last, and the `max_crashes/0`-th fails that key,
  refusing its opens `program_failed` until a sync at a new version. One
  key's crashes never fail another's open: one home's terminals, or one
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

  alias Locus.Backends.{Backend, Reservations}
  alias Prima.{KeeperProtocol, LocusBackends}

  @pool "backends"

  # The keeper answers a pool read within its own 5 s; this bound covers a
  # launcher that never answers at all.
  @pool_timeout_ms 6_000
  # A home's making, measuring, reset or retirement is the launcher's work
  # as the home's own uid, which may take it up to 120 s.
  @home_timeout_ms 130_000
  @status_timeout_ms 5_000
  # The wire's one bound of a close, less what of it is the release's.
  @stop_grace_ms LocusBackends.close_wait_ms() - Backend.release_timeout_ms()
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
  read on (monotonic by default);
  `:ledger`, the name its sessions' heir tags carry, which
  a restarted table adopts back (its `:name`, else its own); `:stop_grace_ms`;
  `:place_wait_ms`, how long a preparation waits for its place
  (`Locus.Launcher.place_wait_ms/0` by default); `:pool_timeout_ms`;
  `:status_timeout_ms`; `:measure_interval_ms`;
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
          {:ok, %{status: :running, session: String.t(), resumed: boolean()}}
          | {:error, LocusBackends.refusal()}
  def open(server \\ __MODULE__, invoke, message) do
    GenServer.call(server, {:open, invoke, message}, @open_timeout_ms)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc """
  Ends the lifetime `message` names, as the owner version `invoke` names
  opened it, and answers `:ok` once nothing of it is held ("Lifetimes and
  closes").
  """
  @spec close(GenServer.server(), map(), LocusBackends.close_message()) ::
          :ok | {:error, LocusBackends.code()}
  def close(server \\ __MODULE__, invoke, message) do
    GenServer.call(server, {:close, invoke, message}, @call_timeout_ms)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc """
  Where a `packs_hold` or a `packs_put` of the owner `invoke` names goes,
  for a program of that owner that loads packs (its sync's `packs`, else
  `bad_request`), the owner admitted at exactly its version as a session
  message's is. A hold of a lifetime whose session lives, starting or
  running, is that session's: `{:held, digest}`, the generation its open
  named, which it keeps while it runs, and nothing goes to the keeper.
  Any other goes to the launcher that keeps the person's packs, for a
  lifetime of this boot that no fence names (else `lifetime_over`), so a
  put for a lifetime whose session lives is refused. Nothing of the
  lifetime is spent: no admission, slot, uid or home. The caller sends
  the request itself, so no part of a put passes through this table.
  """
  @spec packs(GenServer.server(), map(), map()) ::
          {:ok, {module(), term()}} | {:held, String.t()} | {:error, LocusBackends.code()}
  def packs(server \\ __MODULE__, invoke, message) do
    GenServer.call(server, {:packs, invoke, message}, @call_timeout_ms)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc """
  The session `id` of the owner `invoke` names: its process, its mode and
  what ended its process for memory, which the session told this table
  before it was vacated (`:cap`, `:machine` or `:either`), else nil. The
  cause is kept for every later answer of the session, its process gone
  or not.
  """
  @spec session(GenServer.server(), map(), String.t()) ::
          {:ok, pid() | nil, LocusBackends.mode(), LocusBackends.ended_by() | nil}
          | {:error, LocusBackends.code()}
  def session(server \\ __MODULE__, invoke, id),
    do: GenServer.call(server, {:session, invoke, id})

  @doc """
  Retires every owner whose lease has passed, asks every running session
  of the rest to end if no message used it within its owner's idle
  period, and measures every capped kept home a session runs in
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
        stop_grace_ms: Keyword.get(opts, :stop_grace_ms, @stop_grace_ms),
        place_wait_ms: Keyword.get_lazy(opts, :place_wait_ms, &Locus.Launcher.place_wait_ms/0),
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
        # What every session holds, from its open's admission until its
        # launcher says nothing of it is left (`Reservations`).
        reservations: Reservations.new(),
        ledger: Keyword.get_lazy(opts, :ledger, fn -> Keyword.get(opts, :name, make_ref()) end),
        adopted: false,
        adopting: false,
        queue: :queue.new(),
        busy: nil,
        pending: %{},
        drainers: %{},
        # The fences of this boot's lifetimes (`fence/1`).
        fences: MapSet.new(),
        # What waits on a release, each asked again when woken: an open
        # while a process of its key may still run, and a close while its
        # reservation stands.
        held: %{},
        waking: false
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

  # What a request signed for another table's boot is refused with, however
  # long its body took to arrive: that table's fences went with it.
  def handle_call({kind, %{boot: boot}, _message}, _from, %{boot: current} = state)
      when kind in [:open, :close, :packs] and boot != current,
      do: {:reply, {:error, :stale_boot}, state}

  def handle_call({:packs, invoke, message}, _from, state) do
    case admit_owner(state, invoke) do
      {:ok, owner, state} ->
        named = lifetime(invoke, message)

        with {:ok, _program} <- loading_packs(owner, message),
             :error <- live_hold(state, owner, named, message),
             :ok <- admissible(state, named) do
          {:reply, {:ok, session_launcher(state)}, state}
        else
          answered -> {:reply, answered, state}
        end

      {:error, code, state} ->
        {:reply, {:error, code}, state}
    end
  end

  def handle_call({:open, invoke, message}, from, state) do
    case open(state, invoke, message, from) do
      {:hold, state} -> {:noreply, hold(state, {:open, invoke, message}, from)}
      answered -> answered
    end
  end

  # Until the launcher has answered what it holds, nothing is known to be
  # released. The lifetime is fenced all the same.
  def handle_call({:close, invoke, message}, _from, %{adopted: false} = state),
    do: {:reply, {:error, :unavailable}, put_fence(state, lifetime(invoke, message))}

  def handle_call({:close, invoke, message}, from, state) do
    named = lifetime(invoke, message)
    state = wake(put_fence(state, named))

    state =
      state.reservations
      |> Reservations.of_lifetime(named)
      |> Enum.reduce(state, &end_reserved(&2, &1))

    case asked_again(state, {:close, named}, from) do
      {:hold, state} -> {:noreply, hold(state, {:close, named}, from)}
      answered -> answered
    end
  end

  def handle_call({:session, invoke, id}, _from, state) do
    case admit_owner(state, invoke) do
      {:ok, owner, state} ->
        case Map.fetch(owner.sessions, id) do
          {:ok, session} -> {:reply, {:ok, session.pid, session.mode, session.ended_by}, state}
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

  def handle_info(:wake_held, state), do: {:noreply, wake_held(%{state | waking: false})}

  def handle_info({:held_limit, ref}, state) do
    case Map.pop(state.held, ref) do
      {nil, _held} ->
        {:noreply, state}

      {entry, held} ->
        Process.demonitor(entry.monitor, [:flush])
        GenServer.reply(entry.from, {:error, :unavailable})
        {:noreply, %{state | held: held}}
    end
  end

  # The launcher, as a spawn's heir: nothing of that session's process is
  # left.
  def handle_info({_launcher, {:heir, %{session: key}}, :released}, state),
    do: {:noreply, reservation(state, key, :heir)}

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

      # A held call's caller left: nothing is opened for it, and an end
      # already asked stands.
      ref = held_by_monitor(state, monitor) ->
        {entry, held} = Map.pop(state.held, ref)
        Process.cancel_timer(entry.timer)
        {:noreply, %{state | held: held}}

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
      {:state, %{owners: owners, pending: pending, held: held} = state} ->
        {:state,
         %{
           state
           | owners: Map.new(owners, fn {id, owner} -> {id, redacted(owner)} end),
             pending: Map.new(pending, fn {ref, entry} -> {ref, elem(entry.continuation, 0)} end),
             held: map_size(held),
             fences: MapSet.size(state.fences)
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

            # Work that answers its caller itself, the turn given back.
            {:started, state} ->
              next_control(state)
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

        {:reply, {:ok, sync_answer(owner)}, put_owner(state, owner)}

      _new ->
        admit_sync(state, message, version, definition, existing, open_env)
    end
  end

  defp apply_control(state, from, _fields, %{type: :homes}, _open_env) do
    %{launcher: launcher, launcher_server: server} = state

    {_ref, state} =
      run(state, {:homes, from}, @home_timeout_ms, fn -> home_list(launcher, server) end)

    {:started, state}
  end

  # A home still being prepared or already being changed is neither reset nor
  # retired again: it is `conflict`, the home busy rather than the service
  # down. The controller sends a retire again until it is acknowledged, and
  # a reset is asked again.
  defp apply_control(state, from, _fields, %{type: :home} = message, _open_env) do
    if preparing_in?(state, message.home_id) or changing?(state, message.home_id),
      do: {:reply, {:error, :conflict}, state},
      else: change_home(state, from, message)
  end

  defp changing?(state, home_id), do: match?(%{busy: true}, state.homes[home_id])

  defp preparing_in?(state, home_id) do
    Enum.any?(state.pending, fn {_ref, entry} ->
      match?({:open, _froms, %{home_id: ^home_id}}, entry.continuation)
    end)
  end

  defp change_home(state, from, message) do
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

    {_ref, state} =
      run(state, {:home, from, message}, @home_timeout_ms + grace_ms + 30_000, fn ->
        stop_all(pids, nil, grace_ms)

        case message.op do
          :reset -> launcher.home_reset(server, message.home_id)
          :retire -> launcher.home_retire(server, message.home_id)
        end
      end)

    {:started, state}
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

      {:reply, {:ok, sync_answer(owner)}, state}
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
             pool: %{size: pool.size, free: pool.free}
           }}

        :error ->
          {:error, :unavailable}
      end

    GenServer.reply(from, reply)
    control_done(state)
  end

  defp continue(state, {:status, from}, {:ok, owners}) do
    GenServer.reply(from, {:ok, %{owners: owners}})
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

        # The launcher's request that will still make the home, as an open's
        # preparation is: the home busy, not the service.
        {_op, {:error, {:refused, "conflict"}}} ->
          {{:error, :conflict}, Map.put(state.homes, message.home_id, %{home | busy: false})}

        {_op, _failed} ->
          {{:error, :unavailable}, Map.put(state.homes, message.home_id, %{home | busy: false})}
      end

    GenServer.reply(from, reply)
    %{state | homes: homes}
  end

  defp continue(state, {:open, froms, ask}, result), do: opened(state, froms, ask, result)

  # An end asked says nothing of a release: only the reservation does.
  defp continue(state, {:end_asked, _key}, _result), do: state

  defp continue(state, {:fenced, key}, result) do
    answer = if result in [:none, :pending], do: result, else: :failed
    reservation(state, key, {:fence, answer})
  end

  defp continue(state, {:adopted}, {:ok, tags}) when is_list(tags), do: adopted(state, tags)
  defp continue(state, {:adopted}, _failed), do: %{state | adopting: false}

  defp continue(state, {:measured, home_id}, result), do: measured(state, home_id, result)

  defp continue(state, {:homes, from}, result) do
    reply =
      case result do
        {:ok, ids} when is_list(ids) -> {:ok, %{homes: Enum.sort(ids)}}
        _failed -> {:error, :unavailable}
      end

    GenServer.reply(from, reply)
    state
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

  # An open from the start: its owner admitted, then its session.
  defp open(state, invoke, message, from) do
    case admit_owner(state, invoke) do
      {:ok, owner, state} -> open_session(state, owner, invoke, message, from)
      {:error, code, state} -> {:reply, {:error, code}, state}
    end
  end

  # An open or a close held: its caller watched, and its bound set.
  defp hold(state, waiting, {pid, _tag} = from) do
    ref = make_ref()

    release_ms =
      Keyword.get(state.session_opts, :release_timeout_ms, Backend.release_timeout_ms())

    entry = %{
      waiting: waiting,
      from: from,
      monitor: Process.monitor(pid),
      timer: Process.send_after(self(), {:held_limit, ref}, state.stop_grace_ms + release_ms)
    }

    %{state | held: Map.put(state.held, ref, entry)}
  end

  defp held_by_monitor(state, monitor),
    do: Enum.find_value(state.held, fn {ref, entry} -> entry.monitor == monitor && ref end)

  # Something a held call waits on may have changed: they are asked again
  # once this message is handled, not inside the change.
  defp wake(%{held: held} = state) when held == %{}, do: state
  defp wake(%{waking: true} = state), do: state

  defp wake(state) do
    send(self(), :wake_held)
    %{state | waking: true}
  end

  # Each held call asked again: held again, under the bound it was first
  # given, while what it waits on is not released.
  defp wake_held(state) do
    Enum.reduce(Map.keys(state.held), state, fn ref, state ->
      case Map.pop(state.held, ref) do
        {nil, _held} ->
          state

        {entry, held} ->
          case asked_again(%{state | held: held}, entry.waiting, entry.from) do
            {:hold, state} ->
              %{state | held: Map.put(state.held, ref, entry)}

            answered ->
              Process.demonitor(entry.monitor, [:flush])
              Process.cancel_timer(entry.timer)

              case answered do
                {:reply, reply, state} ->
                  GenServer.reply(entry.from, reply)
                  state

                {:noreply, state} ->
                  state
              end
          end
      end
    end)
  end

  defp asked_again(state, {:open, invoke, message}, from),
    do: open(state, invoke, message, from)

  defp asked_again(state, {:close, named}, _from) do
    if Reservations.of_lifetime(state.reservations, named) == [],
      do: {:reply, :ok, state},
      else: {:hold, state}
  end

  # A closed lifetime's reservation: one still being prepared has its place
  # dropped, so a place still waiting for room is answered at once and
  # leaves the pool's queue, and is held until that work answers, which
  # then starts nothing (`opened/4`); any other has its process asked to
  # end, its session answering no open as running any more.
  defp end_reserved(state, {owner_id, session_id} = key) do
    case {state.reservations[key], state.owners} do
      {%{state: :reserved}, _owners} ->
        {launcher, server} = session_launcher(state)
        launcher.drop(server, session_id)
        state

      {_asked, %{^owner_id => %{sessions: %{^session_id => session}} = owner}} ->
        state |> put_session(owner, session_id, %{session | closed: true}) |> ask_end(key)

      _no_session_follows ->
        ask_end(state, key)
    end
  end

  # A close's process asked to end: through the session that follows it,
  # off this process, since a session may be waiting on its launcher; and
  # by the fence for an ending, which no session follows.
  defp ask_end(state, {owner_id, session_id} = key) do
    state =
      case state.owners do
        %{^owner_id => %{sessions: %{^session_id => %{pid: pid}}}} when is_pid(pid) ->
          {_ref, state} =
            run(state, {:end_asked, key}, @call_timeout_ms, fn -> Backend.close(pid) end)

          state

        _no_session_follows ->
          state
      end

    ask_fence(state, key)
  end

  defp open_session(state, owner, invoke, message, from) do
    case Enum.find(owner.definition, &(&1.name == message.program)) do
      nil -> {:reply, {:error, :unknown_program}, state}
      program -> open_program(state, owner, program, invoke, message, from)
    end
  end

  # The program a packs request or an open naming packs is for: one of the
  # owner's that loads packs, as its sync says.
  defp loading_packs(owner, message) do
    case Enum.find(owner.definition, &(&1.name == message.program)) do
      nil -> {:error, :unknown_program}
      %{packs: true} = program -> {:ok, program}
      _loads_none -> {:error, :bad_request}
    end
  end

  # A hold of a lifetime whose session lives, or whose open is still
  # preparing, names the generation that open named. A session whose open
  # named none holds none, and its lifetime is spent.
  defp live_hold(state, owner, named, %{type: :packs_hold}) do
    case {running(owner, named), preparing(state, named)} do
      {{_running_or_starting, id}, _preparing} -> named_packs(owner.sessions[id])
      {:error, {:preparing, ref}} -> named_packs(elem(state.pending[ref].continuation, 2))
      {:error, :error} -> :error
    end
  end

  defp live_hold(_state, _owner, _named, %{type: :packs_put}), do: :error

  defp named_packs(%{packs: digest}) when is_binary(digest), do: {:held, digest}
  defp named_packs(_none), do: :error

  defp open_program(state, owner, program, invoke, message, from) do
    named = lifetime(invoke, message)

    ask = %{
      owner: owner.id,
      session: "ss_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
      athanor: owner.athanor,
      program: program.name,
      home_id: message.home_id,
      key: named.key,
      named: named,
      lifetime: message.lifetime,
      mode: message.mode,
      argv: message.argv,
      packs: Map.get(message, :packs),
      size: if(message.mode == :terminal, do: %{rows: message.rows, cols: message.cols}),
      # What it is opened again from, should it be held once prepared.
      invoke: invoke,
      message: message
    }

    with :ok <- shape(program, message),
         :ok <- packs_shape(program, message),
         :ok <- not_failed(owner, program, ask.key),
         :error <- running(owner, named),
         :ok <- admissible(state, named),
         :error <- preparing(state, named),
         :ok <- gone_before(state, owner, ask.key),
         :ok <- home_open(state, message.home_id),
         :ok <- adopted(state),
         {:ok, admitted} <- room(state, owner) do
      state = put_owner(state, admitted)
      tag = heir_tag(state, owner, ask.session, ask)
      state = %{state | reservations: Reservations.reserve(state.reservations, tag)}
      %{launcher: launcher, launcher_server: server} = state
      place = place_of(state, owner, ask)

      case program.home do
        :kept ->
          cap = program.home_max_bytes
          state = put_home(state, message.home_id, &%{&1 | athanor: admitted.athanor, cap: cap})

          {_ref, state} =
            run(state, {:open, [from], ask}, state.place_wait_ms + @home_timeout_ms * 2, fn ->
              with :placed <- place.(), do: kept_ready(launcher, server, message.home_id, cap)
            end)

          {:noreply, state}

        :scratch ->
          {_ref, state} =
            run(state, {:open, [from], ask}, state.place_wait_ms + state.pool_timeout_ms, fn ->
              with :placed <- place.(), do: launcher.pool_stats(server, @pool)
            end)

          {:noreply, state}
      end
    else
      {:ok, session_id} ->
        {:reply, {:ok, opened_answer(session_id, true)}, state}

      # A second ask shares what the first comes to.
      {:starting, session_id} ->
        session = owner.sessions[session_id]
        session = %{session | waiting: session.waiting ++ [from]}
        {:noreply, put_session(state, owner, session_id, session)}

      {:preparing, ref} ->
        %{continuation: {:open, froms, first}} = entry = state.pending[ref]
        entry = %{entry | continuation: {:open, froms ++ [from], first}}
        {:noreply, %{state | pending: Map.put(state.pending, ref, entry)}}

      :behind ->
        {:hold, state}

      {:error, code} ->
        {:reply, {:error, code}, state}
    end
  end

  # The session's place, made before anything of its preparation under the
  # session's id, for this table: a program's or a terminal's of the row,
  # within the athanor's ceiling where its sync named one. Its
  # reservation's release drops it (`reservation/3`).
  defp place_of(state, owner, ask) do
    {launcher, server} = session_launcher(state)
    table = self()
    kind = if ask.mode == :terminal, do: "terminal", else: "program"

    whose =
      put_given(
        %{kind: kind, athanor: owner.athanor, subject: owner.server},
        :athanor_max_bytes,
        owner.athanor_memory_bytes &&
          min(owner.athanor_memory_bytes, KeeperProtocol.request_bounds().max_athanor_bytes)
      )

    fn ->
      case launcher.place(server, ask.session, whose, table) do
        {:ok, _memory_bytes} -> :placed
        {:error, reason} -> {:unplaced, reason}
      end
    end
  end

  # A kept program's sessions need a home, and a scratch one's none.
  defp shape(%{home: :kept}, %{home_id: nil}), do: {:error, :bad_request}

  defp shape(%{home: :scratch}, %{home_id: home_id}) when home_id != nil,
    do: {:error, :bad_request}

  defp shape(_program, _message), do: :ok

  # An open names packs only for a program that loads them.
  defp packs_shape(%{packs: true}, _message), do: :ok
  defp packs_shape(_program, %{packs: digest}) when is_binary(digest), do: {:error, :bad_request}
  defp packs_shape(_program, _message), do: :ok

  defp not_failed(owner, program, key) do
    if MapSet.member?(owner.programs[program.name].failed_keys, key),
      do: {:error, :program_failed},
      else: :ok
  end

  # Nothing of a process of the key may still run, whoever followed it.
  defp gone_before(state, owner, key) do
    if Reservations.process?(state.reservations, owner.athanor, owner.server, key),
      do: :behind,
      else: :ok
  end

  # The session of this very lifetime: running only once its launch
  # succeeded, and starting until then.
  defp running(owner, named) do
    Enum.find_value(owner.sessions, :error, fn
      {id, %{running: true, closed: false, named: ^named, started: true}} -> {:ok, id}
      {id, %{running: true, closed: false, named: ^named}} -> {:starting, id}
      _another_or_over -> nil
    end)
  end

  # This very lifetime's preparation in flight.
  defp preparing(state, named) do
    Enum.find_value(state.pending, :error, fn
      {ref, %{continuation: {:open, _froms, %{named: ^named}}}} -> {:preparing, ref}
      _other_work -> nil
    end)
  end

  # One lifetime, as the version that signs and the key it names make it.
  defp lifetime(invoke, message) do
    %{
      athanor: invoke.athanor,
      server: invoke.server,
      g: invoke.generation,
      e: invoke.epoch,
      key: {message.program, message.home_id, message.key, message.mode},
      lifetime: message.lifetime
    }
  end

  # A process may start for a lifetime of this boot that no fence names.
  defp admissible(state, named) do
    if LocusBackends.lifetime_of?(named.lifetime, state.boot) and
         not MapSet.member?(state.fences, fence(named)),
       do: :ok,
       else: {:error, :lifetime_over}
  end

  defp put_fence(state, named), do: %{state | fences: MapSet.put(state.fences, fence(named))}

  defp fence(named), do: :crypto.hash(:sha256, :erlang.term_to_binary(named, [:deterministic]))

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
        |> Enum.filter(fn {id, session} ->
          not session.running and not Reservations.held?(state.reservations, {owner.id, id})
        end)
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

  # Until the launcher has answered what it still holds for this ledger,
  # nothing is known to be free.
  defp adopted(%{adopted: false}), do: {:error, :unavailable}
  defp adopted(_state), do: :ok

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

  # The open's work done: the session started, or the refusal, with which
  # nothing was asked of the launcher and the reservation is released. Its
  # key is asked again as its process is about to start: a process of the
  # key that began ending while it was prepared holds it as one found at
  # admission does, its reservation given back first.
  defp opened(state, froms, ask, result) do
    with {:ok, owner} <- still_open(state, ask),
         :ok <- admissible(state, ask.named),
         program = Enum.find(owner.definition, &(&1.name == ask.program)),
         :ok <- claimed(state, program, ask, result),
         :ok <- gone_before(state, owner, ask.key) do
      start_session(state, owner, program, ask, froms)
    else
      :behind ->
        state = reservation(state, {ask.owner, ask.session}, :abandoned)
        Enum.reduce(froms, state, &hold(&2, {:open, ask.invoke, ask.message}, &1))

      {:error, code, state} ->
        unopened(state, froms, ask, code)

      {:error, code} ->
        unopened(state, froms, ask, code)
    end
  end

  defp unopened(state, froms, ask, code) do
    Enum.each(froms, &GenServer.reply(&1, {:error, code}))
    reservation(state, {ask.owner, ask.session}, :abandoned)
  end

  defp still_open(state, ask) do
    case Map.fetch(state.owners, ask.owner) do
      {:ok, %{state: :running} = owner} -> {:ok, owner}
      _gone -> {:error, :lapsed}
    end
  end

  # A scratch session's uid of the pool, claimed in this step; a kept
  # session's home ready under its bound. A session whose place was not
  # made starts nothing.
  defp claimed(_state, _program, ask, {:unplaced, {:no_memory, held}}) do
    Logger.warning(
      "[Locus.Backends.Owners] #{ask.athanor} #{ask.program}: cyfr-locus found no room for a " <>
        "session (no_memory: #{held.need} bytes needed, #{held.free} free)"
    )

    {:error, {:capacity, held}}
  end

  defp claimed(_state, _program, _ask, {:unplaced, _reason}), do: {:error, :unavailable}

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

  defp start_session(state, owner, program, ask, froms) do
    session_id = ask.session
    record = owner.programs[program.name]

    opts =
      [
        owner: %{athanor: owner.athanor, server: owner.server, g: owner.g, e: owner.e},
        session: session_id,
        program: program.name,
        mode: ask.mode,
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
          named: ask.named,
          closed: false,
          home_id: ask.home_id,
          mode: ask.mode,
          packs: ask.packs,
          running: true,
          started: false,
          ended_by: nil,
          opened: System.unique_integer([:monotonic]),
          waiting: froms
        }

        owner = %{
          owner
          | sessions: Map.put(owner.sessions, session_id, session),
            programs:
              Map.put(owner.programs, program.name, %{
                record
                | last: session_id,
                  homes:
                    if(ask.home_id, do: MapSet.put(record.homes, ask.home_id), else: record.homes)
              })
        }

        %{state | pids: Map.put(state.pids, pid, {owner.id, session_id})}
        |> put_owner(owner)
        |> put_fence(ask.named)
        |> reservation({owner.id, session_id}, :started)

      {:error, _reason} ->
        Logger.error(
          "[Locus.Backends.Owners] #{owner.athanor}/#{owner.server} #{program.name}: " <>
            "a session did not start"
        )

        unopened(state, froms, ask, :internal)
    end
  end

  # What a session's process runs: the program's command with the open's
  # arguments as its own, `"$@"` (the administrator allowed the program;
  # its arguments shape only what runs inside its box), a terminal's on a
  # pseudo-terminal of the open's size, told the terminal type unless its
  # environment names one.
  defp spec(state, owner, program, ask, session_id) do
    env = Map.fetch!(owner.env, program.name)

    %{
      place: session_id,
      argv: ["/bin/sh", "-c", program.command <> " \"$@\"", "sh" | ask.argv],
      env: if(ask.size, do: Map.put_new(env, "TERM", LocusBackends.terminal_type()), else: env),
      pool: @pool,
      heir: {self(), heir_tag(state, owner, session_id, ask)}
    }
    |> put_given(:home, ask.home_id)
    |> put_given(:home_max_bytes, program.home_max_bytes)
    |> put_given(:pty, ask.size)
    |> put_given(:hosts, program.hosts)
    |> put_given(:packs, ask.packs && %{athanor: owner.athanor, digest: ask.packs})
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

  defp opened_answer(session_id, resumed?),
    do: %{status: :running, session: session_id, resumed: resumed?}

  # ————— what sessions report —————

  defp on_session(state, pid, event) do
    case locate(state, pid) do
      {:ok, owner, session_id, session} -> session_event(state, owner, session_id, session, event)
      :error -> state
    end
  end

  defp session_event(state, owner, session_id, session, :started) do
    # The first asked for the process, and each after it for that same one.
    session.waiting
    |> Enum.with_index()
    |> Enum.each(fn {from, at} ->
      GenServer.reply(from, {:ok, opened_answer(session_id, at > 0)})
    end)

    state
    |> put_session(owner, session_id, %{session | started: true, waiting: []})
    |> reservation({owner.id, session_id}, :spawned)
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

  # Memory ended the session's process: kept for its later answers. It
  # comes before `:vacated`, from the session itself, so it is here before
  # the session's process record goes.
  defp session_event(state, owner, session_id, session, {:memory, cause}),
    do: put_session(state, owner, session_id, %{session | ended_by: cause})

  # The launcher, through the session: its spawn refused with nothing of
  # it made, or nothing of its process left.
  defp session_event(state, owner, session_id, _session, :vacated),
    do: reservation(state, {owner.id, session_id}, :confirmed)

  # The session could not learn whether its spawn was taken: its process may
  # yet run, and only the launcher can say.
  defp session_event(state, owner, session_id, _session, :unconfirmed),
    do: unfollowed(state, {owner.id, session_id})

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
            state = unfollowed(state, {owner.id, session_id})
            session = %{session | pid: nil, running: false, waiting: []}
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

        %{
          name: program.name,
          status:
            cond do
              MapSet.size(record.failed_keys) > 0 -> :failed
              sessions != [] -> :running
              true -> :idle
            end,
          restarts: record.restarts,
          error: record.error,
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

  defp sync_answer(owner) do
    %{
      status: owner.state,
      programs:
        Enum.map(owner.definition, fn %{name: name} ->
          failed? = MapSet.size(owner.programs[name].failed_keys) > 0
          %{name: name, status: if(failed?, do: :failed, else: :idle)}
        end)
    }
  end

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
  defp slots_held(state), do: Reservations.uids(state.reservations)

  # Every change to what a session holds goes through its reservation's
  # lifecycle (`Reservations`).
  # A reservation released has nothing of its session left: its place is
  # dropped, which frees it where no spawn named it (a preparation that
  # failed or was held, a session that never spawned) and is nothing where
  # one did, which cyfr-locus freed at the spawn's release.
  defp reservation(state, key, event) do
    held? = Map.has_key?(state.reservations, key)
    reservations = Reservations.event(state.reservations, key, event)
    state = %{state | reservations: reservations}

    cond do
      Map.has_key?(reservations, key) ->
        state

      held? ->
        {launcher, server} = session_launcher(state)
        launcher.drop(server, elem(key, 1))
        wake(state)

      true ->
        wake(state)
    end
  end

  # A reservation this table no longer follows is an ending, fenced at once.
  defp unfollowed(state, key), do: state |> reservation(key, :unfollowed) |> ask_fence(key)

  # What a session's heir tag names: the ledger that may adopt it, the
  # session, what it holds, its lifetime (the version that opened it, and
  # the row and key it runs under, included), so a table that adopts it
  # holds the same, closes it by the same name and holds back the next
  # open of its key.
  defp heir_tag(state, owner, session_id, ask) do
    %{
      ledger: state.ledger,
      session: {owner.id, session_id},
      athanor: owner.athanor,
      server: owner.server,
      g: owner.g,
      e: owner.e,
      key: ask.key,
      lifetime: ask.lifetime,
      home_id: ask.home_id
    }
  end

  # The session launcher: the one a session's process is spawned through.
  defp session_launcher(state) do
    {Keyword.get(state.session_opts, :launcher, state.launcher),
     Keyword.get(state.session_opts, :launcher_server, state.launcher_server)}
  end

  # An ending's fence asked of its launcher, once at a time.
  defp ask_fence(state, key) do
    case state.reservations[key] do
      %{state: :ending, fence: fence, tag: tag} when fence in [:unasked, :pending] ->
        {launcher, server} = session_launcher(state)
        state = reservation(state, key, :asking)

        {_ref, state} =
          run(state, {:fenced, key}, @pool_timeout_ms, fn -> launcher.fence(server, tag) end)

        state

      _settled_or_asking ->
        state
    end
  end

  # What the launcher still holds for this ledger, adopted: each an ending,
  # fenced, so one whose end this table already heard is settled by the
  # fence's `:none`.
  defp adopted(state, tags) do
    state =
      Enum.reduce(tags, state, fn %{session: key} = tag, state ->
        state |> reservation(key, {:adopted, tag}) |> ask_fence(key)
      end)

    %{state | adopted: true, adopting: false}
  end

  defp adopt(%{adopted: true} = state), do: state
  defp adopt(%{adopting: true} = state), do: state

  defp adopt(state) do
    {launcher, server} = session_launcher(state)
    ledger = state.ledger
    owners = self()

    {_ref, state} =
      run(state, {:adopted}, @pool_timeout_ms, fn -> launcher.adopt(server, ledger, owners) end)

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
        state = wake(put_owner(state, %{owner | state: :draining, drain_started: true}))

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
          Enum.reduce(Map.keys(owner.sessions), state, fn session_id, state ->
            unfollowed(state, {owner.id, session_id})
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
      state.reservations
      |> Reservations.to_fence()
      |> Enum.reduce(state, &ask_fence(&2, &1.tag.session))

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
