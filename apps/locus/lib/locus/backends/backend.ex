# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Backends.Backend do
  @moduledoc """
  One session of a program of one owner (an athanor's `mcp_servers` row at
  a generation and epoch): its process, started through a
  `Locus.Launcher`, and the sequence-numbered buffer of what it writes
  (`Locus.Backends.Relay`). It knows no protocol. A session of mode `:run`
  takes lines with `send_lines/2`; one of mode `:terminal` runs on a
  pseudo-terminal and takes bytes with `input/2` and a size with
  `resize/3`; `recv/3` answers lines of the one and chunks of bytes of the
  other, and what they mean is the owner's.

  ## Its life

  A session starts its process at once, or after `:delay_ms` when its
  owners hold it back for a crash's backoff, and tells its owners
  `:started` once the launcher answers the spawn. It is `running` until
  its process ends, and then `ended`: what it buffered stays readable,
  every later `recv/3` answers `running: false`, and every later
  `send_lines/2`, `input/2` and `resize/3` answers `:ended`. The process
  stays its until it is gone and its owners hear `{:ended, end}`, `end`
  saying whether the end was a crash (`crash: true`: the process exited
  of its own accord with a status other than 0 or by a signal, wrote a
  line past `Prima.LocusBackends.max_line_bytes/0`, or its spawn was
  refused) and why. Where memory killed the process they also hear
  `{:memory, cause}` (`:cap` its own bound, `:machine` a limit above it,
  `:either` one of the two where which is not known) once, when the
  launcher tells the leader's exit: before `:vacated`, and after a close
  was asked as before one, so a close that answered at once loses no cause.
  Once nothing of its process is left (the launcher's `:released`, or
  its refusal of a spawn it made nothing of), `:vacated`, after which it
  holds no uid. A spawn the launcher refused after making something of it
  (`{:refused, code, handle}`) ends the session refused at once and is
  vacated at the launcher's `:released` on that handle, as a started one
  is: the refusal is not a release. A spawn the launcher did not answer
  (`launcher_unavailable`) is `:unconfirmed` instead: it may yet run, and
  only the launcher can say.

  `close/1`, `retire_if_idle/2` (no message within the idle period),
  `end_session/2` (its owners ending it: the cap of its home, its home's
  reset or retirement) and `stop/2` (its owner retired) end the process
  with the stop grace; none of them is a crash. A session ended this way
  answers `running: false` at once, however long its process takes to
  go.

  ## Its use

  Its process runs in the place its spec names, which the owner table made
  for it (`Locus.Backends.Owners`, "Places"): what it uses is read there,
  by the keeper, and never asked of this process.

  ## Masking

  Everything a session answers is masked with its owner's secret values:
  a run's lines as they are buffered and the stderr tail of its status
  through `Prima.LocusBackends.mask/2`, a terminal's bytes as they arrive
  through one `Prima.LocusBackends.masker/1`, so a value split between two
  of its writes is masked whole; what the masker holds when the process is
  gone is buffered as `Prima.LocusBackends.mask_end/1` answers it. So what
  is buffered is what is answered, and an answer's cost is known before
  it is taken. Nothing of a process's stdout or stderr is logged.

  ## Unread

  What its relay buffers is held in the backends role's one count of
  unread output (`Locus.Output`, the `:output` option): the session names
  its relay's `bytes` after every change of them, a write buffered, a part
  line flushed, lines let go by a later `after` and lines dropped. Told
  to drop, in the answer to its own hold or by `{Locus.Output, :over}`,
  it drops its oldest, counted in `dropped` as its own bound drops them,
  and holds again. It waits on no other session.

  Each piece of the process's output is taken (`c:Locus.Launcher.taken/1`)
  once it is buffered, and the launcher tells the session no more before:
  what the process writes past that waits outside this node's memory,
  and the process's own writes wait behind it, as a pipe's do. A reader
  that never reads stalls nothing, since the session takes and drops,
  counted. A write to the process is its caller's (`send_lines/2`,
  `input/2`), answered once written, so a process that stops reading its
  input holds its callers and never its session.

  ## Recv

  `recv/3` is ready to be answered at once when a line or a chunk past
  `after` is buffered, the session has ended or `max_wait_ms` is 0, and
  otherwise once either comes within `max_wait_ms`; the session holds the
  wait, so nothing else does. A ready recv with nothing to take is
  answered then. One with lines or chunks to take asks the role's
  answering count (`Locus.Output.ask/3`) for what `Locus.Backends.Relay.cost/3`
  says they cost, by the instant its wait ends. Granted, it takes within
  the grant, never more, gives the grant to the caller and answers it as
  `grant`, which the caller returns once the answer's bytes are gone, or
  frees by dying; found `:full`, it answers no lines or chunks, and the
  same `after` reads them later. A wait counts as a use when it is asked,
  not while it waits.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Locus.Backends.Relay
  alias Prima.LocusBackends

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

  @typedoc """
  What `recv/3` answers: lines of a run, chunks of a terminal, and the
  grant of the answering count their bytes hold when there are any.
  """
  @type received ::
          %{
            required(:lines) => [LocusBackends.line()],
            required(:dropped) => non_neg_integer(),
            required(:running) => boolean(),
            required(:exit_code) => 0..255 | nil,
            optional(:grant) => Locus.Output.grant()
          }
          | %{
              required(:chunks) => [LocusBackends.chunk()],
              required(:dropped) => non_neg_integer(),
              required(:running) => boolean(),
              required(:exit_code) => 0..255 | nil,
              optional(:grant) => Locus.Output.grant()
            }

  @doc """
  Starts a session. Options:

    * `:owner` (`%{athanor, server, g, e}`), `:session` (its id),
      `:program` (its program's name) and `:spec` (the
      `t:Locus.Launcher.spec/0` its process is spawned with, a
      terminal's naming its `pty`), required;
    * `:mode`, `:run` (the default) or `:terminal`;
    * `:secrets`, the owner's secret values;
    * `:launcher` and `:launcher_server`;
    * `:notify`, the process told of `:started`, `{:ended, end}`,
      `{:memory, cause}` and `:vacated`;
    * `:output`, the count of unread and answered output it holds in
      (`Locus.Output.server(:backends)`);
    * `:delay_ms`, the wait before the spawn (0);
    * `:stop_grace_ms` (2 s), `:release_timeout_ms`;
    * `:bounds`, overriding `Prima.LocusBackends.bounds/0` by name
      (`:max_line_bytes`, `:max_buffer_bytes`, `:max_buffer_lines`,
      `:line_charge_bytes`, `:stderr_tail_bytes`, `:max_session_bytes`);
    * `:clock`, the milliseconds idleness is read on (monotonic).
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Write `lines` to the session's process, each with a newline: `:running` or `:ended`."
  @spec send_lines(GenServer.server(), [String.t()]) :: :running | :ended
  def send_lines(server, lines) when is_list(lines),
    do: write(server, {:send, Enum.map(lines, &[&1, ?\n])})

  @doc "Write `bytes` to a terminal session's process as they are: `:running` or `:ended`."
  @spec input(GenServer.server(), binary()) :: :running | :ended
  def input(server, bytes) when is_binary(bytes), do: write(server, {:input, bytes})

  # The session names how the bytes reach its process, and the caller
  # writes them, answered once they are written (`c:Locus.Launcher.send/2`):
  # a process that does not read its input holds its caller, never its
  # session, which goes on taking the process's output.
  defp write(server, request) do
    case GenServer.call(server, request, @call_margin_ms) do
      {:write, launcher, handle, data} ->
        case launcher.send(handle, data) do
          :ok -> :running
          {:error, _reason} -> :ended
        end

      :ended ->
        :ended
    end
  end

  @doc "Set a terminal session's size: `:running` or `:ended`."
  @spec resize(GenServer.server(), pos_integer(), pos_integer()) :: :running | :ended
  def resize(server, rows, cols) when is_integer(rows) and is_integer(cols),
    do: GenServer.call(server, {:resize, rows, cols}, @call_margin_ms)

  @doc """
  The lines or chunks past `after`, waiting up to `max_wait_ms` for one or
  the session's end, and for room to answer them. An answer with any
  carries their `grant`, which is the caller's to return.
  """
  @spec recv(GenServer.server(), non_neg_integer(), non_neg_integer()) :: received()
  def recv(server, after_seq, max_wait_ms),
    do: GenServer.call(server, {:recv, after_seq, max_wait_ms}, max_wait_ms + @call_margin_ms)

  @doc "The bound past the stop grace after which a release the launcher never reports ends a stop's wait."
  @spec release_timeout_ms() :: pos_integer()
  def release_timeout_ms, do: @release_timeout_ms

  @doc "End the session's process: answered at once, the process going within its grace."
  @spec close(GenServer.server()) :: :ok
  def close(server), do: GenServer.call(server, {:end, :closed, nil}, @call_margin_ms)

  @doc "End the session for `reason` (its owners' reason, no crash), at once."
  @spec end_session(GenServer.server(), String.t()) :: :ok
  def end_session(server, reason) when is_binary(reason),
    do: GenServer.cast(server, {:end, :ended, reason})

  @doc "End the session if no message used it within `idle_ms`."
  @spec retire_if_idle(GenServer.server(), non_neg_integer()) :: :ok
  def retire_if_idle(server, idle_ms), do: GenServer.cast(server, {:retire_if_idle, idle_ms})

  @doc """
  Whether the session runs, and its stderr: the masked tail of a scratch
  session's, and only the length of a kept session's, whose stderr may
  carry its home's contents, which are the person's.
  """
  @spec status(GenServer.server(), timeout()) :: %{
          running: boolean(),
          stderr_tail: String.t() | nil,
          stderr_bytes: non_neg_integer()
        }
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
    mode = Keyword.get(opts, :mode, :run)
    secrets = Keyword.get(opts, :secrets, [])

    with {:ok, launcher} <- launcher(opts) do
      state = %{
        owner: Keyword.fetch!(opts, :owner),
        session: Keyword.fetch!(opts, :session),
        program: Keyword.fetch!(opts, :program),
        spec: spec,
        mode: mode,
        secrets: secrets,
        masker: if(mode == :terminal, do: LocusBackends.masker(secrets)),
        launcher: launcher,
        launcher_server: Keyword.get(opts, :launcher_server, launcher),
        notify: Keyword.get(opts, :notify),
        output: Keyword.get(opts, :output, Locus.Output.server(:backends)),
        # The bytes last held in the count.
        held: 0,
        stop_grace_ms: Keyword.get(opts, :stop_grace_ms, 2_000),
        release_timeout_ms: Keyword.get(opts, :release_timeout_ms, @release_timeout_ms),
        budget: bounds.max_session_bytes - @answer_margin_bytes,
        clock: clock,
        last_used: clock.(),
        relay:
          bounds
          |> Map.take([
            :max_line_bytes,
            :max_buffer_bytes,
            :max_buffer_lines,
            :line_charge_bytes,
            :stderr_tail_bytes
          ])
          |> Map.merge(%{mode: mode, secrets: secrets})
          |> Relay.new(),
        status: :starting,
        handle: nil,
        released: false,
        ending: nil,
        ended: nil,
        # Recvs waiting for a line or the end, and ready ones asking the
        # count for room, by the ask's reference.
        waiters: [],
        asking: %{},
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
  def handle_call({kind, _data}, _from, %{status: status} = state)
      when kind in [:send, :input] and status != :running,
      do: {:reply, :ended, used(state)}

  def handle_call({kind, data}, _from, state) when kind in [:send, :input],
    do: {:reply, {:write, state.launcher, state.handle, data}, used(state)}

  def handle_call({:resize, _rows, _cols}, _from, %{status: status} = state)
      when status != :running,
      do: {:reply, :ended, used(state)}

  def handle_call({:resize, rows, cols}, _from, state) do
    case state.launcher.resize(state.handle, rows, cols) do
      :ok -> {:reply, :running, used(state)}
      {:error, _reason} -> {:reply, :ended, used(state)}
    end
  end

  def handle_call({:recv, after_seq, max_wait_ms}, from, state) do
    state = used(state)
    deadline = System.monotonic_time(:millisecond) + max_wait_ms

    if state.status == :ended or max_wait_ms == 0 or Relay.past?(state.relay, after_seq) do
      {:noreply, ready(state, from, after_seq, deadline)}
    else
      timer = Process.send_after(self(), {:recv_timeout, from}, max_wait_ms)
      {:noreply, %{state | waiters: [{from, after_seq, deadline, timer} | state.waiters]}}
    end
  end

  def handle_call({:end, kind, reason}, _from, state),
    do: {:reply, :ok, finish(state, kind, reason)}

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       running: state.status != :ended,
       stderr_tail:
         if(Map.has_key?(state.spec, :home),
           do: nil,
           else: Relay.stderr_tail(state.relay, state.secrets)
         ),
       stderr_bytes: Relay.stderr_bytes(state.relay)
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

      # The launcher could not be heard: the spawn may yet be taken, so
      # nothing says its process is not running, and only the launcher can.
      {:error, {:launcher_unavailable, _kind} = reason} ->
        state = ended(state, %{crash: true, error: "spawn refused: #{refusal(reason)}"})
        notify(state, :unconfirmed)
        {:noreply, reply_stoppers(state)}

      # Refused after the launcher made something of it: that is the
      # launcher's until it says it is gone, on the handle, as a started
      # process's release is said.
      {:error, {:refused, _code, handle} = reason} ->
        refused = %{crash: true, error: "spawn refused: #{refusal(reason)}"}
        {:noreply, ended(%{state | handle: handle}, refused)}

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

  # Bytes of the process are taken once handled: the launcher tells the
  # next only then, so what the process writes waits behind this session
  # rather than in its mailbox.
  def handle_info(
        {launcher, ref, {stream, _bytes} = event},
        %{launcher: launcher, handle: %{ref: ref}} = state
      )
      when stream in [:stdout, :stderr] do
    state = on_event(state, event)
    :ok = launcher.taken(state.handle)
    {:noreply, state}
  end

  def handle_info({launcher, ref, event}, %{launcher: launcher, handle: %{ref: ref}} = state),
    do: {:noreply, on_event(state, event)}

  def handle_info({:recv_timeout, from}, state) do
    case List.keytake(state.waiters, from, 0) do
      {{^from, after_seq, deadline, _timer}, waiters} ->
        {:noreply, ready(%{state | waiters: waiters}, from, after_seq, deadline)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({Locus.Output, ref, answer}, %{asking: asking} = state)
      when is_map_key(asking, ref) do
    {{from, after_seq, cost}, asking} = Map.pop!(asking, ref)
    state = %{state | asking: asking}

    case answer do
      {:ok, grant} -> {:noreply, reply(state, from, after_seq, cost, grant)}
      :full -> {:noreply, reply(state, from, after_seq, 0, nil)}
    end
  end

  # Told to drop: holding again is how the count is answered.
  def handle_info({Locus.Output, :over}, state), do: {:noreply, hold(state)}

  # A release the launcher has not reported within its bound ends the
  # stoppers' wait and the session, never what it holds: that is gone only
  # when the launcher says so, as `:released` or to the spawn's heir.
  def handle_info(:release_timeout, %{released: false} = state) do
    state = ended(state, state.ending || %{crash: true, error: "exited code=null signal=null"})
    {:noreply, reply_stoppers(state)}
  end

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
             masker: if(state.masker, do: :redacted),
             relay: %{bytes: relay.bytes, next_seq: relay.next_seq, dropped: relay.dropped},
             waiters: length(state.waiters)
         }}

      {:message, {:send, lines}} ->
        {:message, {:send, {:redacted, length(lines)}}}

      {:message, {:input, bytes}} ->
        {:message, {:input, {:redacted, byte_size(bytes)}}}

      {:message, {launcher, ref, {stream, bytes}}} when stream in [:stdout, :stderr] ->
        {:message, {launcher, ref, {stream, {:redacted, byte_size(bytes)}}}}

      {:log, _log} ->
        {:log, []}

      other ->
        other
    end)
  end

  # ————— the process's events —————

  defp on_event(%{mode: :terminal} = state, {:stdout, bytes})
       when state.status == :running or state.ending != nil do
    {released, masker} = LocusBackends.mask_chunk(state.masker, bytes)

    %{state | masker: masker, relay: Relay.output(state.relay, released)}
    |> unread()
    |> wake()
  end

  defp on_event(state, {:stdout, bytes}) when state.status == :running or state.ending != nil do
    case Relay.stdout(state.relay, bytes) do
      {:ok, relay} -> %{state | relay: relay} |> unread() |> wake()
      {:error, :line_too_long} -> overflow(state)
    end
  end

  defp on_event(state, {:stdout, _bytes}), do: state

  defp on_event(state, {:stderr, bytes}), do: %{state | relay: Relay.stderr(state.relay, bytes)}

  # The leader's end; the session ends once nothing of it is left, so every
  # line it wrote is read first.
  defp on_event(state, {:exited, code, signal, memory}) do
    if memory, do: notify(state, {:memory, memory})

    if state.ending,
      do: state,
      else: %{state | ending: exit_end(code, signal)}
  end

  defp on_event(state, :released), do: released(state)
  defp on_event(state, _event), do: state

  # Only an exit of the process's own accord with a status carries one.
  defp exit_end(0, nil), do: %{crash: false, error: nil, exit_code: 0}

  defp exit_end(code, signal),
    do: %{
      crash: true,
      error: "exited code=#{spelled(code)} signal=#{spelled(signal)}",
      exit_code: if(signal == nil and is_integer(code) and code in 0..255, do: code)
    }

  defp spelled(nil), do: "null"
  defp spelled(value), do: to_string(value)

  defp refusal({:refused, code}) when is_binary(code), do: code
  defp refusal({:refused, code, _handle}) when is_binary(code), do: code
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

  # The process gone: the part of a line it left is a line, what a
  # terminal's masker held is masked whole, and the session is ended now if
  # it was not already.
  defp released(%{released: true} = state), do: state

  defp released(state) do
    state = unread(%{state | released: true, relay: rest(state)})
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

  # ————— what it wrote —————

  defp rest(%{mode: :terminal} = state),
    do: Relay.output(state.relay, LocusBackends.mask_end(state.masker))

  defp rest(state), do: Relay.flush(state.relay)

  # The relay's bytes named to the count after every change of them, and
  # named again after each drop it is told to make, until it is taken.
  defp unread(%{relay: %{bytes: bytes}, held: bytes} = state), do: state
  defp unread(state), do: hold(state)

  defp hold(state) do
    bytes = state.relay.bytes

    case Locus.Output.hold(state.output, bytes) do
      :ok -> %{state | held: bytes}
      {:drop_to, most} -> hold(%{state | relay: Relay.drop_to(state.relay, most)})
    end
  end

  # Every wait a new line or the end makes ready.
  defp wake(state) do
    {ready, waiting} =
      Enum.split_with(state.waiters, fn {_from, after_seq, _deadline, _timer} ->
        state.status == :ended or Relay.past?(state.relay, after_seq)
      end)

    Enum.reduce(ready, %{state | waiters: waiting}, fn waiter, state ->
      {from, after_seq, deadline, timer} = waiter
      Process.cancel_timer(timer)
      ready(state, from, after_seq, deadline)
    end)
  end

  # A recv ready to be answered: with nothing to take it is answered now;
  # otherwise the count is asked for what its answer costs, by the instant
  # its own wait ends, and it is answered when the count answers.
  defp ready(state, from, after_seq, deadline) do
    case Relay.cost(state.relay, after_seq, state.budget) do
      0 ->
        reply(state, from, after_seq, 0, nil)

      cost ->
        ref = Locus.Output.ask(state.output, cost, deadline)
        %{state | asking: Map.put(state.asking, ref, {from, after_seq, cost})}
    end
  end

  # What fits `budget` is taken, and its grant, when there is one, is the
  # caller's before the answer reaches it.
  defp reply(state, from, after_seq, budget, grant) do
    {answer, state} = answer(state, after_seq, budget)

    answer =
      case grant do
        nil ->
          answer

        grant ->
          {pid, _tag} = from
          :ok = Locus.Output.give(grant, pid)
          Map.put(answer, :grant, grant)
      end

    GenServer.reply(from, answer)
    unread(state)
  end

  defp answer(state, after_seq, budget) do
    {taken, dropped, relay} = Relay.take(state.relay, after_seq, budget)
    running = state.status != :ended
    exit_code = if running, do: nil, else: Map.get(state.ending || %{}, :exit_code)
    taken_as = if state.mode == :terminal, do: :chunks, else: :lines
    answer = Map.put(%{dropped: dropped, running: running, exit_code: exit_code}, taken_as, taken)
    {answer, %{state | relay: relay}}
  end

  defp used(state), do: %{state | last_used: state.clock.()}

  defp label(state),
    do: "#{state.owner.athanor}/#{state.owner.server} #{state.program} #{state.session}"

  defp notify(%{notify: nil}, _event), do: :ok
  defp notify(%{notify: pid}, event), do: send(pid, {__MODULE__, self(), event})
end
