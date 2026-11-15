# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Programs.SignIn do
  @moduledoc """
  One sign-in: a `terminal` session running a program row's login command
  (the row's command with the words its login command adds as arguments),
  on a pseudo-terminal of 40 rows by 120 columns in the row's kept home,
  relayed to the one process that attaches to it (`Opus.Programs.sign_in/2`)
  as lines: what the terminal writes is split at its newlines, a part with
  none yet sent as a line of its own, and a line the subscriber sends is
  typed with a carriage return.

  The relay holds the row's owner (`Opus.Programs.hold/1`), opens the
  session under a key derived from its caller's binding (so one caller has
  one sign-in per row), and reads the session's lines with a reader of its
  own. It keeps the last #{500} lines until its subscriber attaches, then
  sends each batch as `{Opus.Programs, token, {:lines, lines}}`; a line the
  subscriber sends is written to the terminal. It ends — `{Opus.Programs,
  token, {:ended, reason}}` to the subscriber, the session closed and the
  owner released — when the command ends (`{:exited, code}`, `code` nil
  for one ended by a signal: whether the program is signed in is the
  program's to say), when the subscriber exits or asks it to (`:closed`),
  when no subscriber attaches within 30 s (`:unattended`), when the box
  tells it to stand down or issues a new grant (`:stand_down`,
  `:owner_moved`), when the session cannot be read (`:lost`), or when its
  row is deleted (`:row_ended`, `Opus.Programs.end_mounts/2`). CYFR stores nothing
  of what passes through, and nothing of it shows in `:sys.get_status/1`
  or a crash report: a sign-in's lines and what the person types are
  credentials, shown only as counts.
  """

  use GenServer, restart: :temporary

  alias Opus.Programs.Session

  @kept_lines 500
  @rows 40
  @cols 120
  @attach_ms 30_000
  @recv_wait_ms 25_000

  @doc false
  def start_link(args),
    do: GenServer.start_link(__MODULE__, args, name: Keyword.fetch!(args, :name))

  @impl true
  def init(args) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(args, :owner)

    params = %{
      program: Opus.Programs.Definition.program_name(),
      home_id: owner.server_id,
      key: Keyword.fetch!(args, :key),
      mode: :terminal,
      argv: Keyword.fetch!(args, :argv),
      rows: @rows,
      cols: @cols
    }

    with {:ok, grant} <- Opus.Programs.hold(owner),
         {:ok, grant, %{session: session}} <- open(grant, owner, params) do
      relay = self()
      reader = spawn_link(fn -> read(relay, grant, session, 0) end)

      {:ok,
       %{
         token: Keyword.fetch!(args, :token),
         binding: Keyword.fetch!(args, :binding),
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

  # An open refused for a boot the service no longer runs tells the box the
  # boot its answer names and holds the owner again, which answers once the
  # owner is synced under that boot; then it is opened once more.
  defp open(grant, owner, params) do
    case Session.open(grant, params) do
      {:ok, opened} ->
        {:ok, grant, opened}

      {:error, {:refused, :stale_boot, boot}} when is_binary(boot) and boot != grant.boot ->
        Opus.Programs.boot_seen(boot)

        with {:ok, grant} <- Opus.Programs.hold(owner),
             {:ok, opened} <- Session.open(grant, params),
             do: {:ok, grant, opened}

      {:error, _reason} = refused ->
        refused
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
    case Session.input(state.grant, state.session, line <> "\r") do
      {:ok, :running} -> {:reply, :ok, state}
      {:ok, :ended} -> {:reply, {:error, :ended}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:close, binding}, _from, %{binding: binding} = state),
    do: {:stop, :normal, :ok, ended(state, :closed)}

  def handle_call(_request, _from, state), do: {:reply, {:error, :not_yours}, state}

  @impl true
  def handle_cast({:row_ended, athanor_id, row_id}, %{owner: owner} = state) do
    if owner.athanor_id == athanor_id and owner.server_id == row_id,
      do: {:stop, :normal, ended(state, :row_ended)},
      else: {:noreply, state}
  end

  @impl true
  def handle_info({:read, lines, running, exit_code}, state) do
    state = relay(state, lines)

    if running,
      do: {:noreply, state},
      else: {:stop, :normal, ended(state, {:exited, exit_code})}
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

  # A sign-in's lines and what the person types are credentials: its state
  # keeps only how many lines it holds, and a message carrying text keeps
  # only its count, before the generic redaction takes the keys.
  @impl true
  def format_status(status) do
    status
    |> Map.new(fn
      {:state, %{} = state} -> {:state, %{state | kept: {:redacted, length(state.kept)}}}
      {:message, message} -> {:message, redact_text(message)}
      {:log, _log} -> {:log, []}
      other -> other
    end)
    |> Opus.Programs.StatusRedaction.format_status()
  end

  defp redact_text({:read, lines, running, exit_code}),
    do: {:read, {:redacted, length(lines)}, running, exit_code}

  defp redact_text({:"$gen_call", from, {:send, binding, _line}}),
    do: {:"$gen_call", from, {:send, binding, :redacted}}

  defp redact_text({Opus.Programs, token, {:lines, lines}}),
    do: {Opus.Programs, token, {:lines, {:redacted, length(lines)}}}

  defp redact_text(message), do: message

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

  # The reader: one output at a time, each naming the last chunk it was
  # answered, so a lost answer is replayed.
  defp read(relay, grant, session, after_seq) do
    case Session.output(grant, session, after_seq, @recv_wait_ms) do
      {:ok, %{chunks: chunks, running: running} = answer} ->
        texts = Enum.flat_map(chunks, &lines(&1.bytes))
        last = if chunks == [], do: after_seq, else: List.last(chunks).seq
        send(relay, {:read, texts, running, answer.exit_code})
        if running, do: read(relay, grant, session, last)

      {:error, reason} ->
        send(relay, {:read_failed, reason})
    end
  end

  defp lines(bytes) do
    bytes
    |> String.replace_invalid()
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing(&1, "\r"))
    |> Enum.reject(&(&1 == ""))
  end
end
