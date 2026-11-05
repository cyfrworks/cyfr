# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Backends.Backend do
  @moduledoc """
  One session of a program of one owner (an athanor's `mcp_servers` row at
  a generation and epoch): its process, started through a
  `Locus.Launcher`, and the sequence-numbered buffer of the lines it
  writes (`Locus.Backends.Relay`). It knows no protocol: lines go in with
  `send_lines/2` and come out with `recv/3`, and what they mean is the
  owner's.

  ## Its life

  A session starts its process at once, or after `:delay_ms` when its
  owners hold it back for a crash's backoff, and tells its owners
  `:started` once the launcher answers the spawn. It is `running` until
  its process ends, and then `ended`: its buffered lines stay readable,
  every later `recv/3` answers `running: false`, and every later
  `send_lines/2` answers `:ended`. The process stays its until it is gone
  and its owners hear `{:ended, end}`, `end` saying whether the end was a
  crash (`crash: true`: the process exited of its own accord with a
  status other than 0 or by a signal, wrote a line past
  `Prima.LocusBackends.max_line_bytes/0`, or its spawn was refused) and
  why; once nothing of its process is left (the launcher's `:released`),
  `:vacated`, after which it holds no uid.

  `close/1`, `retire_if_idle/2` (no `send_lines/2` and no `recv/3` within
  the idle period), `end_session/2` (its owners ending it: the cap of its
  home, its home's reset or retirement) and `stop/2` (its owner retired)
  end the process with the stop grace; none of them is a crash. A session
  ended this way answers `running: false` at once, however long its
  process takes to go.

  ## Lines

  A session on a pseudo-terminal (`:pty`) makes the part of a line with
  no newline a line of its own once `:flush_ms` (200 ms) pass with no
  more bytes, so a prompt that waits for its answer is read. Everything a
  session answers — its lines and the stderr tail of its status — passes
  through `Prima.LocusBackends.mask/2` with its owner's secret values.
  Nothing of a process's stdout or stderr is logged.

  ## Recv

  `recv/3` answers at once when a line past `after` is buffered or the
  session has ended, and otherwise waits up to `max_wait_ms` for either;
  the session holds the wait, so nothing else does. A wait counts as a use
  when it is asked, not while it waits.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Locus.Backends.Relay
  alias Prima.LocusBackends

  @flush_ms 200
  # A release the launcher never reports is taken as done after the grace
  # and this bound, as the owners take one.
  @release_timeout_ms 15_000
  # A stop answers once its process is retired, within the grace and the
  # release bound; the caller's wait covers both.
  @call_margin_ms 60_000
  # An answer's room for its members beside its lines.
  @answer_margin_bytes 4_096

  @typedoc "How a session ended: a crash or not, and why."
  @type ended :: %{crash: boolean(), error: String.t() | nil}

  @typedoc "What `recv/3` answers."
  @type received :: %{
          lines: [LocusBackends.line()],
          dropped: non_neg_integer(),
          running: boolean()
        }

  @doc """
  Starts a session. Options:

    * `:owner` (`%{athanor, server, g, e}`), `:session` (its id),
      `:program` (its program's name) and `:spec` (the
      `t:Locus.Launcher.spec/0` its process is spawned with), required;
    * `:secrets`, the owner's secret values;
    * `:launcher` and `:launcher_server`;
    * `:notify`, the process told of `:started`, `{:ended, end}` and
      `:vacated`;
    * `:delay_ms`, the wait before the spawn (0);
    * `:stop_grace_ms` (2 s), `:flush_ms` (200 ms), `:release_timeout_ms`;
    * `:bounds`, overriding `Prima.LocusBackends.bounds/0` by name
      (`:max_line_bytes`, `:max_buffer_bytes`, `:stderr_tail_bytes`,
      `:max_session_bytes`);
    * `:clock`, the milliseconds idleness is read on (monotonic).
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Write `lines` to the session's process, each with a newline: `:running` or `:ended`."
  @spec send_lines(GenServer.server(), [String.t()]) :: :running | :ended
  def send_lines(server, lines) when is_list(lines),
    do: GenServer.call(server, {:send, lines}, @call_margin_ms)

  @doc "The lines past `after`, waiting up to `max_wait_ms` for one or the session's end."
  @spec recv(GenServer.server(), non_neg_integer(), non_neg_integer()) :: received()
  def recv(server, after_seq, max_wait_ms),
    do: GenServer.call(server, {:recv, after_seq, max_wait_ms}, max_wait_ms + @call_margin_ms)

  @doc "End the session's process: answered at once, the process going within its grace."
  @spec close(GenServer.server()) :: :ok
  def close(server), do: GenServer.call(server, {:end, :closed, nil}, @call_margin_ms)

  @doc "End the session for `reason` (its owners' reason, no crash), at once."
  @spec end_session(GenServer.server(), String.t()) :: :ok
  def end_session(server, reason) when is_binary(reason),
    do: GenServer.cast(server, {:end, :ended, reason})

  @doc "End the session if no send and no recv used it within `idle_ms`."
  @spec retire_if_idle(GenServer.server(), non_neg_integer()) :: :ok
  def retire_if_idle(server, idle_ms), do: GenServer.cast(server, {:retire_if_idle, idle_ms})

  @doc "Whether the session runs, and its stderr tail, masked."
  @spec status(GenServer.server(), timeout()) :: %{running: boolean(), stderr_tail: String.t()}
  def status(server, timeout), do: GenServer.call(server, :status, timeout)

  @doc "End the session and answer once nothing of its process is left, or its bound passes."
  @spec stop(GenServer.server(), non_neg_integer()) :: :ok
  def stop(server, grace_ms),
    do: GenServer.call(server, {:stop, grace_ms}, grace_ms + @call_margin_ms)

  # ————— the server —————

  @impl GenServer
  def init(opts) do
    bounds = Map.merge(LocusBackends.bounds(), Map.new(Keyword.get(opts, :bounds, [])))
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    spec = Keyword.fetch!(opts, :spec)

    with {:ok, launcher} <- launcher(opts) do
      state = %{
        owner: Keyword.fetch!(opts, :owner),
        session: Keyword.fetch!(opts, :session),
        program: Keyword.fetch!(opts, :program),
        spec: spec,
        pty: Map.get(spec, :pty) == true,
        secrets: Keyword.get(opts, :secrets, []),
        launcher: launcher,
        launcher_server: Keyword.get(opts, :launcher_server, launcher),
        notify: Keyword.get(opts, :notify),
        stop_grace_ms: Keyword.get(opts, :stop_grace_ms, 2_000),
        flush_ms: Keyword.get(opts, :flush_ms, @flush_ms),
        release_timeout_ms: Keyword.get(opts, :release_timeout_ms, @release_timeout_ms),
        budget: bounds.max_session_bytes - @answer_margin_bytes,
        clock: clock,
        last_used: clock.(),
        relay:
          Relay.new(Map.take(bounds, [:max_line_bytes, :max_buffer_bytes, :stderr_tail_bytes])),
        status: :starting,
        handle: nil,
        released: false,
        ending: nil,
        ended: nil,
        flush_timer: nil,
        waiters: [],
        stoppers: []
      }

      Process.send_after(self(), :spawn, Keyword.get(opts, :delay_ms, 0))
      {:ok, state}
    end
  end

  defp launcher(opts) do
    case Keyword.fetch(opts, :launcher) do
      {:ok, launcher} -> {:ok, launcher}
      :error -> Locus.Executor.executor()
    end
  end

  @impl GenServer
  def handle_call({:send, _lines}, _from, %{status: status} = state) when status != :running,
    do: {:reply, :ended, used(state)}

  def handle_call({:send, lines}, _from, state) do
    data = Enum.map(lines, &[&1, ?\n])

    case state.launcher.send(state.handle, data) do
      :ok -> {:reply, :running, used(state)}
      {:error, _reason} -> {:reply, :ended, used(state)}
    end
  end

  def handle_call({:recv, after_seq, max_wait_ms}, from, state) do
    state = used(state)

    if state.status == :ended or max_wait_ms == 0 or Relay.past?(state.relay, after_seq) do
      {answer, state} = answer(state, after_seq)
      {:reply, answer, state}
    else
      timer = Process.send_after(self(), {:recv_timeout, from}, max_wait_ms)
      {:noreply, %{state | waiters: [{from, after_seq, timer} | state.waiters]}}
    end
  end

  def handle_call({:end, kind, reason}, _from, state),
    do: {:reply, :ok, finish(state, kind, reason)}

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       running: state.status != :ended,
       stderr_tail: Relay.stderr_tail(state.relay, state.secrets)
     }, state}
  end

  def handle_call({:stop, grace_ms}, from, state) do
    state = finish(%{state | stop_grace_ms: grace_ms}, :stopped, nil)

    if state.released,
      do: {:reply, :ok, state},
      else: {:noreply, %{state | stoppers: [from | state.stoppers]}}
  end

  @impl GenServer
  def handle_cast({:end, kind, reason}, state), do: {:noreply, finish(state, kind, reason)}

  def handle_cast({:retire_if_idle, idle_ms}, %{status: :running} = state) do
    if state.clock.() - state.last_used >= idle_ms,
      do: {:noreply, finish(state, :idle, nil)},
      else: {:noreply, state}
  end

  def handle_cast({:retire_if_idle, _idle_ms}, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(:spawn, %{status: :starting, ending: nil} = state) do
    case state.launcher.spawn(state.launcher_server, state.spec) do
      {:ok, handle} ->
        notify(state, :started)
        {:noreply, %{state | handle: handle, status: :running}}

      {:error, reason} ->
        state = %{state | released: true}
        state = ended(state, %{crash: true, error: "spawn refused: #{refusal(reason)}"})
        notify(state, :vacated)
        {:noreply, reply_stoppers(state)}
    end
  end

  # Ended before its process was asked for: nothing of it was started.
  def handle_info(:spawn, state) do
    state = ended(%{state | released: true}, state.ending)
    notify(state, :vacated)
    {:noreply, reply_stoppers(state)}
  end

  def handle_info({launcher, ref, event}, %{launcher: launcher, handle: %{ref: ref}} = state),
    do: {:noreply, on_event(state, event)}

  def handle_info({:recv_timeout, from}, state) do
    case List.keytake(state.waiters, from, 0) do
      {{^from, after_seq, _timer}, waiters} ->
        {answer, state} = answer(%{state | waiters: waiters}, after_seq)
        GenServer.reply(from, answer)
        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:flush, timer}, %{flush_timer: timer} = state),
    do: {:noreply, %{state | flush_timer: nil, relay: Relay.flush(state.relay)} |> wake()}

  def handle_info({:flush, _timer}, state), do: {:noreply, state}

  def handle_info(:release_timeout, %{released: false} = state),
    do: {:noreply, released(state)}

  def handle_info(:release_timeout, state), do: {:noreply, state}

  def handle_info(message, state) do
    Prima.LoggerContext.unexpected(__MODULE__, message)
    {:noreply, state}
  end

  # The owner's secrets and the lines are credentials or may carry one: no
  # status or crash report shows more of them than their size.
  @impl GenServer
  def format_status(status) do
    Map.new(status, fn
      {:state, %{spec: spec, secrets: secrets, relay: relay} = state} ->
        {:state,
         %{
           state
           | spec: %{
               spec
               | env: {:redacted, map_size(spec.env)},
                 argv: {:redacted, length(spec.argv)}
             },
             secrets: {:redacted, length(secrets)},
             relay: %{bytes: relay.bytes, next_seq: relay.next_seq, dropped: relay.dropped},
             waiters: length(state.waiters)
         }}

      {:message, {:send, lines}} ->
        {:message, {:send, {:redacted, length(lines)}}}

      {:message, {launcher, ref, {stream, bytes}}} when stream in [:stdout, :stderr] ->
        {:message, {launcher, ref, {stream, {:redacted, byte_size(bytes)}}}}

      {:log, _log} ->
        {:log, []}

      other ->
        other
    end)
  end

  # ————— the process's events —————

  defp on_event(state, {:stdout, bytes}) when state.status == :running or state.ending != nil do
    case Relay.stdout(state.relay, bytes) do
      {:ok, relay} -> %{state | relay: relay} |> arm_flush() |> wake()
      {:error, :line_too_long} -> overflow(state)
    end
  end

  defp on_event(state, {:stdout, _bytes}), do: state

  defp on_event(state, {:stderr, bytes}), do: %{state | relay: Relay.stderr(state.relay, bytes)}

  # The leader's end; the session ends once nothing of it is left, so every
  # line it wrote is read first.
  defp on_event(state, {:exited, code, signal}) do
    if state.ending,
      do: state,
      else: %{state | ending: exit_end(code, signal)}
  end

  defp on_event(state, :released), do: released(state)
  defp on_event(state, _event), do: state

  defp exit_end(0, nil), do: %{crash: false, error: nil}

  defp exit_end(code, signal),
    do: %{crash: true, error: "exited code=#{spelled(code)} signal=#{spelled(signal)}"}

  defp spelled(nil), do: "null"
  defp spelled(value), do: to_string(value)

  defp refusal({:refused, code}) when is_binary(code), do: code
  defp refusal({kind, _detail}) when is_atom(kind), do: Atom.to_string(kind)
  defp refusal(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp refusal(_reason), do: "spawn_failed"

  defp overflow(state) do
    Logger.error(
      "[Locus.Backends.Backend] #{label(state)}: a line exceeded " <>
        "#{state.relay.max_line_bytes} bytes; killing the session"
    )

    _ = state.launcher.signal(state.handle, "SIGKILL")

    finish(state, :crash, "line too long")
  end

  # The process gone: the part of a line it left is a line, and the
  # session is ended now if it was not already.
  defp released(%{released: true} = state), do: state

  defp released(state) do
    state = %{state | released: true, relay: Relay.flush(state.relay)}
    # Released with no exit heard: the launcher let every spawn go.
    state = ended(state, state.ending || %{crash: true, error: "exited code=null signal=null"})
    notify(state, :vacated)
    reply_stoppers(state)
  end

  defp reply_stoppers(state) do
    Enum.each(state.stoppers, &GenServer.reply(&1, :ok))
    %{state | stoppers: []}
  end

  # ————— ending —————

  # The session's process asked to end, once: the session answers
  # `running: false` from now on.
  defp finish(%{ending: ending} = state, _kind, _reason) when ending != nil,
    do: ended(state, ending)

  defp finish(state, kind, reason) do
    ending =
      case kind do
        :crash -> %{crash: true, error: reason}
        :ended -> %{crash: false, error: reason}
        _other -> %{crash: false, error: nil}
      end

    state = %{state | ending: ending}

    case state.handle do
      nil ->
        ended(state, ending)

      handle ->
        :ok = state.launcher.release(state.launcher_server, handle, state.stop_grace_ms)

        Process.send_after(
          self(),
          :release_timeout,
          state.stop_grace_ms + state.release_timeout_ms
        )

        ended(state, ending)
    end
  end

  defp ended(%{ended: nil} = state, ended) do
    state = %{state | status: :ended, ended: ended}
    notify(state, {:ended, ended})
    wake(state)
  end

  defp ended(state, _ended), do: state

  # ————— lines —————

  defp arm_flush(%{pty: true} = state) do
    if Relay.partial?(state.relay) do
      timer = make_ref()
      Process.send_after(self(), {:flush, timer}, state.flush_ms)
      %{state | flush_timer: timer}
    else
      %{state | flush_timer: nil}
    end
  end

  defp arm_flush(state), do: state

  # Every wait a new line or the end answers.
  defp wake(state) do
    {ready, waiting} =
      Enum.split_with(state.waiters, fn {_from, after_seq, _timer} ->
        state.status == :ended or Relay.past?(state.relay, after_seq)
      end)

    Enum.reduce(ready, %{state | waiters: waiting}, fn {from, after_seq, timer}, state ->
      Process.cancel_timer(timer)
      {answer, state} = answer(state, after_seq)
      GenServer.reply(from, answer)
      state
    end)
  end

  defp answer(state, after_seq) do
    {lines, dropped, relay} = Relay.take(state.relay, after_seq, state.budget)
    lines = Enum.map(lines, &%{&1 | text: LocusBackends.mask(&1.text, state.secrets)})
    {%{lines: lines, dropped: dropped, running: state.status != :ended}, %{state | relay: relay}}
  end

  defp used(state), do: %{state | last_used: state.clock.()}

  defp label(state),
    do: "#{state.owner.athanor}/#{state.owner.server} #{state.program} #{state.session}"

  defp notify(%{notify: nil}, _event), do: :ok
  defp notify(%{notify: pid}, event), do: send(pid, {__MODULE__, self(), event})
end
