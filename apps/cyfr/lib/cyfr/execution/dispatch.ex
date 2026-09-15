# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Dispatch do
  @moduledoc """
  Runs an execution on a worker service, and stops one.

  `run/4` dispatches to the first worker service in
  `config :cyfr, :workers` (each a `Cyfr.WorkerAPI` module), whose boot id
  (`c:Cyfr.WorkerAPI.status/0`) is the attempt row's runner and the
  assignment's audience. In order:

    1. the run is admitted (`Cyfr.Execution.Admission.admit/4`): its row
       and its `Cyfr.Execution.Attempt`;
    2. the calling process, the run's waiter, is registered under the
       execution's id in `Cyfr.Execution.Registry`;
    3. the attempt takes the run's execution slot — `:child` for a run
       with a parent, `:background` when `opts[:class]` says so, `:root`
       otherwise — waiting at most the run's timeout or 30 seconds; a
       refusal closes the run failed;
    4. the assignment is signed (`Cyfr.Execution.Assignments.issue/1`), its
       attempt's keys are sealed with the worker service's dispatch seal key
       (`Cyfr.WorkerAuth.seal_attempt_keys/3`), and it is started on the
       worker service (`c:Cyfr.WorkerAPI.start/3`) with the input's JSON; a
       run that is not started is closed failed;
    5. the waiter waits for the attempt to close the run (`await/2`) and
       answers what the close recorded.

  A waiter that exits kills its run: its attempt asks the worker service
  to kill the runner. An attempt that stops without closing the run — its
  runner exited, its row lapsed or was lost — has the run closed lost
  (`Cyfr.Execution.Close.lost/1`), and then the worker service is asked to
  kill its runner. The waiter's registration names the worker service, so
  `stop/2` reaches the runner without killing the waiter.

  `claim/4` admits a run for a runner that already runs instead of
  starting one: a formula's child, run in its parent's runner. The run's
  attempt is claimed for that runner and handed to it
  (`Cyfr.Execution.Attempt.hand_over/1`), so nothing on CYFR waits for it,
  and the runner closes it as it closes its own.

  A spawned child's caller holds the invoke-budget slot it charged under
  the guard (`opts[:held_invoke]`, with `opts[:charge]` naming its charge
  row); the run's attempt takes it over, and gives it back when it stops.
  A run refused before its attempt opens gives it back here.

  `cancel/3` cancels a running execution's row and kills what runs it
  (`stop/2`); `stop/2` is also how a cascade stops a child
  (`Cyfr.Execution.Cascade`).
  """

  require Logger

  alias Cyfr.Execution.{Admission, Assignments, Attempt, Cascade, Charge, Close, Keys, Record}
  alias Cyfr.WorkerAuth
  alias Sanctum.Context

  @slot_wait_ms 30_000

  @typedoc """
  A run claimed for a runner that already runs: its signed assignment, its
  attempt's keys and the fields its vault edge projects.
  """
  @type claimed :: %{
          assignment: Cyfr.Assignment.token(),
          attempt_keys: WorkerAuth.attempt_keys(),
          secrets: %{optional(String.t()) => String.t()}
        }

  @doc """
  Run `reference` with `input` in `ctx` on a worker service. `opts` are
  `Cyfr.Execution.Admission.admit/4`'s (without `:runner_id` and
  `:worker`, which dispatch sets) and `:class`. Answers the run's result
  as its close recorded it, or `{:error, :execution_unavailable}` when no
  configured worker service answers.
  """
  @spec run(Context.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%Context{} = ctx, reference, input, opts \\ [])
      when is_binary(reference) and is_map(input) and is_list(opts) do
    admitted =
      with {:ok, worker, boot} <- worker() do
        opts = Keyword.merge(opts, runner_id: boot, worker: worker)

        with {:ok, admitted} <- Admission.admit(ctx, reference, input, opts) do
          {:ok, admitted, worker}
        end
      end

    case admitted do
      {:ok, admitted, worker} ->
        dispatch(admitted, worker, input, opts)

      {:error, _reason} = refused ->
        give_back_invoke(ctx, opts)
        refused
    end
  end

  @doc """
  Admit `reference` with `input` in `ctx` for a runner that already runs
  on a worker service, and hand it the run. `opts` are
  `Cyfr.Execution.Admission.admit/4`'s, with `:runner_id` and `:worker`
  naming the worker service the runner belongs to (its boot id and its
  `Cyfr.WorkerAPI` module), and `:runner` the runner.

  In order: the run is admitted with the calling process as its waiter;
  its attempt takes a `:child` execution slot, waiting as `run/4` does; its
  assignment is signed; the attempt row is claimed for the runner
  (`Arca.ExecutionAttempts.claim/4`) and the run's vault edge is unsealed
  (`Cyfr.Execution.Attempt.attach/2`); and the attempt is handed to the
  runner (`Cyfr.Execution.Attempt.hand_over/1`). Answers
  `{:ok, claimed}` (`t:claimed/0`), or, when any step refuses, the refusal
  the run was closed with: `{:error, reason}` as `Cyfr.Execution.Close`
  answered, a `{:setup_required, payload}` refusal included.
  """
  @spec claim(Context.t(), String.t(), map(), keyword()) ::
          {:ok, claimed()} | {:error, term()}
  def claim(%Context{} = ctx, reference, input, opts)
      when is_binary(reference) and is_map(input) and is_list(opts) do
    case Admission.admit(ctx, reference, input, opts) do
      {:ok, admitted} ->
        hand_over(admitted, Keyword.fetch!(opts, :runner))

      {:error, _reason} = refused ->
        give_back_invoke(ctx, opts)
        refused
    end
  end

  @doc """
  Wait, in the process that opened the attempt `pid`, for it to close its
  run, and answer the run's result: `{:ok, result}` or `{:error, reason}`
  as `Cyfr.Execution.Close` answered. An attempt that stops without closing
  its run is closed lost with `close` (`Cyfr.Execution.Close.lost/1`).
  """
  @spec await(pid(), Close.t()) :: {:ok, map()} | {:error, term()}
  def await(pid, %Close{} = close) when is_pid(pid) do
    {_ended, result} = wait(pid, close)
    result
  end

  @doc """
  Cancel a running execution: the tenant-scoped record cancel
  (`Cyfr.Execution.Record.cancel/3`, with `opts[:restart_required]`)
  first, which decides whether this caller may cancel it; then its running
  children are failed (`Cyfr.Execution.Cascade`), what runs it is stopped
  (`stop/2`) and the cancel telemetry fires.
  """
  @spec cancel(Context.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def cancel(%Context{} = ctx, execution_id, opts \\ []) do
    # The record cancel enforces tenant ownership and the running
    # precondition, so it must succeed before the id-keyed registry is
    # touched: a caller must not stop another tenant's run by its id.
    case Record.cancel(ctx, execution_id, Keyword.take(opts, [:restart_required])) do
      {:ok, record} ->
        # The children are failed before the run is stopped: stopping it
        # stops what it started, whose attempts would otherwise lapse the
        # children's rows first.
        Cascade.fail_children_of(execution_id)
        stop(execution_id, record.athanor_id)
        emit_cancel_telemetry(ctx, execution_id)
        {:ok, %{cancelled: true, execution_id: execution_id}}

      error ->
        error
    end
  end

  @doc """
  End a running execution because its consent changed underneath it:
  `cancel/3` with the typed `restart_required` payload. Rerunning selects
  the new revision; in-flight authority is never rebound.
  """
  @spec cancel_for_restart(Context.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def cancel_for_restart(%Context{} = ctx, execution_id, payload) when is_map(payload) do
    cancel(ctx, execution_id, restart_required: payload)
  end

  @doc """
  Stop what runs `execution_id`, found under its id in
  `Cyfr.Execution.Registry`, for a caller that already ended its row. A
  dispatched run's runner, or the run a claimed attempt was handed to
  (`claim/4`), is killed through its worker service
  (`c:Cyfr.WorkerAPI.kill/1`) and the kill is counted against `tenant` as
  one whose native work may still run; the worker service's exit report
  then stops its attempt, and its waiter, if any, answers the row as it
  stands. Any other holder (a turn root's, a task that has not dispatched
  yet) is counted the same way and killed.
  """
  @spec stop(String.t(), String.t() | nil) :: :ok
  def stop(execution_id, tenant) when is_binary(execution_id) do
    case Registry.lookup(Cyfr.Execution.Registry, execution_id) do
      [{_waiter, {:dispatched, worker}}] ->
        kill_runner(worker, execution_id, tenant)

      [{pid, _value}] ->
        note_unreaped(tenant, execution_id)
        Process.exit(pid, :kill)

      [] ->
        :ok
    end

    :ok
  end

  @doc """
  The worker service a run is dispatched to: the first module in
  `config :cyfr, :workers` that is loaded, with the boot id its status
  answers. `{:error, :execution_unavailable}` when none is configured or it
  does not answer.
  """
  @spec worker() :: {:ok, module(), String.t()} | {:error, :execution_unavailable}
  def worker do
    case Enum.find(Application.get_env(:cyfr, :workers, []), &Code.ensure_loaded?/1) do
      nil ->
        {:error, :execution_unavailable}

      worker ->
        case worker.status() do
          {:ok, %{boot: boot}} when is_binary(boot) -> {:ok, worker, boot}
          _ -> {:error, :execution_unavailable}
        end
    end
  catch
    :exit, _reason -> {:error, :execution_unavailable}
  end

  # ---------------------------------------------------------------------------
  # Dispatch
  # ---------------------------------------------------------------------------

  defp dispatch(admitted, worker, input, opts) do
    registered? = register_waiter(admitted.execution_id, worker)

    try do
      slot_wait = min(admitted.timeout_ms, @slot_wait_ms)

      case Attempt.take_slot(admitted.attempt, class(opts), slot_wait) do
        :ok -> start(admitted, worker, input)
        :closed -> :ok
      end

      case wait(admitted.attempt, admitted.close) do
        {:closed, result} ->
          result

        {:lost, result} ->
          kill_runner(worker, admitted.execution_id, admitted.close.ctx.athanor_id)
          result
      end
    after
      if registered?, do: Registry.unregister(Cyfr.Execution.Registry, admitted.execution_id)
    end
  end

  # The assignment is signed once the attempt holds its slot, so its claim
  # window is not spent waiting for one. A run that is not started is closed
  # failed by its attempt.
  defp start(admitted, worker, input) do
    with {:signed, {:ok, issued}} <- {:signed, Assignments.issue(admitted.assignment)},
         {:ok, worker_key} <- Keys.worker_key(admitted.assignment.audience),
         {:ok, sealed} <-
           WorkerAuth.seal_attempt_keys(
             WorkerAuth.dispatch_seal_key(worker_key),
             issued.attempt_keys
           ),
         :ok <- worker.start(issued.assignment, Jason.encode!(input), sealed) do
      :ok
    else
      {:signed, {:error, reason}} ->
        refuse(admitted, "the execution assignment could not be signed", reason)

      {:error, reason} ->
        refuse(admitted, "the execution worker did not start the run", reason)
    end
  catch
    :exit, reason -> refuse(admitted, "the execution worker did not start the run", reason)
  end

  # The attempt of a run claimed for a runner already running. Every
  # refusal closes the run, which answers its waiter, this process, what the
  # close recorded.
  defp hand_over(admitted, runner) do
    slot_wait = min(admitted.timeout_ms, @slot_wait_ms)

    with :ok <- Attempt.take_slot(admitted.attempt, :child, slot_wait),
         {:ok, issued} <- sign(admitted),
         claimant = Map.put(issued.attempt_keys.attempt, :runner, runner),
         :ok <- claim_row(admitted, claimant),
         {:ok, secrets} <- Attempt.attach(admitted.execution_id, claimant),
         :ok <- Attempt.hand_over(admitted.attempt) do
      {:ok, %{assignment: issued.assignment, attempt_keys: issued.attempt_keys, secrets: secrets}}
    else
      _refused ->
        Attempt.refuse(admitted.attempt, "the execution could not be handed to its runner")

        case wait(admitted.attempt, admitted.close) do
          {_ended, {:error, _reason} = refused} -> refused
          {_ended, {:ok, _result}} -> {:error, "Execution attempt ended before it closed"}
        end
    end
  end

  defp sign(admitted) do
    case Assignments.issue(admitted.assignment) do
      {:ok, issued} ->
        {:ok, issued}

      {:error, reason} ->
        refuse(admitted, "the execution assignment could not be signed", reason)
    end
  end

  defp claim_row(admitted, claimant) do
    case Arca.ExecutionAttempts.claim(
           claimant.athanor_id,
           claimant.attempt,
           claimant.fence,
           claimant.runner
         ) do
      :ok -> :ok
      {:error, reason} -> refuse(admitted, "the execution could not be claimed", reason)
    end
  end

  defp refuse(admitted, sentence, reason) do
    Logger.error(
      "[Cyfr.Execution.Dispatch] #{admitted.execution_id} was not started: #{inspect(reason)}"
    )

    Attempt.refuse(admitted.attempt, sentence)
  end

  # A process that registered the id itself (a background task, before it
  # runs what it registered) keeps its entry; its value marks the run as
  # dispatched either way.
  defp register_waiter(execution_id, worker) do
    case Registry.register(Cyfr.Execution.Registry, execution_id, {:dispatched, worker}) do
      {:ok, _owner} ->
        true

      {:error, {:already_registered, owner}} when owner == self() ->
        Registry.update_value(Cyfr.Execution.Registry, execution_id, fn _ ->
          {:dispatched, worker}
        end)

        false

      {:error, {:already_registered, _other}} ->
        false
    end
  end

  defp class(opts) do
    cond do
      opts[:class] == :background -> :background
      opts[:parent_execution_id] -> :child
      true -> :root
    end
  end

  defp wait(pid, close) do
    ref = Process.monitor(pid)

    receive do
      {Attempt, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        {:closed, result}

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        {:lost, Close.lost(close)}
    end
  end

  # A kill that found a runner is counted; a waiter kills its lost run's
  # runner only after closing the run, so the runner's exit report finds
  # nothing left to lapse.
  defp kill_runner(worker, execution_id, tenant) do
    killed =
      try do
        worker.kill(execution_id)
      catch
        :exit, reason -> {:error, reason}
      end

    if killed == :ok, do: note_unreaped(tenant, execution_id)
    :ok
  end

  defp give_back_invoke(ctx, opts) do
    with true <- opts[:held_invoke] == true,
         %Cyfr.Authority{} = authority <- opts[:authority] do
      Sanctum.Authority.release_invoke(authority)
      Charge.give_back(authority, charge: opts[:charge], ctx: ctx)
    end

    :ok
  end

  defp note_unreaped(tenant, execution_id) do
    case Cyfr.Execution.Semaphore.note_unreaped(tenant, execution_id) do
      :ok ->
        :ok

      {:error, :unavailable} ->
        Logger.error(
          "[Cyfr.Execution.Dispatch] unreaped kill of #{inspect(execution_id)} for tenant " <>
            "#{inspect(tenant)} is uncharged: the semaphore did not answer"
        )
    end
  end

  defp emit_cancel_telemetry(ctx, execution_id) do
    :telemetry.execute(
      [:cyfr, :opus, :execute, :exception],
      %{duration: 0, system_time: System.system_time()},
      %{execution_id: execution_id, user_id: ctx.user_id, error: "cancelled", status: :cancelled}
    )
  end
end
