# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Programs.Terminal do
  @moduledoc """
  One terminal session of a program row: the row's command, with the
  arguments its starter gave, on a pseudo-terminal of the backends
  service, owned by the server for one athanor and one person, never by
  a page or a browser credential (`Opus.Programs.start/3`).

  The process holds the row's owner (`Opus.Programs.hold/2`) and asks the
  box for the session under a key that is its own id, so every start is
  a session of its own; the box records that open before the backend is
  asked and settles whatever the backend answers under the key
  (`Opus.Programs.Box`). An open the box answers past its deadline
  refuses the start, the process ends, and the box closes the late
  session. A reader of its own reads the session's output for the
  process's life, one `output` at a time naming the last chunk it was
  answered, so a lost answer is replayed.

  Any number of processes attach to it (`attach/3`), each monitored:
  each is answered the last #{div(256 * 1024, 1024)} KiB of output and the
  terminal's size, then hears `{Opus.Programs, id, {:bytes, delivery,
  output}}` for what the program writes, each delivery named by a token
  of its own that cannot be guessed, and `{Opus.Programs, id, {:ended,
  reason}}` once. A detach, or an
  attached process's exit, ends nothing.

  Nothing a program prints can grow memory here without bound. The
  reader asks the service for the next output only once this process has
  taken the last, so what a program prints faster than it is taken waits
  in the service's own bounded buffer, which drops its oldest. An
  attached process is handed the next output only once it has said it
  took the last by its token (`Opus.Programs.taken/3`, which a page says
  once its browser has drawn it), so one delivery at most is ever
  unacknowledged for it, whatever it sends, and an acknowledgement
  proves the delivery reached it; what comes meanwhile is kept
  for it, at most the last #{div(256 * 1024, 1024)} KiB, and handed whole
  as `{Opus.Programs, id, {:tail, delivery, output}}` when more than that
  came, which replaces what it shows. At the end it is handed what is
  kept for it and then the end, whatever it owes.

  It ends, and only then:

    * `:exited`: the program exited, or the service no longer runs it
      (its answer says so, the service was started again, or it could
      not be read for a minute);
    * `:closed`: `close/2` was accepted, carried out by this process
      whether or not the caller still waits;
    * `:idle`: a day passed with nothing attached and nothing printed,
      unless the session is kept (`keep/3`);
    * `:row_changed`: its row was changed, disabled or removed
      (`Opus.Programs.end_mounts/2`, or the box telling it to stand down);
    * `:standing`: its person no longer stands on this CYFR, or the
      athanor is no longer theirs and active, read from the store on
      every standing announcement and every five minutes. A store that
      cannot answer ends nothing, and a sign-out of a browser leaves the
      person standing.

  However it ends, killed included, the box closes its session; on the
  way out it asks so itself, which is the fast path.

  A session a turn started (`turn_id`, `by: :aqua`) has no attached
  process: its turn reads what it printed by offset (`read/3`, `wait/4`
  in `Opus.Programs`), the last #{div(256 * 1024, 1024)} KiB kept and
  counted from its first byte, and a wait is answered once output past
  its offset pauses for half a second, the program ends, or its own
  time passes. It also ends with its turn (`:standing`): at once when the
  turn's end says so (`Opus.Programs.end_turn/2`), or at the next
  standing check, which reads the turn. When its program exits by
  itself, it closes its session and releases its owner as any session
  does, but keeps its last output and its ending for its turn to read
  until the turn ends or stops it.

  A session of the person's browser (`by: :browser`, `Opus.Browser`) is
  the person's in what it does: its holder attaches as a person's screen
  does and is handed acknowledged deliveries and the tail, nothing of a
  turn ends it, and the day unwatched never runs out while its holder
  stays attached, which keeps its own idle stop. Every change of
  what `Opus.Programs.running/1` reports is announced on the person's
  own `Cyfr.Bus.programs/2` topic (`Cyfr.Bus.Program`). Nothing that
  passes through is stored or logged: the output it keeps and hands on
  is an `Opus.Programs.Output`, and its status shows none of it.
  """

  use GenServer, restart: :temporary

  require Prima.TestSeam

  alias Opus.Programs.{Output, Session}

  @tail_bytes 256 * 1024
  # How long a turn's session's output must pause before a wait that saw
  # some is answered.
  @settle_ms 500
  # The most one read of a turn's session answers.
  @read_bytes 64 * 1024
  @idle_ms 86_400_000
  @standing_ms 300_000
  @recv_wait_ms 25_000
  # How long the reader keeps asking a service that does not answer
  # before it takes the program as gone.
  @read_retry_ms 1_000
  @read_retries 60

  @doc "The most one read of a turn's session answers, in bytes."
  @spec read_bytes() :: pos_integer()
  def read_bytes, do: @read_bytes

  @doc false
  def start_link(args),
    do: GenServer.start_link(__MODULE__, args, name: Keyword.fetch!(args, :name))

  @impl true
  def init(args) do
    Process.flag(:trap_exit, true)
    :ok = Cyfr.Bus.subscribe_standing()

    {:ok,
     %{
       id: Keyword.fetch!(args, :id),
       athanor_id: Keyword.fetch!(args, :athanor_id),
       user_id: Keyword.fetch!(args, :user_id),
       turn_id: Keyword.get(args, :turn_id),
       row_id: Keyword.fetch!(args, :row_id),
       name: Keyword.fetch!(args, :row_name),
       home_id: Keyword.fetch!(args, :home_id),
       owner: Keyword.fetch!(args, :owner),
       argv: Keyword.fetch!(args, :argv),
       by: Keyword.fetch!(args, :by),
       rows: Keyword.fetch!(args, :rows),
       cols: Keyword.fetch!(args, :cols),
       started_at: DateTime.utc_now(),
       kept: false,
       grant: nil,
       session: nil,
       opening: nil,
       deadline: nil,
       reader: nil,
       subscribers: %{},
       tail: Output.new(""),
       written: 0,
       printed_at: nil,
       ended: nil,
       waiters: %{},
       settle: nil,
       idle: nil,
       standing: Process.send_after(self(), :standing, @standing_ms)
     }}
  end

  @impl true
  def handle_call({:open, deadline}, from, %{session: nil, opening: nil} = state) do
    case with(:ok <- turn_running(state), do: hold(state, deadline)) do
      {:ok, state} ->
        holder = self()
        owner = state.owner

        params = %{
          program: Opus.Programs.Definition.program_name(),
          home_id: state.home_id,
          key: state.id,
          mode: :terminal,
          argv: state.argv,
          rows: state.rows,
          cols: state.cols,
          # What the box announces should this process die before it can.
          ended: Map.put(summary(state), :user_id, state.user_id)
        }

        spawn_link(fn ->
          send(holder, {:opened, Opus.Programs.box_open(owner, holder, params, deadline)})
        end)

        {:noreply, %{state | opening: from, deadline: deadline}}

      {:error, reason} ->
        {:stop, :normal, {:error, reason}, state}
    end
  end

  def handle_call({:attach, person, pid}, _from, state) do
    if yours?(state, person) do
      subscribers =
        Map.put_new_lazy(state.subscribers, pid, fn ->
          %{monitor: Process.monitor(pid), outstanding: nil, pending: nil, lost: false}
        end)

      state = state |> Map.put(:subscribers, subscribers) |> idle() |> changed()

      {:reply, {:ok, %{tail: state.tail, rows: state.rows, cols: state.cols, kept: state.kept}},
       state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  # An attached process took the delivery it names: when that is the one
  # outstanding for it, it is handed what came since, or the next output
  # when nothing did. Any other token, repeated, guessed or never sent,
  # changes nothing, so one delivery at most is ever unacknowledged per
  # process, and only one that received it can name it.
  def handle_call({:taken, person, pid, delivery}, _from, state) do
    case state.subscribers do
      %{^pid => %{outstanding: ^delivery} = subscriber} when is_binary(delivery) ->
        if yours?(state, person),
          do: {:reply, :ok, put_in(state.subscribers[pid], hand(state, pid, subscriber))},
          else: {:reply, {:error, :not_found}, state}

      %{^pid => _subscriber} ->
        if yours?(state, person),
          do: {:reply, :ok, state},
          else: {:reply, {:error, :not_found}, state}

      _not_attached ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:detach, person, pid}, _from, state) do
    if yours?(state, person) and Map.has_key?(state.subscribers, pid),
      do: {:reply, :ok, unsubscribe(state, pid)},
      else: {:reply, :ok, state}
  end

  def handle_call({:use, principal}, _from, %{ended: ended} = state) when ended != nil do
    if yours?(state, principal),
      do: {:reply, {:error, :ended}, state},
      else: {:reply, {:error, :not_found}, state}
  end

  # A send to the session runs in the caller's process under the grant
  # this process holds, apart from it, so a slow service never delays an
  # attach or a close.
  def handle_call({:use, person}, _from, %{session: session} = state) when session != nil do
    if yours?(state, person),
      do: {:reply, {:ok, state.grant, session}, state},
      else: {:reply, {:error, :not_found}, state}
  end

  def handle_call({:resize, person, rows, cols}, _from, %{session: session} = state)
      when session != nil do
    if yours?(state, person),
      do: {:reply, {:ok, state.grant, session}, %{state | rows: rows, cols: cols}},
      else: {:reply, {:error, :not_found}, state}
  end

  def handle_call({:keep, person, kept}, _from, state) do
    if yours?(state, person),
      do: {:reply, :ok, %{state | kept: kept} |> idle() |> changed()},
      else: {:reply, {:error, :not_found}, state}
  end

  # A session listed is one still running, its own or its person's
  # turn's.
  def handle_call({:summary, principal}, _from, state) do
    if listed?(state, principal) and state.ended == nil,
      do: {:reply, {:ok, summary(state)}, state},
      else: {:reply, {:error, :not_found}, state}
  end

  # What a turn's session printed after `offset`, now.
  def handle_call({:read, principal, offset}, _from, state) do
    if yours?(state, principal),
      do: {:reply, {:ok, transcript(state, offset)}, state},
      else: {:reply, {:error, :not_found}, state}
  end

  # The same, once output past `offset` has paused, the program has ended,
  # or `ms` has passed: answered at once when one of these already holds.
  def handle_call({:wait, principal, offset, ms}, {pid, _tag} = from, state) do
    cond do
      not yours?(state, principal) ->
        {:reply, {:error, :not_found}, state}

      state.ended != nil or settled?(state, offset) ->
        {:reply, {:ok, transcript(state, offset)}, state}

      true ->
        ref = make_ref()
        timer = Process.send_after(self(), {:waited, ref}, ms)
        waiter = %{from: from, offset: offset, timer: timer, monitor: Process.monitor(pid)}
        {:noreply, settling(%{state | waiters: Map.put(state.waiters, ref, waiter)})}
    end
  end

  # A close names the session it was accepted for, by its id: it is
  # carried out here, so the caller leaving changes nothing, and answers
  # what the box answered. Nothing attaches to a session being closed.
  def handle_call({:close, _principal}, _from, %{ended: ended} = state) when ended != nil,
    do: {:stop, :normal, {:ok, :already_gone}, state}

  def handle_call({:close, principal}, _from, state) do
    if listed?(state, principal) do
      state = stop_reader(state)
      if state.opening, do: GenServer.reply(state.opening, {:error, :closed})

      answer =
        case close_session(state) do
          :ok -> {:ok, :closed}
          {:error, _unanswered} -> {:error, :unanswered}
        end

      state = ended(state, :closed)
      {:stop, :normal, answer, answer_waiters(%{state | session: nil, opening: nil})}
    else
      {:reply, {:ok, :already_gone}, state}
    end
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :not_found}, state}

  # The start's caller stopped waiting: the session it asked for is
  # nobody's, and ends; whatever the box gave it, the box closes.
  @impl true
  def handle_cast(:refused, state) do
    if state.opening, do: GenServer.reply(state.opening, {:error, :deadline})
    {:stop, :normal, ended(%{state | opening: nil}, :closed)}
  end

  def handle_cast({:row_ended, athanor_id, row_id}, state) do
    if state.athanor_id == athanor_id and state.row_id == row_id,
      do: finish(state, :row_changed),
      else: {:noreply, state}
  end

  # A turn that ended while its start was opening refuses the start; the
  # box closes whatever it opened for this process as it ends.
  def handle_cast({:turn_ended, turn_id}, %{turn_id: turn_id} = state) when turn_id != nil do
    if state.opening, do: GenServer.reply(state.opening, {:error, :not_found})
    finish(%{state | opening: nil}, :standing)
  end

  def handle_cast({:turn_ended, _another}, state), do: {:noreply, state}

  # An open the box gave is taken only inside its start's deadline: one
  # this process reads later (it was busy, or paused) refuses the start,
  # and the session the box gave is closed as this process ends.
  @impl true
  def handle_info({Opus.Programs, _kind, _owner_or_grant}, %{ended: ended} = state)
      when ended != nil,
      do: {:noreply, state}

  def handle_info({:opened, {:ok, %{session: session}}}, %{opening: from} = state)
      when from != nil do
    if System.system_time(:millisecond) > state.deadline do
      GenServer.reply(from, {:error, :deadline})
      {:stop, :normal, %{state | session: session, opening: nil}}
    else
      opened(state, from, session)
    end
  end

  def handle_info({:opened, {:error, reason}}, %{opening: from} = state) when from != nil do
    GenServer.reply(from, {:error, reason})
    {:stop, :normal, %{state | opening: nil}}
  end

  def handle_info({:read, %Output{} = output, running}, state) do
    if state.reader, do: send(state.reader, :taken)
    state = output(state, output)

    if running,
      do: {:noreply, state},
      else: finish(state, :exited)
  end

  def handle_info({:read_failed, _reason}, state), do: finish(state, :exited)

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    cond do
      match?(%{^pid => %{monitor: ^ref}}, state.subscribers) ->
        {:noreply, unsubscribe(state, pid)}

      waiter = Enum.find(state.waiters, fn {_key, w} -> w.monitor == ref end) ->
        {key, %{timer: timer}} = waiter
        Process.cancel_timer(timer)
        {:noreply, %{state | waiters: Map.delete(state.waiters, key)}}

      true ->
        {:noreply, state}
    end
  end

  # A wait whose time passed is answered what stands.
  def handle_info({:waited, ref}, state) do
    case Map.pop(state.waiters, ref) do
      {nil, _waiters} ->
        {:noreply, state}

      {waiter, waiters} ->
        Process.demonitor(waiter.monitor, [:flush])
        GenServer.reply(waiter.from, {:ok, transcript(state, waiter.offset)})
        {:noreply, %{state | waiters: waiters}}
    end
  end

  # Output paused: every wait that saw some is answered.
  def handle_info({:settled, token}, %{settle: {_timer, token}} = state),
    do: {:noreply, settling(answer_settled(%{state | settle: nil}))}

  def handle_info({:settled, _stale}, state), do: {:noreply, state}

  def handle_info({:idle, token}, %{idle: {_timer, token}} = state),
    do: finish(state, :idle)

  def handle_info({:idle, _stale}, state), do: {:noreply, state}

  def handle_info(:standing, state) do
    state = %{state | standing: Process.send_after(self(), :standing, @standing_ms)}
    recheck(state)
  end

  def handle_info(
        %Cyfr.Bus.Session{kind: :revoked, user_id: user_id},
        %{user_id: user_id} = state
      ),
      do: recheck(state)

  def handle_info(
        %Cyfr.Bus.AthanorArchived{athanor_id: athanor_id},
        %{athanor_id: athanor_id} = state
      ),
      do: recheck(state)

  def handle_info(%Cyfr.Bus.Session{}, state), do: {:noreply, state}
  def handle_info(%Cyfr.Bus.AthanorArchived{}, state), do: {:noreply, state}
  def handle_info(%Cyfr.Bus.CallerInvalidated{}, state), do: {:noreply, state}

  def handle_info({Opus.Programs, :stand_down, _key}, state),
    do: finish(state, :row_changed)

  # A new grant before the session stands is the one its open is made
  # under (the box synced the owner again for a service that restarted);
  # once it stands, the service the session ran on is not the one it runs
  # on now, so its program is gone.
  def handle_info({Opus.Programs, :owner, grant}, %{session: nil} = state),
    do: {:noreply, %{state | grant: grant}}

  def handle_info({Opus.Programs, :owner, _grant}, state), do: finish(state, :exited)

  # The reader ends of itself once it has read the program's end. One
  # that dies otherwise leaves nothing reading the session, so it ends as
  # a program the service no longer runs for it does, and is closed.
  def handle_info({:EXIT, reader, :normal}, %{reader: reader} = state),
    do: {:noreply, %{state | reader: nil}}

  def handle_info({:EXIT, reader, _died}, %{reader: reader} = state),
    do: finish(%{state | reader: nil}, :exited)

  # The courier of the box's open ends once it has carried the answer.
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info(message, state) do
    Prima.LoggerContext.unexpected(__MODULE__, message)
    {:noreply, state}
  end

  # The fast path: the box closes what a holder leaves however it ends.
  @impl true
  def terminate(_reason, state) do
    _ = stop_reader(state)
    if state.session, do: close_session(state)
    if state.grant, do: Opus.Programs.release(state.owner)
    :ok
  end

  # What the program wrote is an `Output` from the moment it enters this
  # process (the reader hands nothing else), and the words it was started
  # with are `Opus.Programs.Words` from the gate on, in its state and in
  # every message it handles, so no status, debug log or crash report has
  # a byte or a word of either to print.
  @impl true
  def format_status(status), do: Opus.Programs.StatusRedaction.format_status(status)

  # ---------------------------------------------------------------------------

  defp opened(state, from, session) do
    GenServer.reply(from, {:ok, state.id})
    terminal = self()
    grant = state.grant
    reader = spawn_link(fn -> read(terminal, grant, session, 0, 0) end)

    state = %{state | session: session, opening: nil, reader: reader} |> idle()
    announce(state, :started)
    {:noreply, state}
  end

  # The session's owner: the person who started it, the turn, or the
  # person's browser.
  defp yours?(%{by: :person} = state, {athanor_id, user_id}),
    do: state.athanor_id == athanor_id and state.user_id == user_id

  defp yours?(%{by: :aqua, turn_id: turn_id} = state, {athanor_id, user_id, turn_id})
       when is_binary(turn_id),
       do: state.athanor_id == athanor_id and state.user_id == user_id

  defp yours?(%{by: :browser} = state, {athanor_id, user_id, :browser}),
    do: state.athanor_id == athanor_id and state.user_id == user_id

  defp yours?(_state, _principal), do: false

  # Its owner, or the person whose turn or browser started it: who lists
  # and closes it.
  defp listed?(state, {athanor_id, user_id}),
    do: state.athanor_id == athanor_id and state.user_id == user_id

  defp listed?(state, principal), do: yours?(state, principal)

  # How a session ends. A turn's whose program exited by itself closes its
  # session and lets its owner go, as every ending does, and stays to
  # answer its last output and its ending until its turn ends or stops
  # it; every other ending stops the process, whose `terminate/2` does
  # the same.
  defp finish(%{turn_id: turn_id, ended: nil} = state, :exited) when turn_id != nil do
    state = state |> stop_reader() |> ended(:exited)
    if state.session, do: close_session(state)
    if state.grant, do: Opus.Programs.release(state.owner)
    with {timer, _token} <- state.idle, do: Process.cancel_timer(timer)

    state = %{state | session: nil, grant: nil, idle: nil, ended: :exited}
    {:noreply, answer_waiters(state)}
  end

  defp finish(%{ended: nil} = state, reason),
    do: {:stop, :normal, answer_waiters(%{ended(state, reason) | ended: reason})}

  defp finish(state, _reason), do: {:stop, :normal, state}

  # What the session printed after `offset`: from there, or from the first
  # byte it still keeps, at most `@read_bytes`, with what
  # it no longer keeps counted.
  defp transcript(state, offset) do
    kept = state.tail.bytes
    first = state.written - byte_size(kept)
    from = offset |> max(first) |> min(state.written)
    length = min(state.written - from, @read_bytes)

    %{
      program: state.name,
      output: Output.new(binary_part(kept, from - first, length)),
      from: from,
      next: from + length,
      dropped: max(first - offset, 0),
      running: state.ended == nil and state.session != nil,
      ended: state.ended
    }
  end

  defp settled?(state, offset),
    do:
      state.written > offset and state.printed_at != nil and
        System.monotonic_time(:millisecond) - state.printed_at >= @settle_ms

  # The pause clock runs while a wait has output past its offset: from
  # the last output, one timer at a time, its message carrying a token of
  # its own.
  defp settling(state) do
    with {timer, _token} <- state.settle, do: Process.cancel_timer(timer)

    if Enum.any?(state.waiters, fn {_ref, w} -> state.written > w.offset end) do
      left = @settle_ms - (System.monotonic_time(:millisecond) - (state.printed_at || 0))
      token = make_ref()
      timer = Process.send_after(self(), {:settled, token}, max(left, 0))
      %{state | settle: {timer, token}}
    else
      %{state | settle: nil}
    end
  end

  defp answer_settled(state) do
    {ready, waiting} =
      Enum.split_with(state.waiters, fn {_ref, w} -> settled?(state, w.offset) end)

    for {_ref, waiter} <- ready, do: answer(state, waiter)
    %{state | waiters: Map.new(waiting)}
  end

  defp answer_waiters(state) do
    for {_ref, waiter} <- state.waiters, do: answer(state, waiter)
    %{state | waiters: %{}}
  end

  defp answer(state, waiter) do
    Process.cancel_timer(waiter.timer)
    Process.demonitor(waiter.monitor, [:flush])
    GenServer.reply(waiter.from, {:ok, transcript(state, waiter.offset)})
  end

  # The owner, held under the start's deadline. A hold the box answers
  # too late still registers this process, whose stop then releases it.
  defp hold(state, deadline) do
    case deadline - System.system_time(:millisecond) do
      ms when ms > 0 ->
        with {:ok, grant} <- Opus.Programs.hold(state.owner, ms),
             do: {:ok, %{state | grant: grant}}

      _passed ->
        {:error, :deadline}
    end
  end

  defp close_session(state), do: Opus.Programs.box_close(state.owner, state.home_id, state.id)

  defp stop_reader(%{reader: nil} = state), do: state

  defp stop_reader(%{reader: reader} = state) do
    Process.unlink(reader)
    Process.exit(reader, :kill)
    %{state | reader: nil}
  end

  defp output(state, %Output{bytes: ""}), do: state

  defp output(state, %Output{bytes: bytes}) do
    tail = state.tail.bytes <> bytes
    size = byte_size(tail)

    tail =
      if size > @tail_bytes, do: binary_part(tail, size - @tail_bytes, @tail_bytes), else: tail

    subscribers =
      Map.new(state.subscribers, fn {pid, s} -> {pid, offer(state, pid, s, bytes)} end)

    %{
      state
      | tail: Output.new(tail),
        subscribers: subscribers,
        written: state.written + byte_size(bytes),
        printed_at: System.monotonic_time(:millisecond)
    }
    |> idle()
    |> settling()
  end

  # An attached process that took what it was handed last is handed this
  # output now; one that has not keeps it, with what came before it, the
  # last #{div(256 * 1024, 1024)} KiB of them at most.
  defp offer(state, pid, %{outstanding: nil} = subscriber, bytes),
    do: deliver(state, pid, subscriber, :bytes, Output.new(bytes))

  defp offer(_state, _pid, subscriber, bytes) do
    kept = if subscriber.pending, do: subscriber.pending.bytes <> bytes, else: bytes
    size = byte_size(kept)

    if size > @tail_bytes,
      do: %{
        subscriber
        | pending: Output.new(binary_part(kept, size - @tail_bytes, @tail_bytes)),
          lost: true
      },
      else: %{subscriber | pending: Output.new(kept)}
  end

  # What a process that took the last output is handed: what came since,
  # as the tail when some of it was let go, or nothing until more comes.
  defp hand(_state, _pid, %{pending: nil} = subscriber), do: %{subscriber | outstanding: nil}

  defp hand(state, pid, %{pending: pending, lost: lost} = subscriber) do
    kind = if lost, do: :tail, else: :bytes
    deliver(state, pid, %{subscriber | pending: nil, lost: false}, kind, pending)
  end

  # Each delivery to a process carries a fresh random token, which
  # its acknowledgement names (`taken/3`).
  defp deliver(state, pid, subscriber, kind, %Output{} = output) do
    delivery = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    send(pid, {Opus.Programs, state.id, {kind, delivery, output}})
    %{subscriber | outstanding: delivery}
  end

  defp unsubscribe(state, pid) do
    {subscriber, subscribers} = Map.pop(state.subscribers, pid)
    if subscriber, do: Process.demonitor(subscriber.monitor, [:flush])
    %{state | subscribers: subscribers} |> idle() |> changed()
  end

  # The day's clock runs while nothing is attached and the session is not
  # kept, from the last detach or the last output, whichever came later:
  # one timer at a time, the one before it cancelled, and its message
  # carries a token of its own, so one already sent ends nothing.
  defp idle(state) do
    with {timer, _token} <- state.idle, do: Process.cancel_timer(timer)

    if state.subscribers == %{} and not state.kept and state.session != nil do
      token = make_ref()
      timer = Process.send_after(self(), {:idle, token}, idle_ms())
      %{state | idle: {timer, token}}
    else
      %{state | idle: nil}
    end
  end

  defp idle_ms,
    do:
      Prima.TestSeam.value(@idle_ms, fn ->
        Application.get_env(:cyfr, :program_idle_ms, @idle_ms)
      end)

  # The person stands on this CYFR and the athanor is active and theirs
  # (`Opus.Programs.stands/2`), read from the store and from no context,
  # since the session is the person's and no browser's; and a turn's
  # session's turn is still open. A store that cannot answer ends nothing.
  defp recheck(state) do
    case {Opus.Programs.stands(state.athanor_id, state.user_id), turn_open(state)} do
      {{:ok, false}, _turn} -> finish(state, :standing)
      {_stands, {:ok, false}} -> finish(state, :standing)
      _standing_or_unanswered -> {:noreply, state}
    end
  end

  defp turn_open(%{turn_id: nil}), do: {:ok, true}

  defp turn_open(state) do
    with {:ok, status} <- Opus.Programs.turn_status(state.athanor_id, state.turn_id),
         do: {:ok, status in Prima.TurnState.open_statuses()}
  end

  # A turn's start opens nothing unless its turn still runs, read once the
  # process is registered under it: a turn's end marks its row before it
  # ends what is registered (`Opus.Programs.end_turn/2`), so either the end
  # finds this process or this read finds the end.
  defp turn_running(%{turn_id: nil}), do: :ok

  defp turn_running(state) do
    case Opus.Programs.turn_status(state.athanor_id, state.turn_id) do
      {:ok, "running"} -> :ok
      {:ok, _not_running} -> {:error, :not_found}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp summary(state) do
    %{
      session: state.id,
      row_id: state.row_id,
      name: state.name,
      started_at: state.started_at,
      kept: state.kept,
      attached: state.subscribers != %{},
      by: state.by
    }
  end

  defp changed(%{session: nil} = state), do: state

  defp changed(state) do
    announce(state, :changed)
    state
  end

  # Each attached process is handed what is held for it, whatever it
  # owes, and then the end: the last thing a program printed is shown.
  defp ended(state, reason) do
    for {pid, subscriber} <- state.subscribers do
      if subscriber.pending, do: hand(state, pid, subscriber)
      send(pid, {Opus.Programs, state.id, {:ended, reason}})
    end

    if state.session != nil, do: announce(state, :ended, reason: reason)

    state
  end

  defp announce(state, kind, extra \\ []) do
    actor = Prima.Actor.in_athanor(state.athanor_id)
    payload = Cyfr.Bus.Program.new(actor, kind, Map.merge(summary(state), Map.new(extra)))
    _ = Cyfr.Bus.broadcast(actor, Cyfr.Bus.programs(actor, state.user_id), payload)
    :ok
  end

  # The reader: one output at a time, each naming the last chunk it was
  # answered, so a lost answer is replayed, and the next asked for only
  # once the owner has taken the last. A service that does not answer is
  # asked again each second for a minute.
  defp read(terminal, grant, session, after_seq, failures) do
    case Session.output(grant, session, after_seq, @recv_wait_ms) do
      {:ok, %{chunks: chunks, running: running}} ->
        output = Output.new(IO.iodata_to_binary(Enum.map(chunks, & &1.bytes)))
        last = if chunks == [], do: after_seq, else: List.last(chunks).seq
        send(terminal, {:read, output, running})

        if running do
          receive do
            :taken -> read(terminal, grant, session, last, 0)
          end
        end

      {:error, {:refused, _code, _boot} = refused} ->
        send(terminal, {:read_failed, refused})

      {:error, reason} when failures >= @read_retries ->
        send(terminal, {:read_failed, reason})

      {:error, _unanswered} ->
        Process.sleep(@read_retry_ms)
        read(terminal, grant, session, after_seq, failures + 1)
    end
  end
end
