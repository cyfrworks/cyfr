# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.WorkerService do
  @moduledoc """
  The worker service: it takes each assignment CYFR dispatches, hands it
  to a runner, kills runners, and reports each runner that exits leaving
  attempts open. It implements `Cyfr.WorkerAPI` and runs no guest code.

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
  this service and boot, its input matches its `input_digest` and is a
  JSON object, and the sealed keys open under this worker service's
  dispatch seal key as the attempt it names, on this worker service
  (`Cyfr.WorkerAuth.open_attempt_keys/2`). The dispatch seal key never
  leaves this process: the runner is handed the opened keys.

  ## Runners

  A runner is an OS process of the pool (`Opus.RunnerPool`) the service
  never shares a VM with, and the service loads no component. `start/3`
  takes a runner of the assignment's athanor from the pool and sends it
  the `assign` over `Cyfr.RunnerControl`; the runner attaches, runs the
  subtree with its formula children and reports `complete`, clean or
  not, or `exit` with the attempts still open. A runner that reports
  `exit`, or whose channel closes or process ends with the subtree still
  assigned, is reported to CYFR at once, naming the runner and signed
  with the service's dispatch key (`Opus.HostClient.runner_exited/4`); a
  runner is reported once. A report runs beside the service, which never
  waits on CYFR, and `await_reports/1` answers once none is in flight. A
  `start` no runner can be found for answers `{:error, :unavailable}`,
  and while the keeper refuses runners `{:error, {:unavailable, sentence}}`
  with the keeper's account of why; the listener refuses either `503`,
  naming the sentence, so CYFR reconciles against the claim. Its status
  counts the pool's runners and carries the bound its keeper holds each
  to and the keeper's refusal (`Opus.RunnerPool.status/1`).

  A runner tells the service each child it starts (`child`), so the
  service knows which runner holds which child. `kill/1` for the root of
  a runner's subtree taints the runner and ends it through the keeper,
  with the grace to report its open attempts; for a child a runner said
  it holds, that runner is sent a `cancel_child`, kills the child and
  completes unclean. Either kill is `:ok`, and `:ok` again for an
  execution a runner of this boot already ended; the ids of the last ten
  thousand roots and children ended are remembered for it. A kill of an
  execution no runner of this boot holds or held is `:not_found`, however
  busy the runners are, so CYFR counts no kill that reached nothing; it
  is still offered to every busy runner, in case one started it too
  recently for its word to have arrived. A runner that ends without an
  `exit` is reported holding its subtree's root and every child it said
  it started.
  """

  @behaviour Cyfr.WorkerAPI

  use GenServer

  require Logger

  alias Cyfr.{Assignment, WorkerAuth}
  alias Opus.{HostClient, RunnerPool, RunnerProcess, Subtree}

  @attempt_fields [:athanor_id, :execution_id, :attempt, :fence, :generation]
  @remembered 10_000

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Cyfr.WorkerAPI
  def start(token, input, sealed_keys)
      when is_binary(token) and is_binary(input) and is_binary(sealed_keys) do
    GenServer.call(__MODULE__, {:start, token, input, sealed_keys, Subtree.caller()})
  end

  @impl Cyfr.WorkerAPI
  def kill(execution_id) when is_binary(execution_id),
    do: GenServer.call(__MODULE__, {:kill, execution_id})

  @impl Cyfr.WorkerAPI
  def status, do: GenServer.call(__MODULE__, :status)

  @doc """
  Answer once every runner exit this service is reporting has been
  answered by CYFR or given up on (`Opus.HostClient.runner_exited/4`
  bounds each); at once when none is in flight. For a caller that must
  know no report of the runners it ended still lands after it moved on,
  as a test's end does. Exits if that takes longer than `timeout_ms`.
  """
  @spec await_reports(timeout()) :: :ok
  def await_reports(timeout_ms \\ 70_000),
    do: GenServer.call(__MODULE__, :await_reports, timeout_ms)

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    credentials = Opus.Credentials.load!()
    :ok = Opus.Credentials.install(credentials)
    settings = Opus.Settings.pool!()
    boot = "#{node()}#" <> Cyfr.UUID7.generate_id("boot")

    :ok =
      RunnerPool.serve(
        RunnerPool,
        %{service_id: credentials.service_id, boot: boot, host_url: credentials.host_url},
        self()
      )

    {:ok,
     %{
       credentials: credentials,
       service: credentials.service_id,
       boot: boot,
       settings: settings,
       assigned: %{},
       executions: %{},
       ended: %{ids: MapSet.new(), order: :queue.new()},
       reports: %{},
       report_waiters: []
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
         {:ok, %{} = _decoded} <- Jason.decode(input) do
      start_pooled(state, token, assignment, input, keys, caller)
    else
      _refused -> {:reply, {:error, :malformed}, state}
    end
  end

  def handle_call({:kill, execution_id}, _from, state) do
    cond do
      pid = Map.get(state.executions, execution_id) ->
        :ok = RunnerPool.taint(RunnerPool, pid, state.settings.release_grace_ms)
        {:reply, :ok, state}

      pid = holder(state, execution_id) ->
        :ok = RunnerPool.cancel_child(RunnerPool, pid, execution_id)
        {:reply, :ok, state}

      ended?(state, execution_id) ->
        {:reply, :ok, state}

      true ->
        # A child a runner started so recently that its word has not
        # arrived is still reached; the kill found no runner holding it.
        if map_size(state.assigned) > 0,
          do: :ok = RunnerPool.cancel_child(RunnerPool, execution_id)

        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:await_reports, from, state),
    do: {:noreply, reported(%{state | report_waiters: [from | state.report_waiters]})}

  def handle_call(:status, _from, state) do
    status =
      Map.merge(RunnerPool.status(RunnerPool), %{
        service: state.service,
        boot: state.boot,
        attempts: held(state)
      })

    {:reply, {:ok, status}, state}
  end

  # A report in flight has been answered, or given up on.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state)
      when is_map_key(state.reports, ref) do
    {:noreply, reported(%{state | reports: Map.delete(state.reports, ref)})}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state),
    do: {:noreply, gone(state, pid, {:handle_down, reason})}

  def handle_info({RunnerPool, pid, {:complete, execution_id, _clean}}, state) do
    case Map.get(state.assigned, pid) do
      %{execution_id: ^execution_id} -> {:noreply, forget(state, pid)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({RunnerPool, pid, {:exit, runner, open}}, state) do
    case Map.get(state.assigned, pid) do
      nil ->
        {:noreply, state}

      assignment ->
        state = report(state, runner, Enum.uniq([assignment.attempt | open]), assignment)
        {:noreply, forget(state, pid)}
    end
  end

  def handle_info({RunnerPool, pid, {:child, execution_id, attempt}}, state) do
    case Map.get(state.assigned, pid) do
      nil ->
        {:noreply, state}

      assignment ->
        children = Map.put(assignment.children, execution_id, attempt)

        {:noreply,
         %{state | assigned: Map.put(state.assigned, pid, %{assignment | children: children})}}
    end
  end

  def handle_info({RunnerPool, pid, {:gone, reason}}, state),
    do: {:noreply, gone(state, pid, reason)}

  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  # The credentials hold this service's keys, which no status or crash
  # report shows.
  @impl true
  def format_status(status), do: Map.update(status, :state, nil, &Map.delete(&1, :credentials))

  # ---------------------------------------------------------------------------
  # Starting
  # ---------------------------------------------------------------------------

  defp start_pooled(state, token, assignment, input, keys, caller) do
    execution_id = assignment.execution_id

    if Map.has_key?(state.executions, execution_id) do
      {:reply, {:error, :malformed}, state}
    else
      case RunnerPool.take(RunnerPool, assignment.athanor_id, execution_id) do
        {:ok, pid, runner} ->
          case assign(pid, token, input, keys) do
            :ok ->
              Process.monitor(pid)

              assigned = %{
                runner: runner,
                execution_id: execution_id,
                attempt: assignment.attempt,
                athanor: assignment.athanor_id,
                children: %{},
                callers: caller.callers,
                logger: caller.logger
              }

              {:reply, :ok,
               %{
                 state
                 | assigned: Map.put(state.assigned, pid, assigned),
                   executions: Map.put(state.executions, execution_id, pid)
               }}

            {:error, :malformed} ->
              :ok = RunnerPool.taint(RunnerPool, pid, 0)
              {:reply, {:error, :malformed}, state}

            {:error, reason} ->
              Logger.error(
                "[Opus.WorkerService] the assign of #{execution_id} was not sent: #{inspect(reason)}"
              )

              :ok = RunnerPool.taint(RunnerPool, pid, 0)
              {:reply, {:error, :unavailable}, state}
          end

        {:error, {:refused, refusal}} ->
          {:reply, {:error, {:unavailable, refusal.message}}, state}

        {:error, reason} ->
          Logger.error("[Opus.WorkerService] no runner for #{execution_id}: #{inspect(reason)}")
          {:reply, {:error, :unavailable}, state}
      end
    end
  end

  # The assign as the protocol spells it; a value the protocol refuses
  # (the input past its bound) is the caller's, and refuses the start.
  defp assign(pid, token, input, keys) do
    RunnerProcess.send_message(pid, %{type: :assign, assignment: token, input: input, keys: keys})
  rescue
    ArgumentError -> {:error, :malformed}
  end

  # ---------------------------------------------------------------------------
  # Runners' ends
  # ---------------------------------------------------------------------------

  # A runner gone with its subtree assigned is reported holding the
  # subtree's root and every child it said it started: the attempts the
  # service knows it held. CYFR lapses the ones still running.
  defp gone(state, pid, _reason) do
    case Map.get(state.assigned, pid) do
      nil ->
        state

      assignment ->
        state
        |> report(
          assignment.runner,
          Enum.uniq([assignment.attempt | Map.values(assignment.children)]),
          assignment
        )
        |> forget(pid)
    end
  end

  # The subtree's root and its children are ended for this boot: a kill of
  # any of them is `:ok` from now on.
  defp forget(state, pid) do
    {assignment, assigned} = Map.pop(state.assigned, pid)

    ended =
      Enum.reduce(
        [assignment.execution_id | Map.keys(assignment.children)],
        state.ended,
        &remember(&2, &1)
      )

    %{
      state
      | assigned: assigned,
        executions: Map.delete(state.executions, assignment.execution_id),
        ended: ended
    }
  end

  # The runner that said it started the child `execution_id`.
  defp holder(state, execution_id) do
    Enum.find_value(state.assigned, fn {pid, assignment} ->
      if is_map_key(assignment.children, execution_id), do: pid
    end)
  end

  # Every attempt a runner of this boot holds: each subtree's root and the
  # children its runner said it started.
  defp held(state) do
    for {_pid, assignment} <- state.assigned,
        attempt <- Enum.uniq([assignment.attempt | Map.values(assignment.children)]),
        do: attempt
  end

  defp remember(%{ids: ids, order: order}, execution_id) do
    if MapSet.member?(ids, execution_id) do
      %{ids: ids, order: order}
    else
      ids = MapSet.put(ids, execution_id)
      order = :queue.in(execution_id, order)

      if MapSet.size(ids) > @remembered do
        {{:value, oldest}, order} = :queue.out(order)
        %{ids: MapSet.delete(ids, oldest), order: order}
      else
        %{ids: ids, order: order}
      end
    end
  end

  defp ended?(state, execution_id), do: MapSet.member?(state.ended.ids, execution_id)

  # A report runs beside the service, which never waits on CYFR, and is
  # watched until it is answered, so `await_reports/1` can wait for it.
  defp report(%{credentials: credentials, boot: boot} = state, runner, attempts, context) do
    {_pid, ref} =
      spawn_monitor(fn ->
        Process.put(:"$callers", context.callers)
        Cyfr.LoggerContext.restore(context.logger)

        case HostClient.runner_exited(credentials, boot, runner, attempts) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error(
              "[Opus.WorkerService] the exit of runner #{runner} (#{context.execution_id}) was " <>
                "not reported: #{inspect(reason)}"
            )
        end
      end)

    %{state | reports: Map.put(state.reports, ref, true)}
  end

  # Whoever waits for the reports in flight is answered once none is.
  defp reported(%{reports: reports} = state) when map_size(reports) > 0, do: state

  defp reported(state) do
    for from <- state.report_waiters, do: GenServer.reply(from, :ok)
    %{state | report_waiters: []}
  end
end
