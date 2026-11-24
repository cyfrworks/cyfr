# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Output do
  @moduledoc """
  The one count of the output a role of a Locus node holds in its own
  memory, to the role's bound (`bounds/0`): what the backends service keeps
  unread for its sessions' readers, and what each service has taken out to
  answer or send on. One process per role a node serves (`server/1`),
  started by `Locus.Application` before the roles' children.

  A count is freed only on its holder's word: a `hold/2` naming less, a
  `return/1`, or the holder's death, which is the runtime's word that its
  memory is gone. Nothing is freed for a timeout, a refusal or a lost
  connection.

  ## Unread

  A holder (a backends session) names its whole unread holding with
  `hold/2` after every change of it. Past the role's unread bound, the
  holder holding most of those not already dropping is given a target, its
  holding less the excess, and asked to drop its oldest to it: the caller
  itself is answered `{:drop_to, target}` and holds again once it has; any
  other is sent `{Locus.Output, :over}` and holds again when it reads it,
  at its next message turn. A holder with a target that holds above it,
  for whatever reason it holds, is answered `{:drop_to, target}` in its own
  call: what it owes stays its own and passes to no one, and its target
  goes only once it holds at or below it. No holder waits on another, so
  the count may sit over its bound while a holder told to drop has not yet
  held again: each such holder owes the excess it was assigned, at most
  the one increment of the hold that passed the bound, and is assigned no
  other while it owes. The count therefore passes its bound by at most the
  sum of what the holders told and not yet heard from owe: at most one
  per-hold increment for each of them, each until that holder's next
  hold.

  ## Answering

  Bytes taken out to be answered or sent on (a session's answer, a fetch's
  piece, a host call's answer, a build's reads and lines) are asked for
  before they are made (`ask/3`, `reserve/3`): granted in arrival order
  when the role's answering bound has room, or answered `:full` at the
  asker's deadline, a monotonic instant in milliseconds. A request larger
  than the bound is `:full` at once. The grant is the asker's; `give/2`
  moves it to the process the bytes are handed to, and `return/1` is its
  holder's word that they are gone.

  ## What each role holds

  A role's memory has a bound when every byte its service holds for a
  caller is counted here, or is of a kind capped in size and in how many
  there are at once. Each kind below names its cap, its number at once
  and where each comes from. The numbers the image suites' allowances
  read are the role table's (`Prima.LocusRoles`, `memory`), and so are the
  counted bounds, which `bounds/0` answers.

  Counted:

    * **Unread** (backends): 64 MiB over every session's buffered output
      and the stderr it keeps for its status, running or ended
      (`Locus.Backends.Backend`, "Unread").
    * **Answering**: backends 26 MiB, runtime 16, builds 8, the pool's
      share for what each service holds. The backends role counts each
      `recv` or `output` answer, and a status's collection and answer at
      their most, asked without waiting before the owners collect it and
      held to its write (`Locus.Backends.Service.status_room/1`, 7,359,488
      bytes for one owner); the builds role a build's reads and lines; the
      runtime each host call's answer, fetch head, piece and attached
      frame it hands a runner, CYFR's refusal of an attached fetch from its
      first piece, the answers of its own calls (`take_rate`, its own
      `egress_pin`, `runner_exited`) at twice what they declare until they
      are decoded, and a pinned fetch's larger read where it had room for
      it, asked without waiting: the read and the receive queue behind it,
      twice `fetch_read_ahead_bytes`, 524,288 bytes, to the fetch's end
      (`Locus.Runtime.Relay`, `Locus.Runtime.HostClient`).

  Not counted, each capped in size and in number:

    * **A held keeper connection's read**, every role: one read at a
      time, re-armed on its owner's word, of at most 65,541 bytes (a
      frame's 64 KiB payload and its 5-byte header,
      `Prima.KeeperProtocol`), handed to the owner as at most one message
      a stream with that stream's payloads of the read joined, so a read
      of the smallest frames is held as its bytes and no more, and held at
      most three times over at once (the socket's data, the frames parsed
      from it, its owner's join): 196,623 bytes a spawn. Spawns at once:
      the runtime's and the builds role's are at most their pools' uids,
      8 and 16 (`Prima.LocusRoles`), 1,572,984 and 3,145,968 bytes; the
      backends role's, scratch and kept alike, at most its admission
      limit over the least bound a spawn may have,
      floor(`LOCUS_BACKENDS_MEMORY_BUDGET` × `LOCUS_BACKENDS_MEMORY_OVERCOMMIT`
      / 16 MiB) (`Locus.Backends.Owners`, "Admission by memory";
      `Prima.KeeperProtocol.min_memory_bytes/0`), 112 at the defaults,
      22,021,776 bytes, and more as the overcommit, which has no ceiling,
      grows.
    * **A held keeper connection's writes**, every role: its writer
      sends a call's frames one at a time, each send waiting while the
      socket driver's queue is past gen_tcp's high watermark (8,192
      bytes), and answers its caller once the last send returned, so the
      driver queues at most one frame and the watermark, 73,733 bytes, one
      a spawn: runtime 589,864 bytes, builds 1,179,728, backends 8,258,096
      at the defaults. What waits to be written beyond it is the callers'
      own, at most four callers' writes a connection, waiting for its
      relay to attach or in its writer, each within its request's bound; a
      fifth is refused at once (`Locus.Keeper`).
    * **A relay connection's kernel queue**, every role: the relay's unix
      socket send buffer, 212,992 bytes (Linux's `net.core.wmem_default`),
      one a spawn: runtime 1,703,936 bytes, builds 3,407,872, backends
      23,855,104 at the defaults.
    * **An ending spawn's frames**, every role: what a spawn's relay
      carries between its release being asked, or its leader's exit
      reported, and the relay's end, while cyfr-locus kills its processes
      (at the release's grace, or 2 s past the leader's exit), is read on
      the owner's word, one read at a time, as the held read above; the
      owner counts and drops as it takes. An owner that owes its word and
      takes nothing for 5 s loses what the connection has not read, the
      connection closed, which ends the relay (`Locus.Keeper`). Only once
      the relay has ended is what it left on the connection read to the
      end and handed to the owner at once, without its word: at most the
      relay's socket queue and one read, 278,533 bytes, one a spawn being
      released.
    * **The piece a runtime holder reads ahead of the count**, the
      runtime: each poster, fetch and own call holds the piece its
      connection last handed it while it asks for room, one transport
      read of at most 64 KiB (`Locus.Runtime.Egress.transport_opts/1`),
      or a pinned fetch's larger read, which its room counts. Holders at
      once: 64 calls and 16 fetches a runner (the relay's bounds), each
      fetch with at most one own call at a time, so 96 a runner, 768 over
      8 runners: 48 MiB. A fetch's largest body, 50 MiB
      (`Prima.Limits.Ceiling`), through one 64 KiB read's receive window
      (about 45 KiB) comes at about 150 KB/s over a 300 ms round trip, in
      about 350 s, past a catalyst's default three minutes; through the
      256 KiB read's (about 192 KiB), at 430 to 560 KB/s, in 93 to 121 s.
    * **An attached fetch's unfinished frame**, the runtime: what is read
      of a frame not yet whole, under one frame, 65,541 bytes
      (`Prima.WorkerAuth.max_frame_bytes/0` and its header), 16 a runner,
      128 at once: 8 MiB.
    * **A pinned fetch's head as the HTTP client read it**, the runtime,
      held while the fetch's worker filters and hands it on: at most the
      client's header list bound, 256 KiB (Mint's default
      `max_header_list_size`, which the request's connect options cannot
      set), 128 at once: 32 MiB.
    * **A runner's relay frame as it is assembled**, the runtime: what the
      relay has read of a frame not yet whole, at most
      `Prima.RunnerRelay`'s 8 MiB frame bound, one a runner, 8 at once:
      64 MiB.
    * **A runner's host call body**, the runtime, as its poster sends it:
      at most `Prima.HostAPI.max_body_bytes/0`, 1 MiB, 64 a runner, 512 at
      once: 512 MiB.
    * **A backends session's unfinished line**: at most
      `Prima.LocusBackends.max_line_bytes/0`, 1 MiB, one a running
      session; running sessions are the backends role's spawns, 112 at
      the defaults.
    * **A request body as a listener reads it**, every role: at most the
      route's bound (the runtime's 1 MiB, a backends session's 16 MiB),
      one a connection, as many as the next row's.
    * **A TCP connection's send queue**, every listener: what the kernel
      holds of an answer once its write returned, at most Linux's default
      `net.ipv4.tcp_wmem` ceiling, 4,194,304 bytes, one a connection.
      Nothing in Locus caps a listener's connections (ThousandIsland's
      default is 16,384 an acceptor, 100 acceptors); its callers do. Each
      CYFR node reaches a listener through one Finch pool, which holds at
      most 50 HTTP/1 connections to it, Finch's default pool size: each of
      CYFR's three Locus clients (`Opus.WorkerClient` to the runtime,
      `Compendium.Builds.Client` to builds, `Sanctum.Egress` to backends
      for `Opus.Programs`) names `connect_options`, under which Req starts
      one Finch pool of the default size for each distinct set
      (`Req.Finch`), and each names one set, the backends client by
      waiting at least the connect timeout on every request
      (`Prima.Network.pin/3`). So 50 a CYFR node, 209,715,200 bytes, times
      the CYFR nodes the operator runs.
    * **A relay process of cyfr-locus's**: fixed buffers, part of the
      service's idle figure.
    * **The runtime VM's freed segments**: the allocator keeps up to ten
      freed multiblock carriers cached for reuse (`+MMmcs`), each at most
      the base64 of the largest answer's frame, 6,990,508 bytes: 69,905,080
      bytes, held on whatever the count holds.

  ## Resident memory

  A held byte costs its service more than a byte. The backends image under
  memory pressure measured a buffered byte costing the service's group 2.3
  to 2.8 bytes; main's image suites carry no such factor. Its flood of 31
  unread sessions, each read one keeper read at a time, raised the group
  166 MiB over idle for 63 MiB counted on four processors, as a CI runner
  has (2.6), and 208 to 227 MiB on sixteen (3.3 to 3.6), since the
  allocator keeps carriers for each scheduler. The VM makes resident
  memory that multiple of what is held: a refc binary a process has let go
  stays resident until that process's next collection, and its binary
  virtual heap lets such garbage reach about the live amount before one; a
  collection copies the live heap, so it is briefly twice; and the
  allocator keeps freed carriers mapped. So
  each image proof allows its service's group the factor, 2.8
  (`byte_cost`), times the counted bounds and the uncounted kinds its case
  fills, and the kernel's queues it fills, and prints what it measured
  beside that.
  """

  use GenServer

  # Each role's counted bounds, the role table's (`Prima.LocusRoles`).
  @bounds Map.new(
            Prima.LocusRoles.roles(),
            &{&1.name, Map.take(&1.memory, [:unread, :answering])}
          )

  @servers %{
    backends: Locus.Output.Backends,
    runtime: Locus.Output.Runtime,
    builds: Locus.Output.Builds
  }

  # A blocking reserve waits this long past its deadline for the server's
  # own `:full`, which comes at the deadline.
  @answer_margin_ms 5_000

  @typedoc "A role of a Locus node."
  @type role :: :backends | :runtime | :builds

  @typedoc "A role's bounds, in bytes: nil where the role keeps nothing unread."
  @type bounds :: %{unread: pos_integer() | nil, answering: pos_integer()}

  @typedoc "Bytes granted to a holder until it returns them."
  @opaque grant :: {__MODULE__, GenServer.server(), reference()}

  @typedoc "What a role holds now, and the most it has held since it started."
  @type held :: %{
          unread: non_neg_integer(),
          answering: non_neg_integer(),
          owed: non_neg_integer(),
          owing: non_neg_integer(),
          waiting: non_neg_integer(),
          unread_peak: non_neg_integer(),
          answering_peak: non_neg_integer()
        }

  @doc "Every role's bounds."
  @spec bounds() :: %{role() => bounds()}
  def bounds, do: @bounds

  @doc "The registered name of a role's count."
  @spec server(role()) :: atom()
  def server(role) when is_map_key(@servers, role), do: Map.fetch!(@servers, role)

  @doc false
  def child_spec(role) when is_atom(role),
    do: %{id: {__MODULE__, role}, start: {__MODULE__, :start_link, [role]}}

  def child_spec(opts) when is_list(opts),
    do: %{
      id: {__MODULE__, Keyword.get_lazy(opts, :name, &make_ref/0)},
      start: {__MODULE__, :start_link, [opts]}
    }

  @doc """
  Start a role's count under its name, or, with options, a count with
  `:bounds` of its own (a suite's), named `:name` where given.
  """
  @spec start_link(role() | keyword()) :: GenServer.on_start()
  def start_link(role) when is_map_key(@servers, role),
    do: GenServer.start_link(__MODULE__, Map.fetch!(@bounds, role), name: server(role))

  def start_link(opts) when is_list(opts) do
    bounds = Map.merge(%{unread: nil}, Map.new(Keyword.fetch!(opts, :bounds)))
    GenServer.start_link(__MODULE__, bounds, Keyword.take(opts, [:name]))
  end

  # ————— unread —————

  @doc """
  The calling holder's whole unread holding is `bytes` now. `:ok`, or
  `{:drop_to, bytes}`: the caller holds most and is to drop its oldest
  until it holds at most that, then hold again.
  """
  @spec hold(GenServer.server(), non_neg_integer()) :: :ok | {:drop_to, non_neg_integer()}
  def hold(server, bytes) when is_integer(bytes) and bytes >= 0,
    do: GenServer.call(server, {:hold, bytes}, :infinity)

  # ————— answering —————

  @doc """
  Ask for `bytes` of the answering count, for the calling process, by
  `deadline` (monotonic milliseconds): the answer comes as
  `{Locus.Output, ref, {:ok, grant} | :full}`.
  """
  @spec ask(GenServer.server(), pos_integer(), integer()) :: reference()
  def ask(server, bytes, deadline)
      when is_integer(bytes) and bytes > 0 and is_integer(deadline) do
    ref = make_ref()
    GenServer.cast(server, {:ask, ref, self(), bytes, deadline})
    ref
  end

  @doc "`ask/3`, waiting for its answer: `{:ok, grant}` or `:full`."
  @spec reserve(GenServer.server(), pos_integer(), integer()) :: {:ok, grant()} | :full
  def reserve(server, bytes, deadline) do
    ref = ask(server, bytes, deadline)
    wait = max(deadline - now(), 0) + @answer_margin_ms

    receive do
      {__MODULE__, ^ref, answer} -> answer
    after
      wait ->
        # A count that did not answer by then is down or wedged: nothing
        # is taken as granted, and a late grant goes back.
        cancel(server, ref)
        :full
    end
  end

  @doc """
  The asker's word that it wants no answer to its `ask/3` of `ref`: an ask
  still waiting leaves the queue, and a grant made for it, received or
  not, goes back.
  """
  @spec cancel(GenServer.server(), reference()) :: :ok
  def cancel(server, ref) when is_reference(ref), do: GenServer.cast(server, {:cancel, ref})

  @doc "Move a grant to `pid`, the process the bytes are handed to."
  @spec give(grant(), pid()) :: :ok
  def give({__MODULE__, server, ref}, pid) when is_pid(pid),
    do: GenServer.call(server, {:give, ref, pid}, :infinity)

  @doc "The holder's word that a grant's bytes are gone."
  @spec return(grant()) :: :ok
  def return({__MODULE__, server, ref}), do: GenServer.cast(server, {:return, ref})

  @doc "What the count holds now, and the most it has held."
  @spec held(GenServer.server()) :: held()
  def held(server), do: GenServer.call(server, :held, :infinity)

  defp now, do: System.monotonic_time(:millisecond)

  # ————— the server —————

  @impl GenServer
  def init(bounds) do
    {:ok,
     %{
       bounds: bounds,
       # Each holder's unread bytes and their total, and the target each
       # holder told to drop owes down to: what it owes is what it holds
       # above it.
       unread: %{},
       targets: %{},
       unread_total: 0,
       # Each grant by its ref: its holder and its bytes.
       grants: %{},
       answering_total: 0,
       # The asks not yet granted, in arrival order, and each by its ref.
       queue: :queue.new(),
       waiters: %{},
       monitors: %{},
       peaks: %{unread: 0, answering: 0}
     }}
  end

  @impl GenServer
  def handle_call({:hold, bytes}, {pid, _tag}, state) do
    state = state |> put_unread(pid, bytes) |> watch(pid)

    {reply, state} =
      case state.targets do
        # A holder told to drop that holds above its target drops to it
        # now, in its own call: its debt is never anyone else's.
        %{^pid => target} when bytes > target ->
          {{:drop_to, target}, state}

        _paid_or_none ->
          over(%{state | targets: Map.delete(state.targets, pid)}, pid)
      end

    {:reply, reply, state |> forget_if_idle(pid) |> peak()}
  end

  def handle_call({:give, ref, pid}, _from, state) do
    case state.grants do
      %{^ref => {holder, bytes}} ->
        state = %{state | grants: Map.put(state.grants, ref, {pid, bytes})}
        {:reply, :ok, state |> watch(pid) |> forget_if_idle(holder)}

      _gone ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:held, _from, state) do
    {:reply,
     %{
       unread: state.unread_total,
       answering: state.answering_total,
       owed: owed(state),
       owing: map_size(state.targets),
       waiting: map_size(state.waiters),
       unread_peak: state.peaks.unread,
       answering_peak: state.peaks.answering
     }, state}
  end

  @impl GenServer
  def handle_cast({:ask, ref, pid, bytes, deadline}, state) do
    state = watch(state, pid)

    cond do
      bytes > state.bounds.answering ->
        send(pid, {__MODULE__, ref, :full})
        {:noreply, forget_if_idle(state, pid)}

      :queue.is_empty(state.queue) and fits?(state, bytes) ->
        {:noreply, state |> grant(ref, pid, bytes) |> peak()}

      deadline <= now() ->
        send(pid, {__MODULE__, ref, :full})
        {:noreply, forget_if_idle(state, pid)}

      true ->
        timer = Process.send_after(self(), {:deadline, ref}, deadline, abs: true)
        waiter = %{pid: pid, bytes: bytes, timer: timer}

        {:noreply,
         %{
           state
           | queue: :queue.in(ref, state.queue),
             waiters: Map.put(state.waiters, ref, waiter)
         }}
    end
  end

  def handle_cast({:return, ref}, state), do: {:noreply, state |> release(ref) |> pump()}

  def handle_cast({:cancel, ref}, state) do
    state =
      case Map.pop(state.waiters, ref) do
        {nil, _waiters} ->
          release(state, ref)

        {waiter, waiters} ->
          Process.cancel_timer(waiter.timer)

          %{state | waiters: waiters, queue: :queue.delete(ref, state.queue)}
          |> forget_if_idle(waiter.pid)
      end

    {:noreply, pump(state)}
  end

  @impl GenServer
  def handle_info({:deadline, ref}, state) do
    case Map.pop(state.waiters, ref) do
      {nil, _waiters} ->
        {:noreply, state}

      {waiter, waiters} ->
        send(waiter.pid, {__MODULE__, ref, :full})

        state =
          %{state | waiters: waiters, queue: :queue.delete(ref, state.queue)}
          |> forget_if_idle(waiter.pid)

        {:noreply, pump(state)}
    end
  end

  # A holder that died held nothing more: its memory is gone with it.
  def handle_info({:DOWN, _monitor, :process, pid, _reason}, state) do
    state = %{state | monitors: Map.delete(state.monitors, pid)}
    state = put_unread(state, pid, 0)
    state = %{state | targets: Map.delete(state.targets, pid)}

    held = for {ref, {^pid, _bytes}} <- state.grants, do: ref
    state = Enum.reduce(held, state, &release(&2, &1))

    asked = for {ref, %{pid: ^pid}} <- state.waiters, do: ref

    state =
      Enum.reduce(asked, state, fn ref, state ->
        Process.cancel_timer(state.waiters[ref].timer)

        %{
          state
          | waiters: Map.delete(state.waiters, ref),
            queue: :queue.delete(ref, state.queue)
        }
      end)

    {:noreply, pump(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ————— unread —————

  defp put_unread(state, pid, 0) do
    {old, unread} = Map.pop(state.unread, pid, 0)
    %{state | unread: unread, unread_total: state.unread_total - old}
  end

  defp put_unread(state, pid, bytes) do
    old = Map.get(state.unread, pid, 0)

    %{
      state
      | unread: Map.put(state.unread, pid, bytes),
        unread_total: state.unread_total - old + bytes
    }
  end

  # Past the bound, beyond what the holders told already owe, the holder
  # holding most of those with no target is given one, its holding less
  # the excess. The caller has none (it paid what it owed, or never owed),
  # so one always is.
  defp over(%{bounds: %{unread: nil}} = state, _caller), do: {:ok, state}

  defp over(state, caller) do
    excess = state.unread_total - owed(state) - state.bounds.unread

    eligible =
      Enum.reject(state.unread, fn {pid, _bytes} -> is_map_key(state.targets, pid) end)

    if excess > 0 and eligible != [] do
      {most, bytes} = Enum.max_by(eligible, fn {pid, bytes} -> {bytes, pid == caller} end)
      target = max(bytes - excess, 0)
      state = %{state | targets: Map.put(state.targets, most, target)}

      if most == caller do
        {{:drop_to, target}, state}
      else
        send(most, {__MODULE__, :over})
        {:ok, state}
      end
    else
      {:ok, state}
    end
  end

  # What the holders told to drop owe: each what it holds above its target.
  defp owed(state) do
    Enum.reduce(state.targets, 0, fn {pid, target}, owed ->
      owed + max(Map.get(state.unread, pid, 0) - target, 0)
    end)
  end

  # ————— answering —————

  defp fits?(state, bytes), do: state.answering_total + bytes <= state.bounds.answering

  defp grant(state, ref, pid, bytes) do
    send(pid, {__MODULE__, ref, {:ok, {__MODULE__, self(), ref}}})

    %{
      state
      | grants: Map.put(state.grants, ref, {pid, bytes}),
        answering_total: state.answering_total + bytes
    }
  end

  defp release(state, ref) do
    case Map.pop(state.grants, ref) do
      {nil, _grants} ->
        state

      {{holder, bytes}, grants} ->
        %{state | grants: grants, answering_total: state.answering_total - bytes}
        |> forget_if_idle(holder)
    end
  end

  # The asks are granted in arrival order: the first that does not fit
  # holds every one behind it.
  defp pump(state) do
    with {:value, ref} <- :queue.peek(state.queue),
         %{bytes: bytes, pid: pid, timer: timer} <- state.waiters[ref],
         true <- fits?(state, bytes) do
      Process.cancel_timer(timer)

      %{state | queue: :queue.drop(state.queue), waiters: Map.delete(state.waiters, ref)}
      |> grant(ref, pid, bytes)
      |> peak()
      |> pump()
    else
      _ -> state
    end
  end

  # ————— holders —————

  defp watch(state, pid) do
    if is_map_key(state.monitors, pid),
      do: state,
      else: %{state | monitors: Map.put(state.monitors, pid, Process.monitor(pid))}
  end

  defp forget_if_idle(state, pid) do
    holds? =
      is_map_key(state.unread, pid) or is_map_key(state.targets, pid) or
        Enum.any?(state.grants, fn {_ref, {holder, _bytes}} -> holder == pid end) or
        Enum.any?(state.waiters, fn {_ref, waiter} -> waiter.pid == pid end)

    case state.monitors do
      %{^pid => monitor} when not holds? ->
        Process.demonitor(monitor, [:flush])
        %{state | monitors: Map.delete(state.monitors, pid)}

      _ ->
        state
    end
  end

  defp peak(state) do
    %{
      state
      | peaks: %{
          unread: max(state.peaks.unread, state.unread_total),
          answering: max(state.peaks.answering, state.answering_total)
        }
    }
  end
end
