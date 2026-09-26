# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Backends.Owners do
  @moduledoc """
  The owner table of the backends service: one owner per athanor and
  server row, running at the generation `g` and epoch `e` its last sync
  named, each with the backends (`Locus.Backends.Backend`, under
  `Locus.Backends.BackendSupervisor`) that sync defined. An owner lives
  while its lease does; nothing about it is persisted. The table's
  lifetime is the service's: `boot/1` names it, and a restart forgets
  every owner under a new one.

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
  | `status` | each named owner present, its backends as they report themselves |

  A sync is answered on admission: its backends start once the version it
  replaces is retired, and `rev`, which every change to what the owner's
  `tools/list` answers raises, says when they are ready, as does the
  owner's move from `starting` to `running` once every backend has been
  ready or failed. A retired owner leaves routing at once and holds its
  uids until its backends are stopped; a lapsed one stays routed,
  answering `lapsed`, until then.

  ## Invokes

  `admit/2` answers the backends of the owner an invoke names at exactly
  its `(g, e)`: `unknown_owner` without one, `stale_epoch` below it,
  `epoch_ahead` above it, `lapsed` while it drains or once its lease has
  passed.

  ## The uid pool

  Every backend the service runs, or will run once a retirement finishes,
  holds one uid of the pool `backends`, and the uids held never exceed the
  pool's size less its quarantined uids beyond what the retirement of a
  replaced version is about to free. A uid is claimed at one place, after
  one read of the pool (`Locus.Launcher.pool_stats/2`), with the check and
  the claim in one step of this process: at a sync, for all its backends,
  and at the wake of an idle backend (`claim/2`). A claim past the pool is
  `capacity`; a pool the launcher does not answer is `unavailable`. A uid
  is freed at the retirement that ends its tenure — the owner's backends
  stopped, an idle backend's process retired, a failed backend's last
  process released — and a backend holds one or none, so a retirement seen
  twice frees nothing twice.

  ## Sleeping on nothing

  This process waits on no launcher and no backend: a pool read, the
  stopping of an owner's backends and the collection of a status run in
  processes of their own and report back. The lease and idle checks run
  when `sweep/1` asks (`Locus.Backends.LeaseSweeper`).
  """

  use GenServer

  require Logger

  alias Locus.Backends.Backend
  alias Prima.LocusBackends

  @pool "backends"

  # The keeper answers a pool read within its own 5 s; this bound covers a
  # launcher that never answers at all.
  @pool_timeout_ms 6_000
  @status_timeout_ms 5_000
  @stop_grace_ms 2_000
  @call_timeout_ms 120_000

  @typedoc "An owner as a message names it: its athanor and server row."
  @type key :: {String.t(), String.t()}

  @typedoc "What `admit/2` answers: the owner's backends by name, and its secret values."
  @type admitted :: %{backends: [{String.t(), pid() | nil}], secrets: [String.t()]}

  # ————— the interface —————

  @doc """
  Starts the table. Options: `:name`; `:boot` (a lifetime minted here by
  default); `:launcher` and `:launcher_server` (`Locus.Executor.launcher/0`'s
  by default); `:supervisor`, the `DynamicSupervisor` backends start under;
  `:clock`, the milliseconds leases and idle periods are read on
  (monotonic by default); `:max_in_flight`, `:rpc_timeout_ms`,
  `:init_timeout_ms` and `:memory_bytes` (`Locus.Config`'s by default);
  `:stop_grace_ms`; `:pool_timeout_ms`; `:status_timeout_ms`; and
  `:backend_opts`, more options for every backend.
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
  opened environment (`{:ok, %{backend => %{name => value}}}` or
  `:error`) and is called only for a version not yet held.
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

  @doc "The backends an invoke at the owner's exact version reaches, or the refusal."
  @spec admit(GenServer.server(), map()) :: {:ok, admitted()} | {:error, LocusBackends.code()}
  def admit(server \\ __MODULE__, %{athanor: _, server: _, generation: _, epoch: _} = invoke),
    do: GenServer.call(server, {:admit, invoke})

  @doc """
  A uid of the pool for the backend `backend`, which is about to start a
  process with none held: `:ok`, `{:error, :capacity}`,
  `{:error, :unavailable}`, or `{:error, :gone}` for a backend whose owner
  is retiring or unknown.
  """
  @spec claim(GenServer.server(), pid()) :: :ok | {:error, :capacity | :unavailable | :gone}
  def claim(server \\ __MODULE__, backend) when is_pid(backend) do
    GenServer.call(server, {:claim, backend}, @pool_timeout_ms + @call_timeout_ms)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc """
  Retires every owner whose lease has passed, and asks every ready backend
  of the rest to retire if no call has used it within its owner's idle
  period.
  """
  @spec sweep(GenServer.server()) :: :ok
  def sweep(server \\ __MODULE__), do: GenServer.call(server, :sweep)

  # ————— the server —————

  @impl GenServer
  def init(opts) do
    with {:ok, launcher} <- launcher(opts) do
      {:ok,
       %{
         boot: Keyword.get_lazy(opts, :boot, &mint_boot/0),
         launcher: launcher,
         launcher_server: Keyword.get(opts, :launcher_server, launcher),
         supervisor: Keyword.get(opts, :supervisor, Locus.Backends.BackendSupervisor),
         clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
         max_in_flight:
           Keyword.get_lazy(opts, :max_in_flight, &Locus.Config.backends_max_in_flight/0),
         rpc_timeout_ms:
           Keyword.get_lazy(opts, :rpc_timeout_ms, &Locus.Config.backends_rpc_timeout_ms/0),
         init_timeout_ms:
           Keyword.get_lazy(opts, :init_timeout_ms, &Locus.Config.backends_init_timeout_ms/0),
         memory_bytes:
           Keyword.get_lazy(opts, :memory_bytes, &Locus.Config.backends_memory_bytes/0),
         stop_grace_ms: Keyword.get(opts, :stop_grace_ms, @stop_grace_ms),
         pool_timeout_ms: Keyword.get(opts, :pool_timeout_ms, @pool_timeout_ms),
         status_timeout_ms: Keyword.get(opts, :status_timeout_ms, @status_timeout_ms),
         backend_opts: Keyword.get(opts, :backend_opts, []),
         high_water: {0, 0},
         owners: %{},
         routes: %{},
         pids: %{},
         queue: :queue.new(),
         busy: nil,
         pending: %{},
         drainers: %{}
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp launcher(opts) do
    case Keyword.fetch(opts, :launcher) do
      {:ok, launcher} -> {:ok, launcher}
      :error -> Locus.Executor.launcher()
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
    {reply, state} = admit_invoke(state, invoke)
    {:reply, reply, state}
  end

  def handle_call({:claim, pid}, from, state) do
    case locate(state, pid) do
      {:ok, owner, _backend} when owner.state != :draining ->
        {_ref, state} = read_pool(state, {:claim, from, pid})
        {:noreply, state}

      _gone ->
        {:reply, {:error, :gone}, state}
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

  def handle_info({Backend, pid, event}, state), do: {:noreply, on_backend(state, pid, event)}

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    cond do
      Map.has_key?(state.drainers, monitor) ->
        {id, drainers} = Map.pop(state.drainers, monitor)
        {:noreply, drained(%{state | drainers: drainers}, id)}

      Map.has_key?(state.pids, pid) ->
        {:noreply, backend_down(state, pid)}

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

  # An owner's environment and secret values are credentials, and so is a
  # sync waiting on its pool read: no status or crash report shows more of
  # them than their count, or the kind of work pending.
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
        backends:
          Map.new(owner.backends, fn {name, backend} ->
            {name, %{backend | env: {:redacted, map_size(backend.env)}}}
          end)
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
          %{state: owner_state, g: ^g, e: e} = owner
          when owner_state != :draining and e == entry.e and owner.lease_until > now ->
            owner = %{owner | lease_until: now + message.lease_ms}
            answer = Map.merge(ref, %{state: owner.state, rev: owner.rev})
            {[answer | renewed], unknown, put_owner(state, owner)}

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
      |> Enum.map(&snapshot(&1, now))

    {ref, state} = gather(state, from, snapshots)
    {:wait, ref, state}
  end

  defp apply_control(state, from, fields, %{type: :sync} = message, open_env) do
    key = {message.owner.athanor, message.owner.server}
    version = {fields.generation, message.e}
    definition = definition(message.backends)
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
            idle_ms: message.idle_ms
        }

        {:reply, {:ok, sync_answer(owner)}, put_owner(state, owner)}

      _new ->
        admit_sync(state, from, message, version, definition, existing, open_env)
    end
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
  # definitions, the version it replaces retired, and the pool read.
  defp admit_sync(state, from, message, {g, e}, definition, existing, open_env) do
    with true <- length(definition) <= LocusBackends.max_backends() || :error,
         {:ok, env} <- open(open_env),
         :ok <- environment(definition, env) do
      state = if existing, do: retire(state, existing), else: state

      sync = %{
        athanor: message.owner.athanor,
        server: message.owner.server,
        g: g,
        e: e,
        definition: definition,
        env: env,
        lease_ms: message.lease_ms,
        idle_ms: message.idle_ms,
        replacing: existing && existing.id
      }

      {ref, state} = read_pool(state, {:sync, from, sync})
      {:wait, ref, state}
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

  # The definitions as they are compared: each backend's variable names
  # sorted, the backends in the order the sync named them.
  defp definition(backends),
    do: Enum.map(backends, &%{&1 | env_names: Enum.sort(&1.env_names)})

  # The opened environment names exactly the backends, each block exactly
  # its backend's variables, every value a string.
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
        {:ok, pool} -> {:ok, %{boot: state.boot, pool: %{size: pool.size, free: pool.free}}}
        :error -> {:error, :unavailable}
      end

    GenServer.reply(from, reply)
    control_done(state)
  end

  defp continue(state, {:sync, from, sync}, result) do
    case pool(result) do
      {:ok, pool} ->
        replacing =
          case sync.replacing && Map.get(state.owners, sync.replacing) do
            nil -> 0
            owner -> slots(owner)
          end

        if slots_held(state) - replacing + length(sync.definition) > capacity(pool) do
          GenServer.reply(from, {:error, :capacity})
          control_done(state)
        else
          owner = new_owner(state, sync)

          state = %{
            state
            | owners: Map.put(state.owners, owner.id, owner),
              routes: Map.put(state.routes, {owner.athanor, owner.server}, owner.id)
          }

          # Answered on admission; the backends start after the answer.
          GenServer.reply(from, {:ok, sync_answer(owner)})
          state |> start(owner.id) |> control_done()
        end

      :error ->
        GenServer.reply(from, {:error, :unavailable})
        control_done(state)
    end
  end

  defp continue(state, {:claim, from, pid}, result) do
    {reply, state} =
      case {pool(result), locate(state, pid)} do
        {_pool, {:ok, %{state: :draining}, _backend}} ->
          {{:error, :gone}, state}

        {{:ok, _pool}, {:ok, owner, %{slot: true}}} when owner.state != :draining ->
          {:ok, state}

        {{:ok, pool}, {:ok, owner, backend}} ->
          if slots_held(state) + 1 > capacity(pool),
            do: {{:error, :capacity}, state},
            else: {:ok, put_backend(state, owner, %{backend | slot: true})}

        {:error, {:ok, _owner, _backend}} ->
          {{:error, :unavailable}, state}

        {_pool, :error} ->
          {{:error, :gone}, state}
      end

    GenServer.reply(from, reply)
    state
  end

  defp continue(state, {:status, from}, {:ok, owners}) do
    GenServer.reply(from, {:ok, %{owners: owners}})
    control_done(state)
  end

  defp continue(state, {:status, from}, _result) do
    GenServer.reply(from, {:error, :internal})
    control_done(state)
  end

  defp pool({:ok, %{size: size, free: free} = pool})
       when is_integer(size) and size >= 0 and is_integer(free) and free >= 0,
       do: {:ok, Map.put_new(pool, :quarantined, 0)}

  defp pool(_result), do: :error

  # The uids a backend may hold: every uid of the pool not quarantined.
  defp capacity(%{size: size, quarantined: quarantined}) when is_integer(quarantined),
    do: size - quarantined

  defp capacity(%{size: size}), do: size

  # ————— work of its own, in processes of its own —————

  # A pool read in a process of its own, bounded; its answer or its failure
  # arrives as the continuation's result.
  defp read_pool(state, continuation) do
    %{launcher: launcher, launcher_server: server} = state
    run(state, continuation, state.pool_timeout_ms, fn -> launcher.pool_stats(server, @pool) end)
  end

  # Each named owner's backends asked for their state at once, each within
  # the status bound; a backend that does not answer reports what this
  # table last heard of it.
  defp gather(state, from, snapshots) do
    timeout = state.status_timeout_ms

    run(state, {:status, from}, timeout + 1_000, fn ->
      {:ok, Enum.map(snapshots, &report(&1, timeout))}
    end)
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

  defp snapshot(owner, now) do
    %{
      athanor: owner.athanor,
      server: owner.server,
      g: owner.g,
      e: owner.e,
      state: owner.state,
      rev: owner.rev,
      lease_ms_left: max(0, owner.lease_until - now),
      backends: Enum.map(owner.order, &Map.fetch!(owner.backends, &1))
    }
  end

  defp report(snapshot, timeout) do
    backends =
      snapshot.backends
      |> Enum.map(fn backend ->
        {backend, Task.async(fn -> backend_report(backend, timeout) end)}
      end)
      |> Enum.map(fn {backend, task} ->
        case Task.yield(task, timeout + 100) || Task.shutdown(task, :brutal_kill) do
          {:ok, report} -> report
          _ -> last_heard(backend)
        end
      end)

    %{snapshot | backends: backends}
  end

  defp backend_report(%{pid: nil} = backend, _timeout), do: last_heard(backend)

  defp backend_report(backend, timeout) do
    report = GenServer.call(backend.pid, :status, timeout)

    %{
      name: backend.name,
      status: wire_status(report, backend.status),
      restarts: report.restarts,
      tools: report.tools,
      error: report.error,
      stderr_tail: report.stderr_tail
    }
  catch
    :exit, _reason -> last_heard(backend)
  end

  defp last_heard(backend) do
    %{
      name: backend.name,
      status: backend.status,
      restarts: 0,
      tools: backend.tools,
      error: nil,
      stderr_tail: ""
    }
  end

  # The wire's status for what a backend reports; a stopped backend is
  # reported as it last was.
  defp wire_status(%{status: :starting, phase: phase}, _last) when phase != nil, do: phase
  defp wire_status(%{status: :starting}, _last), do: :spawning
  defp wire_status(%{status: :stopped}, last), do: last
  defp wire_status(%{status: status}, _last), do: status

  # ————— owners —————

  defp new_owner(state, sync) do
    secrets = secret_values(sync.env)

    backends =
      Map.new(sync.definition, fn %{name: name, command: command} ->
        {name,
         %{
           name: name,
           command: command,
           env: Map.fetch!(sync.env, name),
           pid: nil,
           status: :spawning,
           tools: 0,
           settled: false,
           slot: true
         }}
      end)

    waits =
      case sync.replacing && Map.get(state.owners, sync.replacing) do
        nil -> []
        previous -> [previous.id | previous.waits]
      end

    %{
      id: make_ref(),
      athanor: sync.athanor,
      server: sync.server,
      g: sync.g,
      e: sync.e,
      definition: sync.definition,
      state: :starting,
      lease_until: state.clock.() + sync.lease_ms,
      idle_ms: sync.idle_ms,
      rev: 0,
      secrets: secrets,
      order: Enum.map(sync.definition, & &1.name),
      backends: backends,
      waits: Enum.filter(waits, &Map.has_key?(state.owners, &1)),
      started: false,
      drain_started: false
    }
  end

  # The values masked in everything an owner's backends answer: every
  # value of its environment but the literal ones.
  defp secret_values(env) do
    literal = LocusBackends.literal_env_names()

    for {_backend, block} <- env,
        {name, value} <- block,
        name not in literal,
        uniq: true,
        do: value
  end

  defp sync_answer(owner) do
    %{
      status: owner.state,
      rev: owner.rev,
      backends:
        Enum.map(owner.order, fn name ->
          backend = Map.fetch!(owner.backends, name)
          %{name: name, status: backend.status, tools: backend.tools}
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

  defp put_backend(state, owner, backend) do
    owner = Map.fetch!(state.owners, owner.id)
    put_owner(state, %{owner | backends: Map.put(owner.backends, backend.name, backend)})
  end

  defp locate(state, pid) do
    with {:ok, {id, name}} <- Map.fetch(state.pids, pid),
         {:ok, owner} <- Map.fetch(state.owners, id) do
      {:ok, owner, Map.fetch!(owner.backends, name)}
    end
  end

  defp slots(owner), do: Enum.count(owner.backends, fn {_name, backend} -> backend.slot end)

  defp slots_held(state),
    do: Enum.reduce(state.owners, 0, fn {_id, owner}, held -> held + slots(owner) end)

  defp unroute(state, owner) do
    key = {owner.athanor, owner.server}

    if Map.get(state.routes, key) == owner.id,
      do: %{state | routes: Map.delete(state.routes, key)},
      else: state
  end

  # Starts an admitted owner's backends once every version before it is
  # retired, unless it was retired meanwhile.
  defp start(state, id) do
    case Map.fetch(state.owners, id) do
      {:ok, %{state: :starting, started: false} = owner} ->
        if owner.waits == [] and Map.get(state.routes, key(owner)) == id,
          do: start_backends(state, owner),
          else: state

      _other ->
        state
    end
  end

  defp key(owner), do: {owner.athanor, owner.server}

  defp start_backends(state, owner) do
    owners = self()

    Enum.reduce(owner.order, put_owner(state, %{owner | started: true}), fn name, state ->
      owner = Map.fetch!(state.owners, owner.id)
      backend = Map.fetch!(owner.backends, name)

      opts =
        [
          owner: %{athanor: owner.athanor, server: owner.server, g: owner.g, e: owner.e},
          definition: %{name: name, command: backend.command, env: backend.env},
          secrets: owner.secrets,
          launcher: state.launcher,
          launcher_server: state.launcher_server,
          memory_bytes: state.memory_bytes,
          bounds:
            Keyword.merge(
              [max_in_flight: state.max_in_flight],
              Keyword.get(state.backend_opts, :bounds, [])
            ),
          rpc_timeout_ms: state.rpc_timeout_ms,
          init_timeout_ms: state.init_timeout_ms,
          stop_grace_ms: state.stop_grace_ms,
          notify: owners,
          claim: fn -> claim(owners, self()) end,
          clock: state.clock
        ]
        |> Keyword.merge(Keyword.delete(state.backend_opts, :bounds))

      case DynamicSupervisor.start_child(state.supervisor, {Backend, opts}) do
        {:ok, pid} ->
          Process.monitor(pid)
          state = %{state | pids: Map.put(state.pids, pid, {owner.id, name})}
          put_backend(state, owner, %{backend | pid: pid})

        {:error, _reason} ->
          Logger.error(
            "[Locus.Backends.Owners] #{owner.athanor}/#{owner.server} #{name}: not started"
          )

          failed(state, owner, backend)
      end
    end)
  end

  # ————— what backends report —————

  defp on_backend(state, pid, event) do
    case locate(state, pid) do
      {:ok, owner, backend} -> backend_event(state, owner, backend, event)
      :error -> state
    end
  end

  defp backend_event(state, owner, backend, {:view, view}),
    do: put_backend(state, owner, seen(backend, view))

  defp backend_event(state, owner, backend, {:ready, changed?, view}) do
    state = put_backend(state, owner, %{seen(backend, view) | settled: true})
    state = if changed?, do: touch(state, owner.id), else: state
    running(state, owner.id)
  end

  defp backend_event(state, owner, backend, {:crashed, withdrawn?, view}) do
    state = put_backend(state, owner, seen(backend, view))
    if withdrawn?, do: touch(state, owner.id), else: state
  end

  defp backend_event(state, owner, backend, {:failed, view}) do
    state = put_backend(state, owner, %{seen(backend, view) | settled: true})
    state |> touch(owner.id) |> running(owner.id)
  end

  defp backend_event(state, owner, backend, :vacated),
    do: put_backend(state, owner, %{backend | slot: false})

  defp backend_event(state, _owner, _backend, _event), do: state

  defp seen(backend, view),
    do: %{backend | status: wire_status(view, backend.status), tools: view.tools}

  # A backend process that ended on its own holds no uid and runs nothing.
  defp backend_down(state, pid) do
    {{id, name}, pids} = Map.pop(state.pids, pid)
    state = %{state | pids: pids}

    case Map.fetch(state.owners, id) do
      {:ok, %{state: :draining} = owner} ->
        put_backend(state, owner, %{Map.fetch!(owner.backends, name) | pid: nil, slot: false})

      {:ok, owner} ->
        Logger.error("[Locus.Backends.Owners] #{owner.athanor}/#{owner.server} #{name}: ended")
        failed(state, owner, %{Map.fetch!(owner.backends, name) | pid: nil})

      :error ->
        state
    end
  end

  defp failed(state, owner, backend) do
    backend = %{backend | status: :failed, tools: 0, settled: true, slot: false}

    state
    |> put_backend(owner, backend)
    |> touch(owner.id)
    |> running(owner.id)
  end

  defp touch(state, id) do
    owner = Map.fetch!(state.owners, id)
    put_owner(state, %{owner | rev: owner.rev + 1})
  end

  defp running(state, id) do
    owner = Map.fetch!(state.owners, id)

    if owner.state == :starting and
         Enum.all?(owner.backends, fn {_name, backend} -> backend.settled end) do
      touch(put_owner(state, %{owner | state: :running}), id)
    else
      state
    end
  end

  # ————— retirement —————

  defp retire_all(state, owners), do: Enum.reduce(owners, state, &retire(&2, &1))

  # Leaves routing at once; its uids are held until its backends stop.
  defp retire(state, owner), do: state |> unroute(owner) |> drain(owner.id)

  defp drain(state, id) do
    case Map.fetch!(state.owners, id) do
      %{drain_started: true} ->
        state

      owner ->
        state = put_owner(state, %{owner | state: :draining, drain_started: true})
        pids = for {_name, %{pid: pid}} <- owner.backends, pid != nil, do: pid
        %{supervisor: supervisor, stop_grace_ms: grace_ms} = state

        {_pid, monitor} = spawn_monitor(fn -> stop_all(pids, supervisor, grace_ms) end)

        %{state | drainers: Map.put(state.drainers, monitor, id)}
    end
  end

  # Every backend stopped at once, each within its grace and its release
  # bound, then taken off the supervisor.
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

    DynamicSupervisor.terminate_child(supervisor, pid)
  catch
    :exit, _reason -> :ok
  end

  # An owner whose backends are stopped frees its uids and leaves the table;
  # an owner waiting on it may start.
  defp drained(state, id) do
    case Map.pop(state.owners, id) do
      {nil, _owners} ->
        state

      {owner, owners} ->
        pids =
          Enum.reduce(owner.backends, state.pids, fn {_name, backend}, pids ->
            Map.delete(pids, backend.pid)
          end)

        state = unroute(%{state | owners: owners, pids: pids}, owner)

        waiting =
          for {other_id, other} <- state.owners, id in other.waits, do: other_id

        Enum.reduce(waiting, state, fn other_id, state ->
          other = Map.fetch!(state.owners, other_id)
          state |> put_owner(%{other | waits: List.delete(other.waits, id)}) |> start(other_id)
        end)
    end
  end

  # ————— invokes and the sweep —————

  defp admit_invoke(state, %{generation: g, epoch: e} = invoke) do
    case routed(state, {invoke.athanor, invoke.server}) do
      nil ->
        {{:error, :unknown_owner}, state}

      owner ->
        cond do
          {g, e} < {owner.g, owner.e} ->
            {{:error, :stale_epoch}, state}

          {g, e} > {owner.g, owner.e} ->
            {{:error, :epoch_ahead}, state}

          owner.state == :draining ->
            {{:error, :lapsed}, state}

          owner.lease_until <= state.clock.() ->
            {{:error, :lapsed}, lapse(state, owner)}

          true ->
            backends = for name <- owner.order, do: {name, owner.backends[name].pid}
            {{:ok, %{backends: backends, secrets: owner.secrets}}, state}
        end
    end
  end

  defp sweep_owners(state) do
    now = state.clock.()

    Enum.reduce(state.routes, state, fn {_key, id}, state ->
      owner = Map.fetch!(state.owners, id)

      cond do
        owner.state == :draining ->
          state

        owner.lease_until <= now ->
          lapse(state, owner)

        true ->
          for {_name, %{status: :ready, pid: pid}} <- owner.backends,
              pid != nil,
              do: Backend.retire_if_idle(pid, owner.idle_ms)

          state
      end
    end)
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
