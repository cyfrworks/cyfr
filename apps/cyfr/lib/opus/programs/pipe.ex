# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Programs.Pipe do
  @moduledoc """
  One pipe session: a `run` session of a program row under one key, in a
  login entry's kept home, held for the catalysts that open it
  (`Opus.Programs.pipe_open/5`).

  The holder belongs to the row, the home and the key, never to an
  attempt: it holds the row's owner (`Opus.Programs.hold/1`) and opens its
  session on the box whenever an attempt opens the key, so a later attempt
  attaches to the session while its program runs and a program that ended
  is started again (`resumed: false`). It records, for each attempt that
  opened it, what that open answered, so a repeat by the same attempt
  answers as the first did while the session is the same; only an attempt
  that opened the session may use it (`use/4`). A send or a read runs in
  its caller's process under the holder's grant, apart from the holder, so
  a long read never delays a send.

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
  # Within a host call's window: an open the box does not answer by then
  # is refused, and the catalyst's next open asks again.
  @open_timeout_ms 20_000
  # A refusal that says this grant's owner is not on the service any more:
  # held again and asked once more.
  @stale [:stale_boot, :epoch_ahead, :unknown_owner, :lapsed]

  @doc false
  def start_link(args),
    do: GenServer.start_link(__MODULE__, args, name: Keyword.fetch!(args, :name))

  @doc "The wait `Opus.Programs` gives an open: the box's own bound and a margin."
  @spec call_timeout_ms() :: pos_integer()
  def call_timeout_ms, do: @open_timeout_ms + 5_000

  @impl true
  def init(args) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(args, :owner)

    case Opus.Programs.hold(owner) do
      {:ok, grant} ->
        state = %{
          owner: owner,
          grant: grant,
          program: Keyword.fetch!(args, :program),
          row_name: Keyword.fetch!(args, :row_name),
          home_id: Keyword.fetch!(args, :home_id),
          key: Keyword.fetch!(args, :key),
          session: nil,
          openers: %{},
          idle: nil
        }

        {:ok, idle(state)}

      {:error, reason} ->
        {:stop, {:shutdown, reason}}
    end
  end

  @impl true
  def handle_call({:open, opener, argv}, _from, state) do
    case open(state, argv, true) do
      {:ok, %{session: session, resumed: resumed}, state} ->
        answer = %{session: session, resumed: answered(state, opener, session, resumed)}
        state = state |> session(session) |> remember(opener, answer) |> idle()
        {:reply, {:ok, answer}, state}

      # A holder with no session yet, or whose owner could not be held
      # again, has nothing to keep; one whose session runs keeps it.
      {:error, reason, state} when state.session == nil ->
        {:stop, :normal, {:error, reason}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}

      {:lost, reason, state} ->
        {:stop, :normal, {:error, reason}, state}
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
  def handle_info(:idle, state), do: {:stop, :normal, state}

  def handle_info({Opus.Programs, :stand_down, _key}, state), do: {:stop, :normal, state}

  # A new grant means the box synced the owner again: the service the
  # session ran on is not the one it runs on now.
  def handle_info({Opus.Programs, :owner, _grant}, state), do: {:stop, :normal, state}

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info(message, state) do
    Prima.LoggerContext.unexpected(__MODULE__, message)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.session, do: _ = Session.close(state.grant, state.session)
    Opus.Programs.release(state.owner)
    :ok
  end

  @impl true
  def format_status(status), do: Opus.Programs.StatusRedaction.format_status(status)

  # The box opens the key's session: attaching to it while it runs, or
  # starting the program with `argv`. A refusal saying the owner is not on
  # the service any more holds it again and asks once more.
  defp open(state, argv, retry?) do
    params = %{
      program: state.program,
      home_id: state.home_id,
      key: state.key,
      mode: :run,
      argv: argv,
      timeout_ms: @open_timeout_ms
    }

    case Session.open(state.grant, params) do
      {:ok, opened} ->
        {:ok, opened, state}

      {:error, {:refused, code, boot}} when code in @stale and retry? ->
        if code == :stale_boot and is_binary(boot), do: Opus.Programs.boot_seen(boot)

        case Opus.Programs.hold(state.owner) do
          {:ok, grant} -> open(%{state | grant: grant}, argv, false)
          {:error, reason} -> {:lost, reason, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
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
  # and its holder is found by it from then on.
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

  defp idle(state) do
    if state.idle, do: Process.cancel_timer(state.idle)
    %{state | idle: Process.send_after(self(), :idle, state.grant.idle_ms + @idle_slack_ms)}
  end
end
