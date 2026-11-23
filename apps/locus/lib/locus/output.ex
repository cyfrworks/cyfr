# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Output do
  @moduledoc """
  The one count of the output a role of a Locus node holds in its own
  memory, to the role's bound (`bounds/0`): what the backends service keeps
  unread for its sessions' readers, and what each service has taken out to
  answer or send on. One process per role (`server/1`), started by
  `Locus.Application` before the roles' children.

  A count is freed only on its holder's word: a `hold/2` naming less, a
  `return/1`, or the holder's death, which is the runtime's word that its
  memory is gone. Nothing is freed for a timeout, a refusal or a lost
  connection.

  ## Unread

  A holder (a backends session) names its whole unread holding with
  `hold/2` after every change of it. Past the role's unread bound, the
  holder holding most of those not already dropping is asked to drop its
  oldest: the caller itself is answered `{:drop_to, bytes}` and holds again
  once it has; any other is sent `{Locus.Output, :over}` and holds again
  when it reads it, at its next message turn. No holder waits on another,
  so the count may sit over its bound while a holder told to drop has not
  yet held again: each such holder owes the excess it was assigned, at
  most the one increment of the hold that passed the bound, and is not
  assigned another until it holds again. The count therefore passes its
  bound by at most the sum of what the holders told and not yet heard from
  owe: at most one per-hold increment for each of them, until each one's
  next hold.

  ## Answering

  Bytes taken out to be answered or sent on (a session's answer, a fetch's
  piece, a host call's answer, a build's reads and lines) are asked for
  before they are made (`ask/3`, `reserve/3`): granted in arrival order
  when the role's answering bound has room, or answered `:full` at the
  asker's deadline, a monotonic instant in milliseconds. A request larger
  than the bound is `:full` at once. The grant is the asker's; `give/2`
  moves it to the process the bytes are handed to, and `return/1` is its
  holder's word that they are gone.
  """

  use GenServer

  @mib 1_048_576

  # 2.9's numbers. The unread bound is the backends service's alone; every
  # role bounds what it is answering.
  @bounds %{
    backends: %{unread: 64 * @mib, answering: 26 * @mib},
    runtime: %{unread: nil, answering: 16 * @mib},
    builds: %{unread: nil, answering: 8 * @mib}
  }

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
    do: %{id: {__MODULE__, Keyword.fetch!(opts, :name)}, start: {__MODULE__, :start_link, [opts]}}

  @doc """
  Start a role's count under its name, or, with options, a count named
  `:name` with `:bounds` of its own (a suite's).
  """
  @spec start_link(role() | keyword()) :: GenServer.on_start()
  def start_link(role) when is_map_key(@servers, role),
    do: GenServer.start_link(__MODULE__, Map.fetch!(@bounds, role), name: server(role))

  def start_link(opts) when is_list(opts) do
    bounds = Map.merge(%{unread: nil}, Map.new(Keyword.fetch!(opts, :bounds)))
    GenServer.start_link(__MODULE__, bounds, name: Keyword.fetch!(opts, :name))
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
        GenServer.cast(server, {:cancel, ref})
        :full
    end
  end

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
       # Each holder's unread bytes, the excess each holder told to drop
       # owes until it holds again, and their total.
       unread: %{},
       owed: %{},
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
    state =
      state
      |> put_unread(pid, bytes)
      |> Map.update!(:owed, &Map.delete(&1, pid))
      |> watch(pid)

    {reply, state} = over(state, pid)
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
       owed: state.owed |> Map.values() |> Enum.sum(),
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
    state = %{state | owed: Map.delete(state.owed, pid)}

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
  # holding most of those owing nothing is assigned the excess. The caller
  # owes nothing (its hold cleared what it owed), so one always is.
  defp over(%{bounds: %{unread: nil}} = state, _caller), do: {:ok, state}

  defp over(state, caller) do
    owed = state.owed |> Map.values() |> Enum.sum()
    excess = state.unread_total - owed - state.bounds.unread

    eligible = Enum.reject(state.unread, fn {pid, _bytes} -> is_map_key(state.owed, pid) end)

    if excess > 0 and eligible != [] do
      {most, bytes} = Enum.max_by(eligible, fn {pid, bytes} -> {bytes, pid == caller} end)
      state = %{state | owed: Map.put(state.owed, most, excess)}

      if most == caller do
        {{:drop_to, max(bytes - excess, 0)}, state}
      else
        send(most, {__MODULE__, :over})
        {:ok, state}
      end
    else
      {:ok, state}
    end
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
      is_map_key(state.unread, pid) or is_map_key(state.owed, pid) or
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
