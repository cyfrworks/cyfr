# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Programs.Pipe do
  @moduledoc """
  One pipe session: a `run` session of a program row under one key, in a
  login entry's kept home, held for the catalysts that open it
  (`Opus.Programs.pipe_open/6`).

  The holder belongs to the row, the home and the key, never to an
  attempt: it holds the row's owner (`Opus.Programs.hold/2`) and opens its
  session on the box whenever an attempt opens the key, so a later attempt
  attaches to the session while its program runs and a program that ended
  is started again (`resumed: false`). It records, for each attempt that
  opened it, what that open answered, so a repeat by the same attempt
  answers as the first did while the session is the same; only an attempt
  that opened the session may use it (`use/4`). A send or a read runs in
  its caller's process under the holder's grant, apart from the holder, so
  a long read never delays a send.

  An open acts under its caller's deadline (`Opus.Host.Pipe.deadline/1`):
  the owner's acquisition, a retry after a stale grant and the box's open
  all fit it. An open the box answers after the deadline closes the
  session it started (one it only attached to runs on for the attempts
  that opened it) and answers `:deadline`.

  The box owns what the holder opened: each session is recorded on the
  owner's entry for its holder (`Opus.Programs.pipe_session/2`), and a
  holder that dies for any reason, killed included, has its session closed
  and its share of the owner released by the box. The holder's own close
  and release on the way out are the fast path.

  It ends, closing its session and releasing its owner, on `close`, when
  no attempt used it for the box's idle period and a little more (by then
  the box has ended a session no line used), when the box tells it to
  stand down or issues a new grant (the row was disabled, deleted or
  changed, or the service the session ran on is gone), and when its login
  entry is revoked, suspended or deleted (`{:entry_ended, athanor_id,
  entry_id}`, `Opus.Programs.end_mounts/2`, which a sweep also sends for
  an entry that no longer serves without a signal having said so). Nothing
  of what passes through is kept here.
  """

  use GenServer, restart: :temporary

  alias Opus.Programs.Session

  # The most attempts whose open answer is kept: the oldest is forgotten,
  # and must open again before it uses the session.
  @max_openers 64
  # Beyond the box's idle period, so the box has ended an unused session.
  @idle_slack_ms 2_000
  # How long a holder whose first open has not held the owner lives.
  @first_open_ms 60_000
  # How long past its caller's deadline a box's open is still heard, and
  # the longest a late open's close is waited for.
  @late_open_ms 30_000
  @late_close_ms 5_000
  # A refusal that says this grant's owner is not on the service any more:
  # held again and asked once more.
  @stale [:stale_boot, :epoch_ahead, :unknown_owner, :lapsed]

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
  # process that holds it; the box's open runs in a process of its own, and
  # the caller is answered by the deadline whether or not it has finished.
  @impl true
  def handle_call({:open, opener, argv, deadline}, from, state) do
    case hold(state, deadline) do
      {:ok, state} -> {:noreply, start_open(state, from, opener, argv, deadline, true)}
      {:error, reason} when state.session == nil -> {:stop, :normal, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
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

  @impl true
  def handle_info({:opened, ref, result}, %{opens: opens} = state) when is_map_key(opens, ref) do
    {open, opens} = Map.pop(opens, ref)
    if open.timer, do: Process.cancel_timer(open.timer)
    opened(%{state | opens: opens}, open, result)
  end

  # The caller's deadline passed with the box's open still out: the caller
  # is told so, and the open, should it finish, is closed again.
  def handle_info({:deadline, ref}, %{opens: opens} = state) when is_map_key(opens, ref) do
    open = opens[ref]
    GenServer.reply(open.from, {:error, :deadline})
    {:noreply, %{state | opens: Map.put(opens, ref, %{open | from: nil, timer: nil})}}
  end

  def handle_info({:deadline, _ref}, state), do: {:noreply, state}

  def handle_info(:idle, %{opens: opens} = state) when map_size(opens) > 0,
    do: {:noreply, %{state | idle: nil} |> idle()}

  def handle_info(:idle, state), do: {:stop, :normal, state}

  def handle_info({Opus.Programs, :stand_down, _key}, state), do: {:stop, :normal, state}

  # A new grant means the box synced the owner again: the service the
  # session ran on is not the one it runs on now.
  def handle_info({Opus.Programs, :owner, _grant}, state), do: {:stop, :normal, state}

  # An open's own process ends once it has said how its open went.
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info(message, state) do
    Prima.LoggerContext.unexpected(__MODULE__, message)
    {:noreply, state}
  end

  # The fast path: the box closes what a holder leaves behind however it
  # ends, this included.
  @impl true
  def terminate(_reason, state) do
    if state.grant && state.session, do: _ = Session.close(state.grant, state.session)
    if state.grant, do: Opus.Programs.release(state.owner)
    :ok
  end

  @impl true
  def format_status(status), do: Opus.Programs.StatusRedaction.format_status(status)

  # The box's open of the key's session, in a process of its own: it
  # attaches to the session while it runs, or starts the program with
  # `argv`, and says how it went. Its wait reaches past the deadline, so a
  # late completion is still heard and closed.
  defp start_open(state, from, opener, argv, deadline, retry?) do
    ref = make_ref()
    holder = self()
    grant = state.grant

    params = %{
      program: state.program,
      home_id: state.home_id,
      key: state.key,
      mode: :run,
      argv: argv,
      timeout_ms: max(deadline - now(), 0) + @late_open_ms
    }

    spawn_link(fn -> send(holder, {:opened, ref, Session.open(grant, params)}) end)
    timer = Process.send_after(self(), {:deadline, ref}, max(deadline - now(), 0))

    open = %{from: from, opener: opener, argv: argv, deadline: deadline, retry?: retry?}
    %{state | opens: Map.put(state.opens, ref, Map.put(open, :timer, timer))}
  end

  # How an open went. One whose caller still waits is answered; one whose
  # caller's deadline passed closes a program it started. A refusal saying
  # the owner is not on the service any more holds it again and asks once
  # more, inside the same deadline.
  defp opened(state, %{from: nil}, {:ok, %{session: session, resumed: resumed}}),
    do: late(state, session, resumed)

  defp opened(state, %{from: nil}, _refused), do: settle(state)

  defp opened(state, open, {:ok, %{session: session, resumed: resumed}}) do
    answer = %{session: session, resumed: answered(state, open.opener, session, resumed)}
    state = state |> session(session) |> remember(open.opener, answer) |> idle()
    GenServer.reply(open.from, {:ok, answer})
    {:noreply, state}
  end

  defp opened(state, %{retry?: true} = open, {:error, {:refused, code, boot}})
       when code in @stale do
    if code == :stale_boot and is_binary(boot), do: Opus.Programs.boot_seen(boot)

    case hold(%{state | grant: nil}, open.deadline) do
      {:ok, state} ->
        {:noreply, start_open(state, open.from, open.opener, open.argv, open.deadline, false)}

      {:error, reason} ->
        GenServer.reply(open.from, {:error, reason})
        {:stop, :normal, state}
    end
  end

  defp opened(state, open, {:error, reason}) do
    GenServer.reply(open.from, {:error, reason})
    settle(state)
  end

  # A holder with no session and no open still out has nothing to keep.
  defp settle(%{session: nil, opens: opens} = state) when map_size(opens) == 0,
    do: {:stop, :normal, state}

  defp settle(state), do: {:noreply, state}

  # The owner, held under the deadline when this holder holds none. A hold
  # the box answers too late still registers this holder, whose stop then
  # releases it.
  defp hold(%{grant: nil} = state, deadline) do
    with {:ok, timeout} <- left(deadline),
         {:ok, grant} <- Opus.Programs.hold(state.owner, timeout) do
      {:ok, %{state | grant: grant}}
    end
  end

  defp hold(state, _deadline), do: {:ok, state}

  defp left(deadline) do
    case deadline - now() do
      ms when ms > 0 -> {:ok, ms}
      _passed -> {:error, :deadline}
    end
  end

  defp now, do: System.system_time(:millisecond)

  # An open that finished after its caller's deadline: no one learns of
  # its session, so a program it started is closed again. One it only
  # attached to runs on for the attempts that opened it.
  defp late(state, session, resumed) do
    if not resumed, do: _ = Session.close(state.grant, session, @late_close_ms)

    state =
      if not resumed and state.session == session,
        do: %{state | session: nil},
        else: state

    settle(state)
  end

  # A repeat open by an attempt of the session it was answered before
  # answers as the first did; any other open answers what the box said.
  defp answered(state, opener, session, resumed) do
    case state.openers do
      %{^opener => %{session: ^session, resumed: first}} -> first
      _ -> resumed
    end
  end

  # The session the box answered: a program started again has a new id,
  # its holder is found by it from then on, and the box records it as this
  # holder's to close.
  defp session(%{session: session} = state, session), do: state

  defp session(state, session) do
    if state.session,
      do: Registry.unregister(Opus.Programs.Registry, {:pipe_session, state.session})

    {:ok, _} = Registry.register(Opus.Programs.Registry, {:pipe_session, session}, nil)
    _ = Opus.Programs.pipe_session(state.owner, session)
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
