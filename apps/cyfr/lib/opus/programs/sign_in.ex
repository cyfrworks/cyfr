# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Programs.SignIn do
  @moduledoc """
  One sign-in: a `sign_in` session of a program row's login command, on a
  pseudo-terminal in a login entry's kept home, relayed to the one process
  that attaches to it (`Opus.Programs.sign_in/3`).

  The relay holds the row's owner (`Opus.Programs.hold/1`), opens the
  session under a key derived from its caller's binding (so one caller has
  one sign-in per row), and reads the session's lines with a reader of its
  own. It keeps the last #{500} lines until its subscriber attaches, then
  sends each batch as `{Opus.Programs, token, {:lines, lines}}`; a line the
  subscriber sends is written to the terminal. It ends — `{Opus.Programs,
  token, {:ended, reason}}` to the subscriber, the session closed and the
  owner released — when the command ends (`:signed_in` when it exited 0
  and its login entry is active, which makes an entry a restore left
  `needs_reauth` active again through `Sanctum.Mount.signed_in/2` under the
  interactive context that opened it; `{:exited, code}` for any other end
  of the command, `code` nil for one ended by a signal, the entry left as
  it is; `{:not_signed_in, reason}` when it exited 0 but the entry could not
  be made active), when the subscriber
  exits or asks it to (`:closed`), when no subscriber attaches within 30 s
  (`:unattended`), when the box tells it to stand down or issues a new
  grant (`:stand_down`, `:owner_moved`), or when the session cannot be read
  (`:lost`). CYFR stores nothing of what passes through.
  """

  use GenServer, restart: :temporary

  alias Opus.Programs.Session

  @kept_lines 500
  @attach_ms 30_000
  @recv_wait_ms 25_000

  @doc false
  def start_link(args),
    do: GenServer.start_link(__MODULE__, args, name: Keyword.fetch!(args, :name))

  @impl true
  def init(args) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(args, :owner)

    with {:ok, grant} <- Opus.Programs.hold(owner),
         {:ok, %{session: session}} <-
           Session.open(grant, %{
             program: Keyword.fetch!(args, :program),
             home_id: Keyword.fetch!(args, :home_id),
             key: Keyword.fetch!(args, :key),
             mode: :sign_in
           }) do
      relay = self()
      reader = spawn_link(fn -> read(relay, grant, session, 0) end)

      {:ok,
       %{
         token: Keyword.fetch!(args, :token),
         binding: Keyword.fetch!(args, :binding),
         ctx: Keyword.fetch!(args, :ctx),
         entry_id: Keyword.fetch!(args, :home_id),
         owner: owner,
         grant: grant,
         session: session,
         reader: reader,
         subscriber: nil,
         monitor: nil,
         kept: [],
         attach_timer: Process.send_after(self(), :unattended, @attach_ms)
       }}
    else
      {:error, reason} ->
        Opus.Programs.release(owner)
        {:stop, {:shutdown, reason}}
    end
  end

  @impl true
  def handle_call({:attach, binding, pid}, _from, %{binding: binding, subscriber: nil} = state) do
    Process.cancel_timer(state.attach_timer)
    if state.kept != [], do: deliver(pid, state.token, Enum.reverse(state.kept))

    {:reply, :ok,
     %{state | subscriber: pid, monitor: Process.monitor(pid), kept: [], attach_timer: nil}}
  end

  def handle_call({:attach, binding, _pid}, _from, %{binding: binding} = state),
    do: {:reply, {:error, :attached}, state}

  def handle_call({:send, binding, line}, _from, %{binding: binding} = state) do
    case Session.send(state.grant, state.session, [line]) do
      {:ok, :running} -> {:reply, :ok, state}
      {:ok, :ended} -> {:reply, {:error, :ended}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:close, binding}, _from, %{binding: binding} = state),
    do: {:stop, :normal, :ok, ended(state, :closed)}

  def handle_call(_request, _from, state), do: {:reply, {:error, :not_yours}, state}

  @impl true
  def handle_info({:read, lines, running, exit_code}, state) do
    state = relay(state, lines)

    if running,
      do: {:noreply, state},
      else: {:stop, :normal, ended(state, exited(state, exit_code))}
  end

  def handle_info({:read_failed, _reason}, state), do: {:stop, :normal, ended(state, :lost)}

  def handle_info(:unattended, %{subscriber: nil} = state),
    do: {:stop, :normal, ended(state, :unattended)}

  def handle_info(:unattended, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state),
    do: {:stop, :normal, ended(%{state | subscriber: nil}, :closed)}

  def handle_info({Opus.Programs, :stand_down, _key}, state),
    do: {:stop, :normal, ended(state, :stand_down)}

  # A new grant means the box synced the owner again: the service the
  # session ran on is not the one it runs on now.
  def handle_info({Opus.Programs, :owner, _grant}, state),
    do: {:stop, :normal, ended(state, :owner_moved)}

  def handle_info({:EXIT, reader, _reason}, %{reader: reader} = state),
    do: {:noreply, %{state | reader: nil}}

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info(message, state) do
    Prima.LoggerContext.unexpected(__MODULE__, message)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.reader, do: Process.exit(state.reader, :kill)
    _ = Session.close(state.grant, state.session)
    Opus.Programs.release(state.owner)
    :ok
  end

  @impl true
  def format_status(status), do: Opus.Programs.StatusRedaction.format_status(status)

  # Only a command that exited 0 signed the program in; the entry is made
  # active again then, and left as it is on any other end.
  defp exited(state, 0) do
    case Sanctum.Mount.signed_in(state.ctx, state.entry_id) do
      :ok -> :signed_in
      {:error, reason} -> {:not_signed_in, reason}
    end
  end

  defp exited(_state, code), do: {:exited, code}

  defp relay(%{subscriber: nil} = state, lines) do
    kept = Enum.reverse(lines, state.kept) |> Enum.take(@kept_lines)
    %{state | kept: kept}
  end

  defp relay(state, lines) do
    deliver(state.subscriber, state.token, lines)
    state
  end

  defp deliver(_pid, _token, []), do: :ok
  defp deliver(pid, token, lines), do: send(pid, {Opus.Programs, token, {:lines, lines}})

  defp ended(state, reason) do
    if state.subscriber,
      do: send(state.subscriber, {Opus.Programs, state.token, {:ended, reason}})

    state
  end

  # The reader: one recv at a time, each naming the last line it was
  # answered, so a lost answer is replayed.
  defp read(relay, grant, session, after_seq) do
    case Session.recv(grant, session, after_seq, @recv_wait_ms) do
      {:ok, %{lines: lines, running: running} = answer} ->
        texts = Enum.map(lines, & &1.text)
        last = if lines == [], do: after_seq, else: List.last(lines).seq
        send(relay, {:read, texts, running, answer.exit_code})
        if running, do: read(relay, grant, session, last)

      {:error, reason} ->
        send(relay, {:read_failed, reason})
    end
  end

  @doc false
  def kept_lines, do: @kept_lines
end
