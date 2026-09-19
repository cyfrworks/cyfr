# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Runner do
  @moduledoc """
  The runner: the process of the runner role that takes one subtree at a
  time from its worker service over the control channel
  (`Cyfr.RunnerControl`) and runs it in this VM.

  An `assign` carries the signed assignment, the input its digest binds
  and the attempt's opened keys. The runner reads the assignment, starts
  the root's attempt process (`Opus.Attempt`) with a host client of its
  own runner id, presenting the boot its settings name, and tracks the
  subtree that grows from it (`Opus.Subtree`): each child a formula's
  guest starts runs in an attempt process of this VM, and the runner tells
  its service it holds it (`child`), so a kill of that child reaches this
  runner. The attempt
  processes renew their leases and enforce the guest's timeout, bounded
  by the subtree's deadline, as always; the runner adds the watchdog: at
  the assignment's `deadline` plus the configured grace, a subtree still
  running has a guest that ignored its bound, and the VM halts
  (`Opus.Release.halt/1`) so no native thread outlives it, with an `exit`
  written first naming every attempt still open.

  When every attempt process has ended, the subtree is complete. If each
  closed its attempt with CYFR and no component call was killed, no host
  answer lost and no child cancelled, the runner clears what the job
  left (open streams, tasks) and sends `complete` with `clean: true`,
  ready for another assignment for the same athanor. A killed component
  call, a lost answer or a cancelled child makes it `clean: false`: the
  service ends this runner. An attempt process that ends leaving its
  attempt open ends the subtree: the rest is killed, and the runner
  sends `exit` naming every attempt left open, then stops the VM
  (`Opus.Release.stop/1`). A `cancel_child` kills the named child's
  process and marks the runner unclean; one naming no child here is
  ignored. When the channel closes with nothing assigned, the runner
  stops; with a subtree running, it finishes it, then stops.
  """

  use GenServer

  require Logger

  alias Cyfr.{Assignment, RunnerControl}
  alias Opus.{HostClient, Subtree}

  # A line past the protocol's bound before its newline is not a frame.
  @max_line_bytes RunnerControl.max_line_bytes()

  @attempts __MODULE__.Attempts

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc """
  Start the runner. Options: `:settings` (`t:Opus.Settings.runner/0`),
  `:port` (the control port; default `Opus.Release.open_control/1` on the
  settings' descriptor), `:supervisor` (the attempt processes' supervisor,
  default `#{inspect(@attempts)}`), `:halt` and `:stop` (what ends the VM;
  default `Opus.Release`'s), `:name` (default `#{inspect(__MODULE__)}`).
  """
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "The supervisor the runner's attempt processes run under."
  @spec attempts_supervisor() :: atom()
  def attempts_supervisor, do: @attempts

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    settings = Keyword.fetch!(opts, :settings)
    port = Keyword.get_lazy(opts, :port, fn -> Opus.Release.open_control(settings.control_fd) end)

    {:ok,
     Subtree.new(%{
       cancel: :abandon,
       settings: settings,
       port: port,
       buffer: "",
       assignment: nil,
       cancelled: MapSet.new(),
       clean: true,
       open: [],
       closed: false,
       watchdog: nil,
       supervisor: Keyword.get(opts, :supervisor, @attempts),
       halt: Keyword.get(opts, :halt, &Opus.Release.halt/1),
       stop: Keyword.get(opts, :stop, &Opus.Release.stop/1)
     })}
  end

  # ---------------------------------------------------------------------------
  # The channel
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state),
    do: {:noreply, lines(%{state | buffer: state.buffer <> data})}

  def handle_info({port, :eof}, %{port: port} = state), do: {:noreply, channel_closed(state)}

  def handle_info({:EXIT, port, _reason}, %{port: port} = state),
    do: {:noreply, channel_closed(state)}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Subtree.down(state, ref) do
      {:attempt, entry, state} -> {:noreply, attempt_ended(state, entry, reason)}
      {:waiter, state} -> {:noreply, state}
      {:unknown, state} -> {:noreply, state}
    end
  end

  def handle_info({:watchdog, execution_id}, %{assignment: %{execution_id: execution_id}} = state) do
    open = Enum.uniq(state.open ++ Subtree.attempts(state))
    write(state, %{type: :exit, runner: state.settings.runner_id, open: open})
    state.halt.({:watchdog, execution_id})
    {:noreply, state}
  end

  def handle_info({:watchdog, _execution_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # What the subtree's processes ask
  # ---------------------------------------------------------------------------

  @impl true
  def handle_call({:start_child, child, waiter, caller}, _from, state) do
    %{assignment: assignment, client: client} = child
    settings = state.settings

    if state.assignment != nil and client.service == settings.service_id and
         client.boot == settings.boot and assignment.service == settings.service_id and
         assignment.boot == settings.boot and client.execution_id == assignment.execution_id and
         client.attempt == assignment.attempt do
      start = %{
        token: child.token,
        assignment: assignment,
        input: child.input,
        client: client,
        secrets: child.secrets,
        waiter: waiter
      }

      case Subtree.start(state, state.supervisor, start, caller, waiter) do
        {:ok, pid, state} ->
          write(state, %{
            type: :child,
            execution_id: assignment.execution_id,
            attempt: assignment.attempt
          })

          {:reply, {:ok, pid}, state}

        {:error, :malformed} ->
          {:reply, {:error, :malformed}, state}
      end
    else
      {:reply, {:error, :malformed}, state}
    end
  end

  def handle_call({:settled, pid}, _from, state), do: {:reply, :ok, Subtree.settle(state, pid)}

  @impl true
  def handle_cast({:track, pid, fields}, state), do: {:noreply, Subtree.track(state, pid, fields)}

  def handle_cast({:unclean, _pid, reason}, state) do
    Logger.warning("[Opus.Runner] unclean: #{inspect(reason)}")
    {:noreply, %{state | clean: false}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.assignment do
      open = Enum.uniq(state.open ++ Subtree.attempts(state))
      write(state, %{type: :exit, runner: state.settings.runner_id, open: open})
      Subtree.kill_all(state)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Frames
  # ---------------------------------------------------------------------------

  defp lines(state) do
    case :binary.split(state.buffer, "\n") do
      [line, rest] ->
        state = %{state | buffer: rest}

        state =
          case RunnerControl.decode(line) do
            {:ok, %{type: :assign} = message} ->
              on_assign(state, message)

            {:ok, %{type: :cancel_child, execution_id: execution_id}} ->
              on_cancel_child(state, execution_id)

            {:ok, %{type: type}} ->
              Logger.error("[Opus.Runner] the service sent a #{type} frame; ignored")
              state

            {:error, reason} ->
              Logger.error(
                "[Opus.Runner] the service sent a line that is not a frame: #{inspect(reason)}"
              )

              state
          end

        lines(state)

      [partial] when byte_size(partial) > @max_line_bytes ->
        Logger.error("[Opus.Runner] the service sent a line past the protocol's bound; halting")
        state.halt.(:oversize_line)
        %{state | buffer: ""}

      [_partial] ->
        state
    end
  end

  defp on_assign(%{assignment: current} = state, _message) when current != nil do
    Logger.error("[Opus.Runner] assigned while running #{current.execution_id}; ignored")
    state
  end

  defp on_assign(state, %{assignment: token, input: input, keys: keys}) do
    settings = state.settings

    with {:ok, assignment} <- Assignment.read(token),
         true <- assignment.service == settings.service_id and assignment.boot == settings.boot,
         {:ok, %{} = decoded} <- Jason.decode(input) do
      client = HostClient.new(keys, settings.runner_id, settings.boot, settings.host_url)
      start = %{token: token, assignment: assignment, input: decoded, client: client}
      caller = %{callers: [self()], logger: Cyfr.LoggerContext.capture()}

      case Subtree.start(state, state.supervisor, start, caller, nil) do
        {:ok, _pid, state} ->
          watchdog =
            Process.send_after(
              self(),
              {:watchdog, assignment.execution_id},
              max(
                assignment.deadline + settings.watchdog_grace_ms -
                  System.system_time(:millisecond),
                0
              )
            )

          %{
            state
            | assignment: %{
                execution_id: assignment.execution_id,
                athanor_id: assignment.athanor_id
              },
              watchdog: watchdog,
              clean: true,
              open: []
          }

        {:error, :malformed} ->
          Logger.error(
            "[Opus.Runner] the assignment names an execution this runner already ran; halting"
          )

          state.halt.(:malformed_assign)
          state
      end
    else
      _refused ->
        # The service verified this assignment; one that does not read
        # here is not the service's. The runner ends, and the service
        # reports what it assigned.
        Logger.error("[Opus.Runner] the assignment cannot be read; halting")
        state.halt.(:malformed_assign)
        state
    end
  end

  defp on_cancel_child(state, execution_id) do
    case state.assignment do
      %{execution_id: ^execution_id} ->
        Logger.error(
          "[Opus.Runner] cancel_child names the subtree's root #{execution_id}; ignored"
        )

        state

      _ ->
        case Subtree.kill(state, execution_id) do
          :ok -> %{state | clean: false, cancelled: MapSet.put(state.cancelled, execution_id)}
          :not_found -> state
        end
    end
  end

  # ---------------------------------------------------------------------------
  # The subtree's end
  # ---------------------------------------------------------------------------

  # An attempt process that ended other than `:normal` left its attempt
  # open: the subtree cannot be completed, so the rest is killed and the
  # runner ends once every process is gone. A cancelled child's is CYFR's
  # already, however its process ended: the cancel is the fence.
  defp attempt_ended(state, _entry, :normal), do: maybe_finish(state)

  defp attempt_ended(state, entry, _reason) do
    if MapSet.member?(state.cancelled, entry.execution_id) do
      maybe_finish(state)
    else
      state = %{state | open: [entry.attempt | state.open], clean: false}
      Subtree.kill_all(state)
      maybe_finish(state)
    end
  end

  defp maybe_finish(%{assignment: nil} = state), do: state

  defp maybe_finish(%{runners: runners} = state) when map_size(runners) > 0, do: state

  defp maybe_finish(%{open: [_ | _]} = state) do
    write(state, %{type: :exit, runner: state.settings.runner_id, open: Enum.uniq(state.open)})
    state.stop.(1)
    %{state | assignment: nil}
  end

  defp maybe_finish(state) do
    if state.watchdog, do: Process.cancel_timer(state.watchdog)
    clear_job_state()

    write(state, %{
      type: :complete,
      execution_id: state.assignment.execution_id,
      clean: state.clean
    })

    state = %{
      state
      | assignment: nil,
        watchdog: nil,
        clean: true,
        open: [],
        cancelled: MapSet.new()
    }

    if state.closed, do: state.stop.(0)
    state
  end

  # What a job leaves behind in this VM, so the next job of the same
  # athanor starts from nothing: every open stream and every task.
  defp clear_job_state do
    for {key, _value} <- Opus.Cache.match({:http_stream, :_, :_}), do: Opus.Cache.invalidate(key)

    if Process.whereis(Opus.TaskSupervisor) do
      for pid <- Task.Supervisor.children(Opus.TaskSupervisor),
          do: Task.Supervisor.terminate_child(Opus.TaskSupervisor, pid)
    end

    :ok
  end

  defp channel_closed(%{closed: true} = state), do: state

  defp channel_closed(state) do
    state = %{state | closed: true}
    if state.assignment == nil, do: state.stop.(0)
    state
  end

  defp write(%{port: port}, message) do
    Port.command(port, RunnerControl.encode(message))
    :ok
  rescue
    ArgumentError -> :ok
  end
end
