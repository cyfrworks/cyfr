# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.WorkerService do
  @moduledoc """
  The worker service: it starts a runner for each assignment CYFR
  dispatches and for each child a formula's runner is admitted, kills
  runners, and reports each runner that exits leaving its attempt open. It
  implements `Cyfr.WorkerAPI` and runs no guest code.

  Its service id, its worker key and where CYFR is are its credentials
  (`Opus.Credentials`, from `config :opus`), loaded when it starts; a
  missing or malformed one refuses the boot. Its boot id, minted when it
  starts, is carried on every header beside its service id. Every
  assignment it accepts must name both: one addressed to another boot of
  this service was dispatched to an incarnation that no longer runs, and
  is refused. A restarted service holds none of its predecessor's
  attempts: their runners are gone with it, and CYFR lapses them through
  the lease.

  CYFR reaches `start/3`, `kill/1` and `status/0` through
  `Opus.WorkerListener`. `start/3` reads the assignment
  (`Cyfr.Assignment.read/1`), refuses it as `:malformed` unless it names
  this service and boot, its input matches its `input_digest`, and the
  sealed keys open under this worker service's dispatch seal key as the
  attempt it names, on this worker service
  (`Cyfr.WorkerAuth.open_attempt_keys/2`), and then starts an
  `Opus.Runner` under `Opus.WorkerService.Runners` with a host client of
  its own runner id, presenting this boot to the host API its credentials
  name, and monitors it.

  `start_child/2` starts a runner, the same way, for a child CYFR admitted
  and claimed for a formula's runner (`Opus.HostClient.admit_child/5`): it
  runs in that runner's group, presenting as the same runner. A child with
  a waiting process (a formula's synchronous call or spawned task) is
  killed when that process exits before its runner settles
  (`settled/0`); a streamed child, with none, runs until it closes.

  A runner tells the service its component process and what that process
  started (`track/1`). `kill/1` kills a runner's component process and the
  runner by name, a child's as a root's. When a runner exits, its
  component process (with the formula tracker linked to it) and its
  streaming requests are stopped; a runner that exits other than `:normal`
  left its attempt open, and a process of its own reports the exit to CYFR
  at once, naming the runner and signed with its dispatch key
  (`Opus.HostClient.runner_exited/4`).
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
    GenServer.call(__MODULE__, {:start, token, input, sealed_keys, caller()})
  end

  @impl Cyfr.WorkerAPI
  def kill(execution_id) when is_binary(execution_id),
    do: GenServer.call(__MODULE__, {:kill, execution_id})

  @impl Cyfr.WorkerAPI
  def status, do: GenServer.call(__MODULE__, :status)

  @doc """
  Start a runner for `child`, a child CYFR admitted and claimed for a
  formula's runner (`t:Opus.HostClient.child/0`). `waiter` is the process
  the runner answers (`Opus.Runner`), whose exit kills the runner until it
  settles, or nil for a child nothing waits for. Answers
  `{:ok, runner_pid}`, or `{:error, :malformed}` when the child's client is
  not for the attempt its assignment names on this worker service, or
  names an execution this service already runs.
  """
  @spec start_child(HostClient.child(), pid() | nil) :: {:ok, pid()} | {:error, :malformed}
  def start_child(%{assignment: %Assignment{}, client: %HostClient{}} = child, waiter)
      when is_pid(waiter) or is_nil(waiter),
      do: GenServer.call(__MODULE__, {:start_child, child, waiter, caller()})

  @doc """
  Record, for the calling runner, its component process (`:component`) or
  the cleanup references its runtime answered (`:cleanup`), which a kill or
  its exit stops.
  """
  @spec track(%{optional(:component) => pid(), optional(:cleanup) => map()}) :: :ok
  def track(fields) when is_map(fields), do: GenServer.cast(__MODULE__, {:track, self(), fields})

  @doc """
  Record, for the calling runner, that CYFR has closed its attempt: its
  waiter's exit no longer kills it.
  """
  @spec settled() :: :ok
  def settled, do: GenServer.call(__MODULE__, {:settled, self()})

  defp caller do
    %{callers: [self() | Process.get(:"$callers", [])], logger: Cyfr.LoggerContext.capture()}
  end

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    # Trapped, so a shutdown runs `terminate/2`, which stops the component
    # processes a runner's exit does not.
    Process.flag(:trap_exit, true)
    credentials = Opus.Credentials.load!()
    :ok = Opus.Credentials.install(credentials)

    boot = "#{node()}#" <> Cyfr.UUID7.generate_id("boot")

    {:ok,
     %{
       credentials: credentials,
       service: credentials.service_id,
       boot: boot,
       runners: %{},
       executions: %{},
       waiters: %{}
     }}
  end

  @impl true
  def handle_call({:start, token, input, sealed_keys, caller}, _from, state) do
    with {:ok, assignment} <- Assignment.read(token),
         true <- assignment.service == state.service and assignment.boot == state.boot,
         true <- Cyfr.Digest.sha256(input) == assignment.input_digest,
         {:ok, %{attempt: attempt} = keys} <-
           WorkerAuth.open_attempt_keys(state.credentials.dispatch_seal_key, sealed_keys),
         true <-
           attempt ==
             assignment |> Map.take(@attempt_fields) |> Map.put(:service, state.service),
         {:ok, %{} = decoded} <- Jason.decode(input) do
      start = %{
        token: token,
        assignment: assignment,
        input: decoded,
        client:
          HostClient.new(
            keys,
            Cyfr.UUID7.generate_id("runner"),
            state.boot,
            state.credentials.host_url
          )
      }

      case start_runner(start, caller, nil, state) do
        {:reply, {:ok, _pid}, state} -> {:reply, :ok, state}
        refused -> refused
      end
    else
      _refused -> {:reply, {:error, :malformed}, state}
    end
  end

  def handle_call({:start_child, child, waiter, caller}, _from, state) do
    %{assignment: assignment, client: client} = child

    if client.service == state.service and client.boot == state.boot and
         assignment.service == state.service and assignment.boot == state.boot and
         client.execution_id == assignment.execution_id and client.attempt == assignment.attempt do
      start = %{
        token: child.token,
        assignment: assignment,
        input: child.input,
        client: client,
        secrets: child.secrets,
        waiter: waiter
      }

      start_runner(start, caller, waiter, state)
    else
      {:reply, {:error, :malformed}, state}
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

  def handle_call({:settled, pid}, _from, state) do
    case find_runner(state, pid) do
      {ref, runner} ->
        state = forget_waiter_of(state, runner)
        {:reply, :ok, %{state | runners: Map.put(state.runners, ref, %{runner | waiter: nil})}}

      nil ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:status, _from, state) do
    attempts = for {_ref, runner} <- state.runners, do: runner.attempt

    {:reply,
     {:ok,
      %{
        service: state.service,
        boot: state.boot,
        runners: %{fresh: 0, idle: 0, busy: map_size(state.runners)},
        attempts: attempts
      }}, state}
  end

  @impl true
  def handle_cast({:track, pid, fields}, state) do
    case find_runner(state, pid) do
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
        {:noreply, waiter_down(ref, state)}

      {runner, runners} ->
        kill_component(runner)
        if reason != :normal, do: report(state, runner)

        state = %{
          state
          | runners: runners,
            executions: Map.delete(state.executions, runner.execution_id)
        }

        {:noreply, forget_waiter_of(state, runner)}
    end
  end

  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  # The credentials hold this service's keys, which no status or crash
  # report shows.
  @impl true
  def format_status(status), do: Map.update(status, :state, nil, &Map.delete(&1, :credentials))

  @impl true
  def terminate(_reason, state) do
    for {_ref, runner} <- state.runners do
      kill_component(runner)
      Process.exit(runner.pid, :kill)
    end

    :ok
  end

  defp start_runner(start, caller, waiter, state) do
    execution_id = start.assignment.execution_id

    with false <- Map.has_key?(state.executions, execution_id),
         {:ok, pid} <-
           DynamicSupervisor.start_child(
             @runners,
             {Runner, Map.merge(start, %{callers: caller.callers, logger: caller.logger})}
           ) do
      ref = Process.monitor(pid)
      waiter_ref = if is_pid(waiter), do: Process.monitor(waiter)

      runner = %{
        pid: pid,
        execution_id: execution_id,
        attempt: start.assignment.attempt,
        runner: start.client.runner,
        callers: caller.callers,
        logger: caller.logger,
        waiter: waiter_ref,
        component: nil,
        cleanup: %{}
      }

      waiters = if waiter_ref, do: Map.put(state.waiters, waiter_ref, ref), else: state.waiters

      {:reply, {:ok, pid},
       %{
         state
         | runners: Map.put(state.runners, ref, runner),
           executions: Map.put(state.executions, execution_id, ref),
           waiters: waiters
       }}
    else
      _refused -> {:reply, {:error, :malformed}, state}
    end
  end

  defp find_runner(state, pid), do: Enum.find(state.runners, fn {_ref, r} -> r.pid == pid end)

  # A waiting process that exits before its child's runner settles kills
  # the runner, whose exit is then reported.
  defp waiter_down(waiter_ref, state) do
    case Map.pop(state.waiters, waiter_ref) do
      {nil, _waiters} ->
        state

      {ref, waiters} ->
        case Map.fetch(state.runners, ref) do
          {:ok, runner} ->
            kill_component(runner)
            Process.exit(runner.pid, :kill)

          :error ->
            :ok
        end

        %{state | waiters: waiters}
    end
  end

  defp forget_waiter_of(state, %{waiter: nil}), do: state

  defp forget_waiter_of(state, %{waiter: waiter_ref}) do
    Process.demonitor(waiter_ref, [:flush])
    %{state | waiters: Map.delete(state.waiters, waiter_ref)}
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

  defp report(%{credentials: credentials, boot: boot}, runner) do
    spawn(fn ->
      Process.put(:"$callers", runner.callers)
      Cyfr.LoggerContext.restore(runner.logger)

      case HostClient.runner_exited(credentials, boot, runner.runner, [runner.attempt]) do
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
