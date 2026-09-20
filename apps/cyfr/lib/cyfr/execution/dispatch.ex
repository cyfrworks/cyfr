# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Dispatch do
  @moduledoc """
  Runs an execution on a worker service, and stops one.

  `run/4` dispatches to the first worker service in
  `config :cyfr, :workers` (each a `t:Cyfr.WorkerAPI.endpoint/0`, reached
  through `Cyfr.Execution.WorkerClient`) whose status answers its
  configured id: the status `Cyfr.Execution.WorkerWatch` heard from it
  within the last poll interval (`Cyfr.Execution.WorkerWatch.fresh_boot/2`),
  else one asked for now. The boot that status names is the attempt
  row's runner and the assignment's audience. In order:

    1. the run is admitted (`Cyfr.Execution.Admission.admit/4`): its row
       and its `Cyfr.Execution.Attempt`;
    2. the calling process, the run's waiter, is registered under the
       execution's id in `Cyfr.Execution.Registry` as `:admitted`: it has
       started nothing yet;
    3. the attempt takes the run's execution slot — `:child` for a run
       with a parent, `:background` when `opts[:class]` says so, `:root`
       otherwise — waiting at most the run's timeout or 30 seconds; a
       refusal closes the run failed, and a run whose row ended while it
       was queued (a cancel, its parent's cascade) leaves the queue when
       its row ends and is not started
       (`Cyfr.Execution.Attempt.take_slot/3`);
    4. the waiter's registration becomes `{:dispatched, endpoint}`, the
       assignment is signed (`Cyfr.Execution.Assignments.issue/1`), its
       attempt's keys are sealed with the worker service's dispatch seal key
       (`Cyfr.WorkerAuth.seal_attempt_keys/3`), and it is started on the
       worker service (`Cyfr.Execution.WorkerClient.start/4`) with the
       input's JSON; a run that is not started is closed failed, and a
       start the worker service refused (`{:unavailable, sentence}`: its
       keeper starts no runner) is closed failed with the service's
       sentence, "the execution worker refused the start: …". A start
       whose answer was lost after the worker service may have acted is
       reconciled against the attempt, never dispatched again: a runner
       that attached keeps the run, and a run no runner attached to is
       closed failed as "the execution worker did not answer the start"
       (a runner attaching after that finds no attempt and stops);
    5. the waiter waits for the attempt to close the run (`await/2`) and
       answers what the close recorded.

  A waiter that exits kills its run: its attempt asks the worker service
  to kill the runner. An attempt that stops without closing the run — its
  runner exited, its row lapsed, was lost or was ended by another writer —
  has the run closed lost (`Cyfr.Execution.Close.lost/1`), which answers
  the row as it stands, and then the worker service is asked to kill its
  runner, unless the run was never started; that kill is the one the run
  is counted by as an unreaped kill, whoever killed it first (`stop/2`).
  Once the run is dispatched the waiter's registration names the worker
  service's endpoint, so `stop/2` reaches the runner without killing the
  waiter.

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
  alias Cyfr.Execution.{WorkerClient, WorkerWatch}
  alias Cyfr.{WorkerAPI, WorkerAuth}
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
  `Cyfr.Execution.Admission.admit/4`'s (without `:service_id`, `:boot_id`
  and `:worker`, which dispatch sets) and `:class`. Answers the run's result
  as its close recorded it, or `{:error, :execution_unavailable}` when no
  configured worker service answers.
  """
  @spec run(Context.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%Context{} = ctx, reference, input, opts \\ [])
      when is_binary(reference) and is_map(input) and is_list(opts) do
    admitted =
      with {:ok, worker} <- worker(reference) do
        opts =
          Keyword.merge(opts,
            service_id: worker.service,
            boot_id: worker.boot,
            worker: worker.endpoint
          )

        with {:ok, admitted} <- Admission.admit(ctx, reference, input, opts) do
          {:ok, admitted, worker.endpoint}
        end
      end

    case admitted do
      {:ok, admitted, endpoint} ->
        dispatch(admitted, endpoint, input, opts)

      {:error, _reason} = refused ->
        give_back_invoke(ctx, opts)
        refused
    end
  end

  @doc """
  Admit `reference` with `input` in `ctx` for a runner that already runs
  on a worker service, and hand it the run. `opts` are
  `Cyfr.Execution.Admission.admit/4`'s, with `:service_id`, `:boot_id` and
  `:worker` naming the worker service the runner belongs to (its id, its
  boot and its `t:Cyfr.WorkerAPI.endpoint/0`), and `:runner` the runner.

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
        hand_over(admitted, Keyword.fetch!(opts, :runner), Keyword.fetch!(opts, :boot_id))

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
  first, which decides whether this caller may cancel it and is the only
  thing that decides the cancel; then its running children are failed
  (`Cyfr.Execution.Cascade`), what runs it is stopped (`stop/2`) and the
  cancel telemetry fires. A run cancelled while it is queued for its
  execution slot gives back its invoke-budget slot and its charge row
  here, and never takes the slot.
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
  Stop what runs `execution_id`, for a caller that already ended its row:
  the row's terminal write decided, and nothing here does more than
  release.

  The run's attempt is told first, without waiting for it
  (`Cyfr.Execution.Attempt.stop_ended/1`): one no runner has attached to
  stops and gives back what the run held, and one still queued for its
  execution slot leaves the queue. Then what runs it is found under its
  id in `Cyfr.Execution.Registry`. A run whose waiter has not started it
  (`:admitted`) has no runner, so no worker service is asked anything; a
  start that set off meanwhile is the waiter's to kill, once its attempt
  has stopped. A dispatched run's runner, or the run a claimed attempt was
  handed to (`claim/4`), is killed through its worker service
  (`Cyfr.Execution.WorkerClient.kill/2`); the worker service's exit report
  then stops an attempt its runner attached to, and its waiter, if any,
  answers the row as it stands. Any other holder is a process of this
  node (a turn root's, a task that has not dispatched yet), and is
  killed.

  A kill is counted against `tenant` as one whose native work may still
  run (`Cyfr.Execution.Attempt.note_unreaped/2`) once for each run, and
  only for a run a runner ran. A run with a waiter is counted where its
  end is seen, never here: by its waiter, which kills its lost run's
  runner once its attempt has stopped and counts that kill (the worker
  service answers `:ok` again for a runner already ended), or by its
  attempt, which kills and counts it when the waiter is gone. A run
  handed to its runner has neither, and its kill is counted here. The
  kill of a process of this node reaches nothing native, and is counted
  as nothing.

  A repeat finds no attempt to stop and gives nothing back again.
  """
  @spec stop(String.t(), String.t() | nil) :: :ok
  def stop(execution_id, tenant) when is_binary(execution_id) do
    Attempt.stop_ended(execution_id)

    case Registry.lookup(Cyfr.Execution.Registry, execution_id) do
      [{_waiter, :admitted}] ->
        :ok

      [{holder, {:dispatched, endpoint}}] ->
        # The entry of a run handed to its runner is its attempt's own; any
        # other is a waiter's, whose run is counted where its end is seen.
        if holder == Attempt.whereis(execution_id) do
          kill_runner(endpoint, execution_id, tenant)
        else
          WorkerClient.kill(endpoint, execution_id)
        end

      [{pid, _value}] ->
        Process.exit(pid, :kill)

      [] ->
        :ok
    end

    :ok
  end

  @typedoc """
  A worker service a run can be dispatched to: its configured service id,
  the boot its status answered, and its endpoint.
  """
  @type worker :: %{service: String.t(), boot: String.t(), endpoint: WorkerAPI.endpoint()}

  @doc """
  The worker service runs are dispatched to: the first entry of
  `config :cyfr, :workers` (a `t:Cyfr.WorkerAPI.endpoint/0`, whose
  `components` list names the name-level references it alone runs, or is
  nil) whose status answers its configured id, with the boot that status
  names; an entry that does not answer, or answers as another service, is
  skipped. The status is the one `Cyfr.Execution.WorkerWatch` heard
  within the last poll interval, else the entry is asked now. `worker/1`
  also requires the entry to run `reference`.
  `{:error, :execution_unavailable}` when no entry qualifies or answers.
  """
  @spec worker() :: {:ok, worker()} | {:error, :execution_unavailable}
  def worker, do: select(fn _entry -> true end)

  @spec worker(String.t()) :: {:ok, worker()} | {:error, :execution_unavailable}
  def worker(reference) when is_binary(reference) do
    name = name_of(reference)

    select(fn entry ->
      case entry do
        %{components: names} when is_list(names) -> name != nil and name in names
        _ -> true
      end
    end)
  end

  defp select(runs?) do
    :cyfr
    |> Application.get_env(:workers, [])
    |> Enum.find_value({:error, :execution_unavailable}, fn
      %{id: id, url: url} = entry when is_binary(id) and is_binary(url) ->
        if runs?.(entry), do: answering(entry)

      _ ->
        nil
    end)
  end

  defp answering(%{id: id} = entry) do
    endpoint = Map.put_new(entry, :components, nil)

    case WorkerWatch.fresh_boot(endpoint) do
      {:ok, boot} ->
        {:ok, %{service: id, boot: boot, endpoint: endpoint}}

      :unknown ->
        case WorkerClient.status(endpoint) do
          {:ok, %{service: ^id, boot: boot}} when is_binary(boot) ->
            {:ok, %{service: id, boot: boot, endpoint: endpoint}}

          _ ->
            nil
        end
    end
  end

  defp name_of(reference) do
    case Cyfr.ComponentRef.to_name_ref(reference) do
      {:ok, name} -> name
      {:error, _reason} -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Dispatch
  # ---------------------------------------------------------------------------

  defp dispatch(admitted, endpoint, input, opts) do
    registered? = register_waiter(admitted.execution_id)

    try do
      slot_wait = min(admitted.timeout_ms, @slot_wait_ms)

      # Only a run whose attempt holds its slot, its row still live, is
      # started, and its registration says so before the start sets off:
      # a run that was not started has no runner to kill.
      started? =
        case Attempt.take_slot(admitted.attempt, class(opts), slot_wait) do
          :ok ->
            mark_dispatched(admitted.execution_id, endpoint)
            start(admitted, endpoint, input)
            true

          :closed ->
            false
        end

      case wait(admitted.attempt, admitted.close) do
        {:closed, result} ->
          result

        {:lost, result} ->
          if started?,
            do: kill_runner(endpoint, admitted.execution_id, admitted.close.ctx.athanor_id)

          result
      end
    after
      if registered?, do: Registry.unregister(Cyfr.Execution.Registry, admitted.execution_id)
    end
  end

  # The assignment is signed once the attempt holds its slot, so its claim
  # window is not spent waiting for one. A run that is not started is closed
  # failed by its attempt; one whose start's answer was lost is closed only
  # if no runner attached (`Cyfr.Execution.Attempt.refuse/2`), since the
  # worker service may have started it.
  defp start(admitted, endpoint, input) do
    with {:signed, {:ok, issued}} <- {:signed, Assignments.issue(admitted.assignment)},
         {:ok, worker_key} <- Keys.worker_key(admitted.assignment.service),
         {:ok, sealed} <-
           WorkerAuth.seal_attempt_keys(
             WorkerAuth.dispatch_seal_key(worker_key),
             issued.attempt_keys
           ),
         :ok <- WorkerClient.start(endpoint, issued.assignment, Jason.encode!(input), sealed) do
      :ok
    else
      {:signed, {:error, reason}} ->
        refuse(admitted, "the execution assignment could not be signed", reason)

      # The worker service refused the start and started nothing: its
      # sentence is the run's failure, and there is nothing to reconcile.
      {:error, {:unavailable, sentence}} ->
        refuse(admitted, "the execution worker refused the start: " <> sentence, :unavailable)

      {:error, :lost} ->
        case Attempt.refuse(admitted.attempt, "the execution worker did not answer the start") do
          :attached ->
            Logger.warning(
              "[Cyfr.Execution.Dispatch] #{admitted.execution_id}: the start's answer was " <>
                "lost, and its runner attached"
            )

          :closed ->
            Logger.error(
              "[Cyfr.Execution.Dispatch] #{admitted.execution_id} was not started: the " <>
                "start's answer was lost, and no runner attached"
            )
        end

      {:error, reason} ->
        refuse(admitted, "the execution worker did not start the run", reason)
    end
  end

  # The attempt of a run claimed for a runner already running. Every
  # refusal closes the run, which answers its waiter, this process, what the
  # close recorded.
  defp hand_over(admitted, runner, boot) do
    slot_wait = min(admitted.timeout_ms, @slot_wait_ms)

    with :ok <- Attempt.take_slot(admitted.attempt, :child, slot_wait),
         {:ok, issued} <- sign(admitted),
         claimant = Map.merge(issued.attempt_keys.attempt, %{runner: runner, boot: boot}),
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
           Cyfr.Actor.in_athanor(claimant.athanor_id),
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

    _closed = Attempt.refuse(admitted.attempt, sentence)
    :ok
  end

  # The waiter's entry says how far the run has come, which is what
  # `stop/2` reads: `:admitted` until its attempt holds its slot, and then
  # `{:dispatched, endpoint}`, set before the start sets off. A process
  # that registered the id itself (a background task, before it runs what
  # it registered) keeps its entry, with the same values.
  defp register_waiter(execution_id) do
    case Registry.register(Cyfr.Execution.Registry, execution_id, :admitted) do
      {:ok, _owner} ->
        true

      {:error, {:already_registered, owner}} when owner == self() ->
        Registry.update_value(Cyfr.Execution.Registry, execution_id, fn _ -> :admitted end)
        false

      {:error, {:already_registered, _other}} ->
        false
    end
  end

  # An entry another process holds is not the waiter's to change.
  defp mark_dispatched(execution_id, endpoint) do
    Registry.update_value(Cyfr.Execution.Registry, execution_id, fn _ ->
      {:dispatched, endpoint}
    end)

    :ok
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

  # A kill that found a runner is counted; one that found none
  # (`:not_found`) has nothing to reap. A waiter kills its lost run's
  # runner only after closing the run, so the runner's exit report finds
  # nothing left to lapse; that kill is the one that counts its run, a
  # cancel's before it included (`stop/2`).
  defp kill_runner(endpoint, execution_id, tenant) do
    if WorkerClient.kill(endpoint, execution_id) == :ok,
      do: Attempt.note_unreaped(tenant, execution_id)

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

  defp emit_cancel_telemetry(ctx, execution_id) do
    :telemetry.execute(
      [:cyfr, :opus, :execute, :exception],
      %{duration: 0, system_time: System.system_time()},
      %{execution_id: execution_id, user_id: ctx.user_id, error: "cancelled", status: :cancelled}
    )
  end
end
