# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Programs.Pipe do
  @moduledoc """
  One pipe session's courier: a `run` session of a program row under one
  key, in a login entry's kept home, carried between the attempts that
  open it (`Opus.Programs.pipe_open/6`) and the box that owns it.

  The box owns every pipe session (`Opus.Programs.Box`): it records an
  open before the backend is asked, makes it itself, gives the session it
  answers to the open that asked while its caller waits inside the
  deadline, closes any other, and owes every close until the backend
  confirms it. The holder holds the row's owner (`Opus.Programs.hold/2`),
  which the box's opens for it need, and keeps nothing the box does not:
  the session the box gave it, so attempts find it by id, and for each
  attempt that opened it what that open answered, so a repeat by the same
  attempt answers as the first did and only an attempt that opened the
  session uses it (`use/4`). A send or a read runs in its caller's process
  under the holder's grant, apart from the holder, so a long read never
  delays a send; the box's open is awaited by a process of the holder's
  own, so an open never delays them either.

  The holder belongs to the row, the home and the key, never to an
  attempt. It ends on `close`, when no attempt used it for the box's idle
  period and a little more (by then the box has ended a session no line
  used), when the box tells it to stand down or issues a new grant (the
  row was disabled, deleted or changed, or the service the session ran on
  is gone), and when its login entry is revoked, suspended or deleted
  (`{:entry_ended, athanor_id, entry_id}`, `Opus.Programs.end_mounts/2`,
  which a sweep also sends for an entry that no longer serves without a
  signal having said so). However it ends, killed included, the box closes
  its session; on its way out it asks so itself, which is the fast path.
  Nothing of what passes through is kept here.
  """

  use GenServer, restart: :temporary

  # The most attempts whose open answer is kept: the oldest is forgotten,
  # and must open again before it uses the session.
  @max_openers 64
  # Beyond the box's idle period, so the box has ended an unused session.
  @idle_slack_ms 2_000
  # How long a holder whose first open has not held the owner lives.
  @first_open_ms 60_000

  @doc false
  def start_link(args),
    do: GenServer.start_link(__MODULE__, args, name: Keyword.fetch!(args, :name))

  # A holder starts holding nothing: its first open holds the owner, under
  # that open's deadline.
  @impl true
  def init(args) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       owner: Keyword.fetch!(args, :owner),
       grant: nil,
       program: Keyword.fetch!(args, :program),
       row_name: Keyword.fetch!(args, :row_name),
       home_id: Keyword.fetch!(args, :home_id),
       key: Keyword.fetch!(args, :key),
       session: nil,
       openers: %{},
       opens: %{},
       idle: Process.send_after(self(), :idle, @first_open_ms)
     }}
  end

  # The owner is held here, inside the deadline, since the box records the
  # process that holds it; the box's open is awaited by a process of this
  # holder's, and the box answers it by the deadline.
  @impl true
  def handle_call({:open, opener, argv, deadline}, from, state) do
    case hold(state, deadline) do
      {:ok, state} ->
        ref = make_ref()
        holder = self()
        owner = state.owner
        params = %{program: state.program, home_id: state.home_id, key: state.key, argv: argv}

        spawn_link(fn ->
          send(
            holder,
            {:opened, ref, Opus.Programs.pipe_box_open(owner, holder, params, deadline)}
          )
        end)

        {:noreply, %{state | opens: Map.put(state.opens, ref, %{from: from, opener: opener})}}

      {:error, reason} when state.session == nil and map_size(state.opens) == 0 ->
        {:stop, :normal, {:error, reason}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:use, athanor_id, opener, session}, _from, state) do
    if yours?(state, athanor_id, opener, session),
      do: {:reply, {:ok, state.grant}, idle(state)},
      else: {:reply, {:error, :denied}, state}
  end

  def handle_call(:mount, _from, state),
    do: {:reply, {state.owner.athanor_id, state.home_id, state.row_name}, state}

  def handle_call({:close, athanor_id, opener, session}, _from, state) do
    if yours?(state, athanor_id, opener, session),
      do: {:stop, :normal, :ok, state},
      else: {:reply, {:error, :denied}, state}
  end

  @impl true
  def handle_cast({:entry_ended, athanor_id, entry_id}, %{home_id: entry_id} = state) do
    if state.owner.athanor_id == athanor_id,
      do: {:stop, :normal, state},
      else: {:noreply, state}
  end

  def handle_cast({:entry_ended, _athanor_id, _entry_id}, state), do: {:noreply, state}

  # What the box gave, carried to the caller: the session it gave this
  # key, or why it gave none.
  @impl true
  def handle_info({:opened, ref, result}, %{opens: opens} = state) when is_map_key(opens, ref) do
    {open, opens} = Map.pop(opens, ref)
    state = %{state | opens: opens}

    case result do
      {:ok, %{session: session, resumed: resumed}} ->
        answer = %{session: session, resumed: answered(state, open.opener, session, resumed)}
        state = state |> session(session) |> remember(open.opener, answer) |> idle()
        GenServer.reply(open.from, {:ok, answer})
        {:noreply, state}

      {:error, reason} ->
        GenServer.reply(open.from, {:error, reason})
        settle(state)
    end
  end

  def handle_info(:idle, %{opens: opens} = state) when map_size(opens) > 0,
    do: {:noreply, idle(%{state | idle: nil})}

  def handle_info(:idle, state), do: {:stop, :normal, state}

  def handle_info({Opus.Programs, :stand_down, _key}, state), do: {:stop, :normal, state}

  # A new grant means the box synced the owner again: the service the
  # session ran on is not the one it runs on now.
  def handle_info({Opus.Programs, :owner, _grant}, state), do: {:stop, :normal, state}

  # A courier of an open ends once it has carried the box's answer.
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info(message, state) do
    Prima.LoggerContext.unexpected(__MODULE__, message)
    {:noreply, state}
  end

  # The fast path: the box closes what a holder leaves however it ends.
  @impl true
  def terminate(_reason, state) do
    if state.grant do
      _ = Opus.Programs.pipe_box_close(state.owner, state.home_id, state.key)
      Opus.Programs.release(state.owner)
    end

    :ok
  end

  @impl true
  def format_status(status), do: Opus.Programs.StatusRedaction.format_status(status)

  # A holder with no session and no open still out has nothing to keep.
  defp settle(%{session: nil, opens: opens} = state) when map_size(opens) == 0,
    do: {:stop, :normal, state}

  defp settle(state), do: {:noreply, state}

  # The owner, held under the deadline when this holder holds none. A hold
  # the box answers too late still registers this holder, whose stop then
  # releases it.
  defp hold(%{grant: nil} = state, deadline) do
    case deadline - System.system_time(:millisecond) do
      ms when ms > 0 ->
        with {:ok, grant} <- Opus.Programs.hold(state.owner, ms),
             do: {:ok, %{state | grant: grant}}

      _passed ->
        {:error, :deadline}
    end
  end

  defp hold(state, _deadline), do: {:ok, state}

  # A repeat open by an attempt of the session it was answered before
  # answers as the first did; any other open answers what the box said.
  defp answered(state, opener, session, resumed) do
    case state.openers do
      %{^opener => %{session: ^session, resumed: first}} -> first
      _ -> resumed
    end
  end

  # The session the box gave: a program started again has a new id, and
  # its holder is found by it from then on.
  defp session(%{session: session} = state, session), do: state

  defp session(state, session) do
    if state.session,
      do: Registry.unregister(Opus.Programs.Registry, {:pipe_session, state.session})

    {:ok, _} = Registry.register(Opus.Programs.Registry, {:pipe_session, session}, nil)
    %{state | session: session}
  end

  defp remember(state, opener, answer) do
    openers = Map.put(state.openers, opener, Map.put(answer, :at, System.monotonic_time()))

    openers =
      if map_size(openers) > @max_openers do
        {oldest, _} = Enum.min_by(openers, fn {_opener, %{at: at}} -> at end)
        Map.delete(openers, oldest)
      else
        openers
      end

    %{state | openers: openers}
  end

  defp yours?(state, athanor_id, opener, session) do
    state.owner.athanor_id == athanor_id and state.session == session and
      match?(%{^opener => %{session: ^session}}, state.openers)
  end

  defp idle(%{grant: nil} = state), do: state

  defp idle(state) do
    if state.idle, do: Process.cancel_timer(state.idle)
    %{state | idle: Process.send_after(self(), :idle, state.grant.idle_ms + @idle_slack_ms)}
  end
end
