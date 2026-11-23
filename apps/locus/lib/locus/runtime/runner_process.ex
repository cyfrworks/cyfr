# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.RunnerProcess do
  @moduledoc """
  The service's handle on one runner: the OS process the keeper started
  for it (`Locus.Runtime.Keeper`), the control channel to it and the
  `Prima.RunnerControl` lines on that channel.

  Started by `Locus.Runtime.RunnerPool` with the keeper, the runner's id and what
  to start it with, it spawns the runner from its own process, so the
  keeper's messages reach it, and tells its owner what happens as
  `{Locus.Runtime.RunnerProcess, pid, event}`: `:ready` once the channel is
  attached, `{:message, message}` for each frame the runner sends
  (`complete` or `exit`; a clean `complete` whose place the keeper did not
  make warm again is `{:message, complete, {:error, {:assign, reason}}}`;
  a frame the runner may not send, or a line that is not one, is
  `{:error, {:protocol, reason}}`), `:closed` once the
  runner's end of the channel is closed, `{:exited, how}` once its
  process ended and, for an attached runner, after its channel closed or
  a bound passed, `:released` once the keeper has retired it,
  `{:refused, reason}` when the keeper refused the spawn, so no process of
  the runner ever ran and nothing is left to release, and
  `{:error, reason}` for a later failure of the keeper's. A message the service
  sends (`send_message/2`) is written at once, or held until the channel
  attaches. `release/2` asks the keeper to end the runner; when this
  process itself is stopped, the runner is released with no grace.

  When the runner attaches, this process starts the service's end of its
  relay (`Locus.Runtime.Relay`), linked, and hands it every relay byte the keeper
  carries; the relay writes back through the keeper itself. `assign/6`
  binds the relay to the attempt it assigns, from the assignment and the
  opened keys, before the `assign` is written (or, before the runner
  attaches, once the relay starts), so the runner's first host call finds
  it bound. A relay that stops because it closed the channel, or failed,
  is `{:error, {:relay, reason}}`: the pool retires the runner, as for any
  failure. One whose runner's end of the stream ended is heard as the
  runner's own end.

  Before its spawn this process makes the runner's place, named by the
  runner's id, `warm` and no athanor's (`c:Locus.Runtime.Keeper.place/3`):
  this process is the place's owner, so a runner that never spawned leaves
  none behind it, and one the keeper refused to place is `{:refused,
  reason}`, nothing of it having run. This process assigns the place
  itself (`c:Locus.Runtime.Keeper.assign/4`), so every assign of a runner
  is made in the order of its work, each waiting for the keeper's answer
  three seconds at most: `assign/6` makes it `run` of the work's
  athanor (its keys' `attempt.athanor_id`) before it binds the relay or
  holds or writes anything of the work, waits for that no later than its
  start's deadline, and answers `{:error, {:unsent, {:assign, reason}}}`,
  nothing of the work held or written, where the keeper does not apply it
  in that time, and `{:error, {:unsent, :past_deadline}}` where it applied
  it but the deadline has passed; a clean `complete` read from the runner
  makes it `warm` again, still that athanor's, before the owner hears the
  `complete`, and one the keeper does not apply is heard with it as
  `{:message, complete, {:error, {:assign, reason}}}`, the completion and
  the end of a runner no longer one to reuse in one event.

  Guest data never crosses here: control bytes are frames, and the
  runner's own log lines, which the keeper relays, are logged under the
  runner's id. An `assign` carries the attempt's opened keys, so its
  status and a crash report show only the size of what it holds for the
  channel.
  """

  use GenServer

  require Logger

  alias Prima.RunnerControl

  # A line past the protocol's bound before its newline is not a frame.
  @max_line_bytes RunnerControl.max_line_bytes()

  # The keeper's refusals of a write that come before any byte of it: the
  # channel closed or unknown, or its socket (`:einval`) already closed.
  @unwritten [:control_closed, :unknown_runner, :einval]

  # How long the process's end is held for its control stream to close.
  @control_drain_ms 1_000

  # The longest an assign of the runner's place waits for the keeper's
  # answer, so a start whose first runner's keeper does not answer has
  # time left to go to another (`Locus.Runtime.WorkerService`).
  @assign_wait_ms 3_000

  # This process answers an assign by its start's deadline; the caller
  # waits this much past it for that answer.
  @assign_answer_ms 500

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc """
  Start a handle. Options: `:id`, `:keeper`, `:keeper_opts` (the keeper's
  options, default none), `:spec` (`t:Locus.Runtime.Keeper.spec/0`), `:owner`.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Send `message`, a `cancel_child`, to the runner; an `assign` is `assign/6`'s."
  @spec send_message(pid(), RunnerControl.message()) :: :ok | {:error, term()}
  def send_message(pid, %{type: :cancel_child} = message) do
    line = message |> RunnerControl.encode() |> IO.iodata_to_binary()
    GenServer.call(pid, {:send, line})
  end

  @doc """
  Assign the runner the attempt `token` names: bind its relay to the
  attempt (`Locus.Runtime.Relay.bind/2`, `host_url` being where its calls go when
  the assignment names no address), then send the `assign` with `input`
  and the opened `keys`, and nothing of it once `deadline` (monotonic
  milliseconds) has passed. `{:error, {:unsent, reason}}` when nothing of it
  reached the runner, so it may be sent to another; any other error may
  follow a write. Raises for an `assign` the protocol refuses.
  """
  @spec assign(
          pid(),
          String.t(),
          String.t(),
          Prima.WorkerAuth.attempt_keys(),
          String.t(),
          integer()
        ) :: :ok | {:error, term()}
  def assign(pid, token, input, keys, host_url, deadline)
      when is_binary(token) and is_binary(input) and is_binary(host_url) and
             is_integer(deadline) do
    line =
      %{type: :assign, assignment: token, input: input, keys: keys}
      |> RunnerControl.encode()
      |> IO.iodata_to_binary()

    GenServer.call(
      pid,
      {:assign, line, %{assignment: token, keys: keys, host_url: host_url}, deadline},
      max(deadline - now(), 0) + @assign_answer_ms
    )
  catch
    # An exit's reason carries the call, the attempt's keys among it.
    :exit, {:noproc, _call} -> {:error, {:unsent, :gone}}
    :exit, _reason -> {:error, :handle_failed}
  end

  @doc "End the runner: a term signal, `grace_ms` to report, then the kill."
  @spec release(pid(), non_neg_integer()) :: :ok
  def release(pid, grace_ms) when is_integer(grace_ms) and grace_ms >= 0,
    do: GenServer.cast(pid, {:release, grace_ms})

  @doc "The runner's id and OS pid, as far as known."
  @spec info(pid()) :: %{id: String.t(), os_pid: non_neg_integer() | nil}
  def info(pid), do: GenServer.call(pid, :info)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       id: Keyword.fetch!(opts, :id),
       keeper: Keyword.fetch!(opts, :keeper),
       keeper_opts: Keyword.get(opts, :keeper_opts, []),
       spec: Keyword.fetch!(opts, :spec),
       owner: Keyword.fetch!(opts, :owner),
       channel: nil,
       relay: nil,
       binding: nil,
       # The athanor of the work last assigned, whose its place stays at rest.
       athanor: nil,
       os_pid: nil,
       attached: false,
       pending: [],
       buffer: "",
       closed: false,
       exited: nil,
       released: false
     }, {:continue, :spawn}}
  end

  @impl true
  def handle_continue(:spawn, state) do
    with :ok <- state.keeper.place(state.spec.runner, %{kind: "warm"}, state.keeper_opts),
         {:ok, channel, events} <- state.keeper.spawn(state.spec) do
      {:noreply, Enum.reduce(events, %{state | channel: channel}, &on_event/2)}
    else
      {:error, reason} ->
        notify(state, {:refused, reason})
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:send, line}, _from, %{attached: true} = state),
    do: {:reply, state.keeper.send(state.channel, line), state}

  def handle_call({:send, line}, _from, state),
    do: {:reply, :ok, %{state | pending: [state.pending, line]}}

  def handle_call(
        {:assign, _line, _binding, _deadline},
        _from,
        %{relay: nil, attached: true} = state
      ),
      do: {:reply, {:error, {:unsent, {:relay, :closed}}}, state}

  # The place is the work's athanor's run before anything of the work is
  # bound, held or written, and nothing of the work is once the start's
  # deadline has passed.
  def handle_call({:assign, line, binding, deadline}, _from, state) do
    athanor = binding.keys.attempt.athanor_id
    whose = %{kind: "run", athanor: athanor}
    until = min(now() + @assign_wait_ms, deadline)

    case state.keeper.assign(state.spec.runner, whose, until, state.keeper_opts) do
      :ok ->
        if now() < deadline,
          do: assigned(%{state | athanor: athanor}, line, binding),
          else: {:reply, {:error, {:unsent, :past_deadline}}, state}

      {:error, reason} ->
        {:reply, {:error, {:unsent, {:assign, reason}}}, state}
    end
  end

  def handle_call(:info, _from, state), do: {:reply, %{id: state.id, os_pid: state.os_pid}, state}

  @impl true
  def handle_cast({:release, grace_ms}, state), do: {:noreply, release_runner(state, grace_ms)}

  # The relay stopped. One that closed the channel, or failed, retires a
  # runner still running. One whose runner's end of the stream ended is the
  # runner's own exit, heard as its channel's close and its process's end:
  # a runner that closed its relay and runs on reaches nothing, and fails
  # what it holds.
  @impl true
  def handle_info({:EXIT, relay, {:shutdown, :relay_ended}}, %{relay: relay} = state),
    do: {:noreply, %{state | relay: nil}}

  def handle_info({:EXIT, relay, reason}, %{relay: relay} = state) do
    state = %{state | relay: nil}
    unless state.closed or state.released, do: notify(state, {:error, {:relay, reason}})
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:control_drained, ref}, %{exited: {ref, _how}} = state),
    do: {:noreply, flush_exited(state)}

  def handle_info({:control_drained, _ref}, state), do: {:noreply, state}

  def handle_info(msg, %{channel: channel} = state) when channel != nil do
    case state.keeper.handle_message(channel, msg) do
      {:events, events, channel} ->
        {:noreply, Enum.reduce(events, %{state | channel: channel}, &on_event/2)}

      :unknown ->
        Prima.LoggerContext.unexpected(__MODULE__, msg)
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    _ = release_runner(state, 0)
    :ok
  end

  # What is held until the channel attaches is an `assign`, whose line
  # carries the attempt's opened keys, and so is the call that sent it: no
  # status or crash report shows more of either than its size, and the
  # debug log, which holds both, is left out.
  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, %{pending: pending} = state} ->
        {:state,
         %{
           state
           | pending: {:redacted, IO.iodata_length(pending)},
             binding: if(state.binding, do: :redacted)
         }}

      {:message, {:send, line}} ->
        {:message, {:send, {:redacted, byte_size(line)}}}

      {:message, {:assign, line, _binding, deadline}} ->
        {:message, {:assign, {:redacted, byte_size(line)}, :redacted, deadline}}

      {:log, _log} ->
        {:log, []}

      other ->
        other
    end)
  end

  defp on_event({:spawned, os_pid}, state), do: %{state | os_pid: os_pid}

  defp on_event(:attached, state) do
    state = start_relay(state)
    pending = IO.iodata_to_binary(state.pending)

    if pending != "" do
      case state.keeper.send(state.channel, pending) do
        :ok -> :ok
        {:error, reason} -> notify(state, {:error, {:send_failed, reason}})
      end
    end

    notify(state, :ready)
    %{state | attached: true, pending: []}
  end

  defp on_event({:control, data}, state), do: lines(%{state | buffer: state.buffer <> data})

  defp on_event({:relay, data}, %{relay: relay} = state) when relay != nil do
    Locus.Runtime.Relay.deliver(relay, data)
    state
  end

  defp on_event({:relay, _data}, state), do: state

  defp on_event(:relay_closed, %{relay: relay} = state) when relay != nil do
    Locus.Runtime.Relay.ended(relay)
    state
  end

  defp on_event(:relay_closed, state), do: state

  defp on_event({:log, data}, state) do
    Logger.info("[Locus.Runtime.RunnerProcess] runner #{state.id}: #{String.trim_trailing(data)}")
    state
  end

  defp on_event(:control_closed, %{closed: false} = state) do
    notify(state, :closed)
    flush_exited(%{state | closed: true})
  end

  defp on_event(:control_closed, state), do: state

  # The keeper hears a runner's end apart from its control stream, which
  # comes on the relay's connection, so the two arrive in no defined
  # order. The end of a runner whose stream is still open is held until
  # the stream closes, bounded by `@control_drain_ms`, so the frames the
  # runner wrote before it ended (its `exit`, with what it holds) reach the
  # owner first.
  defp on_event({:exited, how}, %{attached: true, closed: false} = state) do
    ref = make_ref()
    Process.send_after(self(), {:control_drained, ref}, @control_drain_ms)
    %{state | exited: {ref, how}}
  end

  defp on_event({:exited, how}, state) do
    notify(state, {:exited, how})
    state
  end

  defp on_event(:released, state) do
    state = flush_exited(state)
    notify(state, :released)
    %{state | released: true}
  end

  defp on_event({:refused, reason}, state) do
    notify(state, {:refused, reason})
    state
  end

  defp on_event({:error, reason}, state) do
    notify(state, {:error, reason})
    state
  end

  # Each complete line is one frame from the runner. A line past the
  # protocol's bound before its newline is not a frame either.
  defp lines(state) do
    case :binary.split(state.buffer, "\n") do
      [line, rest] ->
        state = %{state | buffer: rest}

        case RunnerControl.decode(line) do
          {:ok, %{type: type} = message} ->
            if RunnerControl.sender(type) == :runner,
              do: heard(state, message),
              else: notify(state, {:error, {:protocol, {:not_a_runner_frame, type}}})

          {:error, reason} ->
            notify(state, {:error, {:protocol, reason}})
        end

        lines(state)

      [partial] when byte_size(partial) > @max_line_bytes ->
        notify(state, {:error, {:protocol, :oversize_line}})
        %{state | buffer: ""}

      [_partial] ->
        state
    end
  end

  # A clean completion puts the place back at rest, still the athanor's,
  # before the owner hears it, so the next work's assign follows it. One
  # the keeper does not apply is heard with the completion, in one event,
  # so the owner never offers the runner between the two.
  defp heard(%{athanor: athanor} = state, %{type: :complete, clean: true} = message)
       when athanor != nil do
    whose = %{kind: "warm", athanor: athanor}

    case state.keeper.assign(state.spec.runner, whose, now() + @assign_wait_ms, state.keeper_opts) do
      :ok -> notify(state, {:message, message})
      {:error, reason} -> notify(state, {:message, message, {:error, {:assign, reason}}})
    end
  end

  defp heard(state, message), do: notify(state, {:message, message})

  # Held until the runner attaches, or written once its relay is bound to
  # the attempt.
  defp assigned(%{relay: nil} = state, line, binding),
    do: {:reply, :ok, %{state | binding: binding, pending: [state.pending, line]}}

  defp assigned(state, line, binding) do
    case bind(state.relay, binding) do
      :ok -> {:reply, written(state.keeper.send(state.channel, line)), state}
      {:error, reason} -> {:reply, {:error, {:unsent, {:relay, reason}}}, state}
    end
  end

  # The relay's writes go through the keeper from the relay's own process,
  # on the handle the runner attached with. An assignment made before the
  # runner attached binds it now, before the held `assign` is written.
  defp start_relay(state) do
    {keeper, channel} = {state.keeper, state.channel}

    {:ok, relay} =
      Locus.Runtime.Relay.start_link(
        runner: state.id,
        write: fn data -> keeper.send_relay(channel, data) end,
        close: fn -> keeper.close_relay(channel) end
      )

    case state.binding && Locus.Runtime.Relay.bind(relay, state.binding) do
      {:error, reason} -> notify(state, {:error, {:relay, reason}})
      _bound -> :ok
    end

    %{state | relay: relay, binding: nil}
  end

  # The relay can end before its exit is read here.
  defp bind(relay, binding) do
    Locus.Runtime.Relay.bind(relay, binding)
  catch
    :exit, _reason -> {:error, :closed}
  end

  defp written({:error, reason}) when reason in @unwritten, do: {:error, {:unsent, reason}}
  defp written(answer), do: answer

  defp release_runner(%{channel: nil} = state, _grace_ms), do: state
  defp release_runner(%{released: true} = state, _grace_ms), do: state

  defp release_runner(state, grace_ms) do
    :ok = state.keeper.release(state.channel, grace_ms)
    %{state | released: true}
  end

  defp flush_exited(%{exited: {_ref, how}} = state) do
    notify(state, {:exited, how})
    %{state | exited: nil}
  end

  defp flush_exited(state), do: state

  defp notify(state, event), do: send(state.owner, {__MODULE__, self(), event})

  defp now, do: System.monotonic_time(:millisecond)
end
