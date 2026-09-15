# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.WorkerService do
  @moduledoc """
  The worker service: it starts a runner for each assignment CYFR
  dispatches, kills runners, and reports each runner that exits leaving
  its attempt open. It implements `Cyfr.WorkerAPI` and runs no guest code.

  Its boot id, minted when it starts, is the audience every assignment it
  accepts must name, and the runner id of every attempt dispatched to it.

  `start/3` reads the assignment (`Cyfr.Assignment.read/1`), refuses it as
  `:malformed` unless it names this boot, its input matches its
  `input_digest`, and the sealed key opens under the dispatch seal key as
  the attempt it names (`Cyfr.WorkerAuth.open_attempt_key/2`), and then
  starts an `Opus.Runner` under `Opus.WorkerService.Runners` with a host
  client of its own id, and monitors it.

  A runner tells the service its component process and what that process
  started (`track/1`). `kill/1` kills a runner's component process and the
  runner by name. When a runner exits, its component process (with the
  formula tracker linked to it) and its streaming requests are stopped; a
  runner that exits other than `:normal` left its attempt open, and a
  process of its own reports the exit to CYFR at once, signed with the
  dispatch key (`Opus.HostClient.runner_exited/3`).

  In this BEAM the dispatch and dispatch seal keys are CYFR's
  (`Cyfr.Execution.Keys`).
  """

  @behaviour Cyfr.WorkerAPI

  use GenServer

  require Logger

  alias Cyfr.{Assignment, WorkerAuth}
  alias Opus.{HostClient, Runner}

  @runners __MODULE__.Runners
  @attempt_fields [:athanor_id, :execution_id, :attempt, :fence, :generation]

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Cyfr.WorkerAPI
  def start(token, input, sealed_keys)
      when is_binary(token) and is_binary(input) and is_binary(sealed_keys) do
    caller = %{
      callers: [self() | Process.get(:"$callers", [])],
      logger: Cyfr.LoggerContext.capture()
    }

    GenServer.call(__MODULE__, {:start, token, input, sealed_keys, caller})
  end

  @impl Cyfr.WorkerAPI
  def kill(execution_id) when is_binary(execution_id),
    do: GenServer.call(__MODULE__, {:kill, execution_id})

  @impl Cyfr.WorkerAPI
  def status, do: GenServer.call(__MODULE__, :status)

  @doc """
  Record, for the calling runner, its component process (`:component`) or
  the cleanup references its runtime answered (`:cleanup`), which a kill or
  its exit stops.
  """
  @spec track(%{optional(:component) => pid(), optional(:cleanup) => map()}) :: :ok
  def track(fields) when is_map(fields), do: GenServer.cast(__MODULE__, {:track, self(), fields})

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    # Trapped, so a shutdown runs `terminate/2`, which stops the component
    # processes a runner's exit does not.
    Process.flag(:trap_exit, true)
    boot = "#{node()}#" <> Cyfr.UUID7.generate_id("worker")
    {:ok, %{boot: boot, runners: %{}, executions: %{}}}
  end

  @impl true
  def handle_call({:start, token, input, sealed_keys, caller}, _from, state) do
    with {:ok, assignment} <- Assignment.read(token),
         true <- assignment.audience == state.boot,
         true <- Cyfr.Digest.sha256(input) == assignment.input_digest,
         {:ok, %{attempt: attempt, key: key}} <-
           WorkerAuth.open_attempt_key(Cyfr.Execution.Keys.dispatch_seal_key(), sealed_keys),
         true <- attempt == Map.take(assignment, @attempt_fields),
         false <- Map.has_key?(state.executions, assignment.execution_id),
         {:ok, %{} = decoded} <- Jason.decode(input),
         {:ok, pid} <-
           DynamicSupervisor.start_child(
             @runners,
             {Runner,
              %{
                token: token,
                assignment: assignment,
                input: decoded,
                client: HostClient.new(attempt, key, Cyfr.UUID7.generate_id("runner")),
                callers: caller.callers,
                logger: caller.logger
              }}
           ) do
      ref = Process.monitor(pid)

      runner = %{
        pid: pid,
        execution_id: assignment.execution_id,
        attempt: assignment.attempt,
        callers: caller.callers,
        logger: caller.logger,
        component: nil,
        cleanup: %{}
      }

      {:reply, :ok,
       %{
         state
         | runners: Map.put(state.runners, ref, runner),
           executions: Map.put(state.executions, assignment.execution_id, ref)
       }}
    else
      _refused -> {:reply, {:error, :malformed}, state}
    end
  end

  def handle_call({:kill, execution_id}, _from, state) do
    case Map.fetch(state.executions, execution_id) do
      {:ok, ref} ->
        runner = Map.fetch!(state.runners, ref)
        kill_component(runner)
        Process.exit(runner.pid, :kill)
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:status, _from, state) do
    attempts = for {_ref, runner} <- state.runners, do: runner.attempt

    {:reply,
     {:ok,
      %{
        boot: state.boot,
        runners: %{fresh: 0, idle: 0, busy: map_size(state.runners)},
        attempts: attempts
      }}, state}
  end

  @impl true
  def handle_cast({:track, pid, fields}, state) do
    case Enum.find(state.runners, fn {_ref, runner} -> runner.pid == pid end) do
      {ref, runner} ->
        runner = %{
          runner
          | component: Map.get(fields, :component, runner.component),
            cleanup: Map.get(fields, :cleanup, runner.cleanup)
        }

        {:noreply, %{state | runners: Map.put(state.runners, ref, runner)}}

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.runners, ref) do
      {nil, _runners} ->
        {:noreply, state}

      {runner, runners} ->
        kill_component(runner)
        if reason != :normal, do: report(state.boot, runner)

        {:noreply,
         %{
           state
           | runners: runners,
             executions: Map.delete(state.executions, runner.execution_id)
         }}
    end
  end

  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    for {_ref, runner} <- state.runners do
      kill_component(runner)
      Process.exit(runner.pid, :kill)
    end

    :ok
  end

  # The component process traps exits, so it is killed by name. Its formula
  # tracker is linked to it and goes with it, taking the spawned tasks; its
  # streaming requests run under a supervisor of their own and are stopped
  # here.
  defp kill_component(runner) do
    if is_pid(runner.component), do: Process.exit(runner.component, :kill)

    if runner.cleanup[:stream_exec_ref],
      do: Opus.HttpStreamHandler.cleanup_registry(runner.cleanup.stream_exec_ref)

    :ok
  end

  defp report(boot, runner) do
    spawn(fn ->
      Process.put(:"$callers", runner.callers)
      Cyfr.LoggerContext.restore(runner.logger)

      case HostClient.runner_exited(Cyfr.Execution.Keys.dispatch_key(), boot, [runner.attempt]) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "[Opus.WorkerService] the exit of #{runner.execution_id}'s runner was not " <>
              "reported: #{inspect(reason)}"
          )
      end
    end)

    :ok
  end
end
