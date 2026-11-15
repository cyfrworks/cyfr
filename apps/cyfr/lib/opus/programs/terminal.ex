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
  terminal's size, then hears `{Opus.Programs, id, {:bytes, output}}`
  for what the program writes and `{Opus.Programs, id, {:ended, reason}}`
  once. A detach, or an attached process's exit, ends nothing.

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
  way out it asks so itself, which is the fast path. Every change of
  what `Opus.Programs.running/1` reports is announced on the person's
  own `Cyfr.Bus.programs/2` topic (`Cyfr.Bus.Program`). Nothing that
  passes through is stored or logged: the output it keeps and hands on
  is an `Opus.Programs.Output`, and its status shows none of it.
  """

  use GenServer, restart: :temporary

  alias Opus.Programs.{Output, Session}

  @tail_bytes 256 * 1024
  @idle_ms 86_400_000
  @standing_ms 300_000
  @recv_wait_ms 25_000
  # How long the reader keeps asking a service that does not answer
  # before it takes the program as gone.
  @read_retry_ms 1_000
  @read_retries 60

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
       reader: nil,
       subscribers: %{},
       tail: "",
       idle: nil,
       standing: Process.send_after(self(), :standing, @standing_ms)
     }}
  end

  @impl true
  def handle_call({:open, deadline}, from, %{session: nil, opening: nil} = state) do
    case hold(state, deadline) do
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
          cols: state.cols
        }

        spawn_link(fn ->
          send(holder, {:opened, Opus.Programs.box_open(owner, holder, params, deadline)})
        end)

        {:noreply, %{state | opening: from}}

      {:error, reason} ->
        {:stop, :normal, {:error, reason}, state}
    end
  end

  def handle_call({:attach, person, pid}, _from, state) do
    if yours?(state, person) do
      subscribers =
        Map.put_new_lazy(state.subscribers, pid, fn -> Process.monitor(pid) end)

      state = state |> Map.put(:subscribers, subscribers) |> idle() |> changed()

      {:reply,
       {:ok,
        %{tail: Output.new(state.tail), rows: state.rows, cols: state.cols, kept: state.kept}},
       state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:detach, person, pid}, _from, state) do
    if yours?(state, person) and Map.has_key?(state.subscribers, pid),
      do: {:reply, :ok, unsubscribe(state, pid)},
      else: {:reply, :ok, state}
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

  def handle_call({:summary, person}, _from, state) do
    if yours?(state, person),
      do: {:reply, {:ok, summary(state)}, state},
      else: {:reply, {:error, :not_found}, state}
  end

  # A close names the session it was accepted for, by its id: it is
  # carried out here, so the caller leaving changes nothing, and answers
  # what the box answered. Nothing attaches to a session being closed.
  def handle_call({:close, person}, _from, state) do
    if yours?(state, person) do
      state = stop_reader(state)
      if state.opening, do: GenServer.reply(state.opening, {:error, :closed})

      answer =
        case close_session(state) do
          :ok -> {:ok, :closed}
          {:error, _unanswered} -> {:error, :unanswered}
        end

      state = ended(state, :closed)
      {:stop, :normal, answer, %{state | session: nil, opening: nil}}
    else
      {:reply, {:ok, :already_gone}, state}
    end
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :not_found}, state}

  @impl true
  def handle_cast({:row_ended, athanor_id, row_id}, state) do
    if state.athanor_id == athanor_id and state.row_id == row_id,
      do: {:stop, :normal, ended(state, :row_changed)},
      else: {:noreply, state}
  end

  @impl true
  def handle_info({:opened, {:ok, %{session: session}}}, %{opening: from} = state)
      when from != nil do
    GenServer.reply(from, {:ok, state.id})
    terminal = self()
    grant = state.grant
    reader = spawn_link(fn -> read(terminal, grant, session, 0, 0) end)

    state = %{state | session: session, opening: nil, reader: reader} |> idle()
    announce(state, :started)
    {:noreply, state}
  end

  def handle_info({:opened, {:error, reason}}, %{opening: from} = state) when from != nil do
    GenServer.reply(from, {:error, reason})
    {:stop, :normal, %{state | opening: nil}}
  end

  def handle_info({:read, bytes, running}, state) do
    state = output(state, bytes)

    if running,
      do: {:noreply, state},
      else: {:stop, :normal, ended(state, :exited)}
  end

  def handle_info({:read_failed, _reason}, state),
    do: {:stop, :normal, ended(state, :exited)}

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    if match?(%{^pid => ^ref}, state.subscribers),
      do: {:noreply, unsubscribe(state, pid)},
      else: {:noreply, state}
  end

  def handle_info({:idle, ref}, %{idle: ref} = state),
    do: {:stop, :normal, ended(state, :idle)}

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
    do: {:stop, :normal, ended(state, :row_changed)}

  # A new grant means the box synced the owner again: the service the
  # session ran on is not the one it runs on now, so its program is gone.
  def handle_info({Opus.Programs, :owner, _grant}, state),
    do: {:stop, :normal, ended(state, :exited)}

  def handle_info({:EXIT, reader, _reason}, %{reader: reader} = state),
    do: {:noreply, %{state | reader: nil}}

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

  @impl true
  def format_status(status) do
    status
    |> Map.new(fn
      {:state, %{} = state} -> {:state, %{state | tail: Output.new(state.tail), argv: :redacted}}
      {:message, {:read, bytes, running}} -> {:message, {:read, Output.new(bytes), running}}
      other -> other
    end)
    |> Opus.Programs.StatusRedaction.format_status()
  end

  # ---------------------------------------------------------------------------

  defp yours?(state, {athanor_id, user_id}),
    do: state.athanor_id == athanor_id and state.user_id == user_id

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

  defp output(state, ""), do: state

  defp output(state, bytes) do
    tail = state.tail <> bytes
    size = byte_size(tail)

    tail =
      if size > @tail_bytes, do: binary_part(tail, size - @tail_bytes, @tail_bytes), else: tail

    for pid <- Map.keys(state.subscribers),
        do: send(pid, {Opus.Programs, state.id, {:bytes, Output.new(bytes)}})

    idle(%{state | tail: tail})
  end

  defp unsubscribe(state, pid) do
    {ref, subscribers} = Map.pop(state.subscribers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    %{state | subscribers: subscribers} |> idle() |> changed()
  end

  # The day's clock runs while nothing is attached and the session is not
  # kept, from the last detach or the last output, whichever came later.
  defp idle(state) do
    if state.idle, do: Process.cancel_timer(state.idle)

    if state.subscribers == %{} and not state.kept and state.session != nil do
      ref = make_ref()
      Process.send_after(self(), {:idle, ref}, @idle_ms)
      %{state | idle: ref}
    else
      %{state | idle: nil}
    end
  end

  defp recheck(state) do
    case stands(state.athanor_id, state.user_id) do
      {:ok, false} -> {:stop, :normal, ended(state, :standing)}
      _standing_or_unanswered -> {:noreply, state}
    end
  end

  # The person stands on this CYFR (`Sanctum.Caller.stands?/1`) and the
  # athanor is active and theirs, read from the store and from no
  # context, since the session is the person's and no browser's.
  defp stands(athanor_id, user_id) do
    with {:ok, true} <- Sanctum.Caller.stands?(user_id),
         {:ok, athanor} <- Sanctum.Tenancy.Athanors.get(athanor_id) do
      {:ok, athanor.status == "active" and athanor.owner_user_id == user_id}
    else
      {:ok, false} -> {:ok, false}
      {:error, :not_found} -> {:ok, false}
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

  defp ended(state, reason) do
    for pid <- Map.keys(state.subscribers),
        do: send(pid, {Opus.Programs, state.id, {:ended, reason}})

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
  # answered, so a lost answer is replayed. A service that does not
  # answer is asked again each second for a minute.
  defp read(terminal, grant, session, after_seq, failures) do
    case Session.output(grant, session, after_seq, @recv_wait_ms) do
      {:ok, %{chunks: chunks, running: running}} ->
        bytes = IO.iodata_to_binary(Enum.map(chunks, & &1.bytes))
        last = if chunks == [], do: after_seq, else: List.last(chunks).seq
        send(terminal, {:read, bytes, running})
        if running, do: read(terminal, grant, session, last, 0)

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
