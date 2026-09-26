# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.RunnerProcess do
  @moduledoc """
  The service's handle on one runner: the OS process the keeper started
  for it (`Opus.Keeper`), the control channel to it and the
  `Prima.RunnerControl` lines on that channel.

  Started by `Opus.RunnerPool` with the keeper, the runner's id and what
  to start it with, it spawns the runner from its own process, so the
  keeper's messages reach it, and tells its owner what happens as
  `{Opus.RunnerProcess, pid, event}`: `:ready` once the channel is
  attached, `{:message, message}` for each frame the runner sends
  (`complete` or `exit`; a frame the runner may not send, or a line that
  is not one, is `{:error, {:protocol, reason}}`), `:closed` once the
  runner's end of the channel is closed, `{:exited, how}` once its
  process ended, `:released` once the keeper has retired it,
  `{:refused, reason}` when the keeper refused the spawn, so no process of
  the runner ever ran and nothing is left to release, and
  `{:error, reason}` for a later failure of the keeper's. A message the service
  sends (`send_message/2`) is written at once, or held until the channel
  attaches. `release/2` asks the keeper to end the runner; when this
  process itself is stopped, the runner is released with no grace.

  When the runner attaches, this process starts the service's end of its
  relay (`Opus.Relay`), linked, and hands it every relay byte the keeper
  carries; the relay writes back through the keeper itself. `assign/5`
  binds the relay to the attempt it assigns, from the assignment and the
  opened keys, before the `assign` is written (or, before the runner
  attaches, once the relay starts), so the runner's first host call finds
  it bound. A relay that stops because it closed the channel, or failed,
  is `{:error, {:relay, reason}}`: the pool retires the runner, as for any
  failure. One whose runner's end of the stream ended is heard as the
  runner's own end.

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

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc "Start a handle. Options: `:id`, `:keeper`, `:spec` (`t:Opus.Keeper.spec/0`), `:owner`."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Send `message`, a `cancel_child`, to the runner; an `assign` is `assign/5`'s."
  @spec send_message(pid(), RunnerControl.message()) :: :ok | {:error, term()}
  def send_message(pid, %{type: :cancel_child} = message) do
    line = message |> RunnerControl.encode() |> IO.iodata_to_binary()
    GenServer.call(pid, {:send, line})
  end

  @doc """
  Assign the runner the attempt `token` names: bind its relay to the
  attempt (`Opus.Relay.bind/2`, `host_url` being where its calls go when
  the assignment names no address), then send the `assign` with `input`
  and the opened `keys`. Raises for an `assign` the protocol refuses.
  """
  @spec assign(pid(), String.t(), String.t(), Prima.WorkerAuth.attempt_keys(), String.t()) ::
          :ok | {:error, term()}
  def assign(pid, token, input, keys, host_url)
      when is_binary(token) and is_binary(input) and is_binary(host_url) do
    line =
      %{type: :assign, assignment: token, input: input, keys: keys}
      |> RunnerControl.encode()
      |> IO.iodata_to_binary()

    GenServer.call(pid, {:assign, line, %{assignment: token, keys: keys, host_url: host_url}})
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
       spec: Keyword.fetch!(opts, :spec),
       owner: Keyword.fetch!(opts, :owner),
       channel: nil,
       relay: nil,
       binding: nil,
       os_pid: nil,
       attached: false,
       pending: [],
       buffer: "",
       closed: false,
       released: false
     }, {:continue, :spawn}}
  end

  @impl true
  def handle_continue(:spawn, state) do
    case state.keeper.spawn(state.spec) do
      {:ok, channel, events} ->
        {:noreply, Enum.reduce(events, %{state | channel: channel}, &on_event/2)}

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

  def handle_call({:assign, line, binding}, _from, %{relay: nil, attached: false} = state),
    do: {:reply, :ok, %{state | binding: binding, pending: [state.pending, line]}}

  def handle_call({:assign, _line, _binding}, _from, %{relay: nil} = state),
    do: {:reply, {:error, {:relay, :closed}}, state}

  def handle_call({:assign, line, binding}, _from, state) do
    case Opus.Relay.bind(state.relay, binding) do
      :ok -> {:reply, state.keeper.send(state.channel, line), state}
      {:error, reason} -> {:reply, {:error, {:relay, reason}}, state}
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

      {:message, {:assign, line, _binding}} ->
        {:message, {:assign, {:redacted, byte_size(line)}, :redacted}}

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
    Opus.Relay.deliver(relay, data)
    state
  end

  defp on_event({:relay, _data}, state), do: state

  defp on_event(:relay_closed, %{relay: relay} = state) when relay != nil do
    Opus.Relay.ended(relay)
    state
  end

  defp on_event(:relay_closed, state), do: state

  defp on_event({:log, data}, state) do
    Logger.info("[Opus.RunnerProcess] runner #{state.id}: #{String.trim_trailing(data)}")
    state
  end

  defp on_event(:control_closed, %{closed: false} = state) do
    notify(state, :closed)
    %{state | closed: true}
  end

  defp on_event(:control_closed, state), do: state

  defp on_event({:exited, how}, state) do
    notify(state, {:exited, how})
    state
  end

  defp on_event(:released, state) do
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
              do: notify(state, {:message, message}),
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

  # The relay's writes go through the keeper from the relay's own process,
  # on the handle the runner attached with. An assignment made before the
  # runner attached binds it now, before the held `assign` is written.
  defp start_relay(state) do
    {keeper, channel} = {state.keeper, state.channel}

    {:ok, relay} =
      Opus.Relay.start_link(
        runner: state.id,
        write: fn data -> keeper.send_relay(channel, data) end,
        close: fn -> keeper.close_relay(channel) end
      )

    case state.binding && Opus.Relay.bind(relay, state.binding) do
      {:error, reason} -> notify(state, {:error, {:relay, reason}})
      _bound -> :ok
    end

    %{state | relay: relay, binding: nil}
  end

  defp release_runner(%{channel: nil} = state, _grace_ms), do: state
  defp release_runner(%{released: true} = state, _grace_ms), do: state

  defp release_runner(state, grace_ms) do
    :ok = state.keeper.release(state.channel, grace_ms)
    %{state | released: true}
  end

  defp notify(state, event), do: send(state.owner, {__MODULE__, self(), event})
end
