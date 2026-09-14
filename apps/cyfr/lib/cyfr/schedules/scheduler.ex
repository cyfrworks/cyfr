# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Schedules.Scheduler do
  @moduledoc """
  The scheduler of recurring component executions: a timer per active
  schedule (`Process.send_after/3`), each firing claiming one occurrence
  and running it through the execution port.

  Each occurrence fires at most once across the cluster:
  `Arca.ScheduleOccurrences.claim/3` advances the schedule's cursor and
  inserts the occurrence row in one transaction, and the loser is told
  `:held`. The occurrence row is then the run's record — `started` by the
  execution's own admission (`Arca.Execution.admit/2` moves it inside
  the transaction that admits the row), `completed` or `failed` when the
  run answers, `uncertain` when the runner died with a started
  execution. A schedule's `concurrency` decides overlap: `forbid` leaves
  a due occurrence unclaimed while another is open and checks again
  shortly; `allow` claims it regardless.

  A scheduler that starts recovers what the last one left: an
  occurrence claimed and never invoked runs once, a started one whose
  execution ended or was swept while the occurrence stayed open is
  `uncertain`. A due time in the past fires at once, once.
  """

  use GenServer
  require Logger
  require Arca.Repo.Errors

  alias Arca.{CronSchedule, ScheduleOccurrences}
  alias Cyfr.Schedules.Cron

  @db_load_errors Arca.Repo.Errors.db_errors() ++ [DBConnection.OwnershipError, RuntimeError]
  @db_fire_errors Arca.Repo.Errors.db_errors() ++ [DBConnection.OwnershipError]
  @db_timer_errors Arca.Repo.Errors.db_errors() ++ [DBConnection.OwnershipError, ArgumentError]

  @max_timer_ms 60 * 60 * 1_000
  @max_load_retries 5
  @recheck_ms 30_000

  def start_link(opts \\ []) do
    # Long-lived, querying on boot and on timers: under the test sandbox
    # it would keep a lent connection past its owner's exit, so its own
    # suite starts it explicitly and nothing else runs it there.
    if Application.get_env(:cyfr, :cron_scheduler_enabled, true) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :ignore
    end
  end

  def add(schedule_id), do: GenServer.cast(__MODULE__, {:add, schedule_id})
  def remove(schedule_id), do: GenServer.cast(__MODULE__, {:remove, schedule_id})
  def pause(schedule_id), do: GenServer.cast(__MODULE__, {:pause, schedule_id})
  def resume(schedule_id), do: GenServer.cast(__MODULE__, {:resume, schedule_id})
  def update(schedule_id), do: GenServer.cast(__MODULE__, {:update, schedule_id})
  def reload, do: GenServer.cast(__MODULE__, :reload)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{timers: %{}, tasks: %{}, load_retry_count: 0}, {:continue, :load_schedules}}
  end

  @impl true
  def handle_continue(:load_schedules, state) do
    {:noreply, state |> load_all_schedules() |> recover_when_owner()}
  end

  @impl true
  def handle_cast({:add, schedule_id}, state), do: {:noreply, schedule_timer(schedule_id, state)}

  def handle_cast({:update, schedule_id}, state),
    do: {:noreply, schedule_timer(schedule_id, state)}

  def handle_cast({:resume, schedule_id}, state),
    do: {:noreply, schedule_timer(schedule_id, state)}

  def handle_cast({:remove, schedule_id}, state), do: {:noreply, cancel_timer(schedule_id, state)}
  def handle_cast({:pause, schedule_id}, state), do: {:noreply, cancel_timer(schedule_id, state)}

  def handle_cast(:reload, state) do
    {:noreply, state |> cancel_all_timers() |> load_all_schedules()}
  end

  @impl true
  # A boot that does not own the control plane claims no occurrence: the
  # schedule is asked again at the recheck.
  def handle_info({:fire, schedule_id}, state) do
    state = %{state | timers: Map.delete(state.timers, schedule_id)}

    case Cyfr.ControlPlane.when_owner(fn -> fire_schedule(schedule_id, state) end) do
      :not_owner -> {:noreply, recheck_later(schedule_id, state)}
      fired -> {:noreply, fired}
    end
  end

  def handle_info(:recover_occurrences, state), do: {:noreply, recover_when_owner(state)}

  def handle_info({:recheck, schedule_id}, state) do
    state = %{state | timers: Map.delete(state.timers, schedule_id)}
    {:noreply, schedule_timer(schedule_id, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.tasks, fn {_id, task} -> task.ref == ref end) do
      {schedule_id, task} ->
        state = %{state | tasks: Map.delete(state.tasks, schedule_id)}
        if failed_run?(reason), do: runner_died(schedule_id, task, reason)
        broadcast_update(task.ctx)
        {:noreply, schedule_timer(schedule_id, state)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(:retry_load, state) do
    if state.load_retry_count >= @max_load_retries do
      Logger.error(
        "[Schedules] max retries (#{@max_load_retries}) exhausted loading schedules — retrying in 5 minutes"
      )

      :telemetry.execute([:cyfr, :schedules, :scheduler, :load_failed], %{count: 1}, %{
        retries: state.load_retry_count
      })

      Process.send_after(self(), :retry_load, 300_000)
      {:noreply, state}
    else
      {:noreply, load_all_schedules(state)}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.timers, fn {_id, ref} -> Process.cancel_timer(ref) end)

    if map_size(state.tasks) > 0 do
      ids = state.tasks |> Map.keys() |> Enum.join(", ")
      Logger.info("[Schedules] shutting down with running schedules: #{ids}")
    end

    :ok
  end

  # A task exit that is not the run failing: it finished before its
  # monitor was installed, or the scheduler is going down.
  @doc false
  @spec failed_run?(term()) :: boolean()
  def failed_run?(:normal), do: false
  def failed_run?(:noproc), do: false
  def failed_run?(:shutdown), do: false
  def failed_run?({:shutdown, _}), do: false
  def failed_run?(_reason), do: true

  # ---------------------------------------------------------------------------
  # Loading and recovery
  # ---------------------------------------------------------------------------

  defp load_all_schedules(state) do
    case CronSchedule.active_schedules() do
      {:error, :database_error} ->
        load_retry(state, "storage unavailable")

      {:ok, schedules} ->
        Logger.info("[Schedules] loading #{length(schedules)} active schedule(s)")
        state = Enum.reduce(schedules, state, &load_one_schedule/2)
        %{state | load_retry_count: 0}
    end
  rescue
    e in @db_load_errors ->
      level = if match?(%DBConnection.OwnershipError{}, e), do: :warning, else: :error
      load_retry(state, Exception.message(e), level)
  catch
    :exit, reason ->
      load_retry(state, "exited: " <> inspect(reason), :warning)
  end

  defp load_retry(state, why, level \\ :error) do
    retry_count = state.load_retry_count + 1
    delay_ms = min(5_000 * Integer.pow(2, retry_count - 1), 60_000)

    Logger.log(
      level,
      "[Schedules] failed to load schedules (#{why}), retry #{retry_count}/#{@max_load_retries} in #{delay_ms}ms"
    )

    Process.send_after(self(), :retry_load, delay_ms)
    %{state | load_retry_count: retry_count}
  end

  # Boot arms timers: the cursor each row carries is the next occurrence,
  # and a cursor already in the past fires at once.
  defp load_one_schedule(schedule, acc) do
    case Cron.parse(schedule.cron_expression) do
      {:ok, _} ->
        schedule_timer(schedule.id, acc)

      {:error, reason} ->
        Logger.warning("[Schedules] invalid cron for schedule #{schedule.id}: #{reason}")
        acc
    end
  rescue
    e ->
      Logger.warning(
        "[Schedules] failed to load schedule #{schedule.id}: #{Exception.message(e)}"
      )

      timer_failed(schedule.id, Exception.message(e))
      acc
  catch
    :exit, reason ->
      Logger.warning(
        "[Schedules] failed to load schedule #{schedule.id}: exited #{inspect(reason)}"
      )

      timer_failed(schedule.id, inspect(reason))
      acc
  end

  defp recover_when_owner(state) do
    case Cyfr.ControlPlane.when_owner(fn -> recover_occurrences(state) end) do
      :not_owner ->
        Process.send_after(self(), :recover_occurrences, @recheck_ms)
        state

      recovered ->
        recovered
    end
  end

  # What the last scheduler left open: a claimed occurrence was never
  # invoked and runs once; a started one whose execution is gone is
  # uncertain.
  defp recover_occurrences(state) do
    case ScheduleOccurrences.recoverable() do
      {:ok, %{never_invoked: never_invoked, lapsed: lapsed}} ->
        Enum.each(lapsed, fn occurrence ->
          Logger.warning(
            "[Schedules] occurrence #{occurrence.id} of #{occurrence.schedule_id} started " <>
              "and its execution ended without it: uncertain"
          )

          ScheduleOccurrences.finish(occurrence.athanor_id, occurrence.id, "uncertain")
        end)

        Enum.reduce(never_invoked, state, fn occurrence, acc ->
          if Map.has_key?(acc.tasks, occurrence.schedule_id),
            do: acc,
            else: rerun_claimed(occurrence, acc)
        end)

      {:error, :database_error} ->
        state
    end
  rescue
    e in @db_load_errors ->
      Logger.warning("[Schedules] occurrence recovery failed: #{Exception.message(e)}")
      state
  catch
    :exit, reason ->
      Logger.warning("[Schedules] occurrence recovery exited: #{inspect(reason)}")
      state
  end

  defp rerun_claimed(occurrence, state) do
    with {:ok, %{status: "active"} = schedule} <-
           CronSchedule.get_for_daemon(occurrence.schedule_id),
         {:ok, exec_reference, input} <- runnable(schedule) do
      ctx = context_of(schedule)

      Logger.info(
        "[Schedules] occurrence #{occurrence.id} of #{schedule.id} claimed and never run: running it"
      )

      run_occurrence(schedule, occurrence, ctx, exec_reference, input, state)
    else
      _ ->
        _ = ScheduleOccurrences.finish(occurrence.athanor_id, occurrence.id, "failed")
        state
    end
  end

  # ---------------------------------------------------------------------------
  # Firing
  # ---------------------------------------------------------------------------

  defp fire_schedule(schedule_id, state) do
    case CronSchedule.get_for_daemon(schedule_id) do
      {:error, :not_found} ->
        state

      {:error, :database_error} ->
        retry_later(schedule_id, state)

      {:ok, %{status: "active"} = schedule} ->
        ctx = context_of(schedule)

        if Sanctum.Tenancy.channel_active?(schedule.athanor_id, schedule.user_id) do
          fire_active_schedule(schedule, ctx, state)
        else
          # The athanor is archived or the creator was denied on this
          # server — the run is skipped and recorded, never the schedule
          # deleted: the members who remain decide its fate.
          Logger.warning(
            "[Schedules] schedule #{schedule_id} athanor #{schedule.athanor_id} or " <>
              "creator #{inspect(schedule.user_id)} no longer active — skipping run"
          )

          record_error(ctx, schedule_id, "Athanor or creator no longer active — run skipped")
          emit_schedule_failed(schedule_id, ctx, "athanor_or_creator_inactive")
          schedule_timer(schedule_id, state)
        end

      {:ok, _other_status} ->
        state
    end
  rescue
    e in @db_fire_errors ->
      Logger.warning(
        "[Schedules] fire_schedule #{schedule_id} failed (#{Exception.message(e)}), retrying in 30s"
      )

      :telemetry.execute([:cyfr, :schedules, :scheduler, :fire_failed], %{count: 1}, %{
        schedule_id: schedule_id
      })

      retry_later(schedule_id, state)
  catch
    :exit, reason ->
      Logger.warning(
        "[Schedules] fire_schedule #{schedule_id} exited (#{inspect(reason)}), retrying in 30s"
      )

      retry_later(schedule_id, state)
  end

  defp fire_active_schedule(schedule, ctx, state) do
    case runnable(schedule) do
      {:error, :unresolved_reference} ->
        Logger.error(
          "[Schedules] schedule #{schedule.id} has no resolved_reference. " <>
            "Cannot execute with unresolved reference '#{schedule.reference}'. " <>
            "Re-create or update the schedule to pin a resolved version."
        )

        emit_schedule_failed(schedule.id, ctx, :unresolved_reference)
        record_error(ctx, schedule.id, "No resolved reference — re-create or update the schedule")
        schedule_timer(schedule.id, state)

      {:error, :invalid_input} ->
        Logger.error(
          "[Schedules] schedule #{schedule.id} has invalid JSON input, skipping execution"
        )

        emit_schedule_failed(schedule.id, ctx, :invalid_input)
        record_error(ctx, schedule.id, "Invalid JSON input")
        schedule_timer(schedule.id, state)

      {:ok, exec_reference, input} ->
        case claim(schedule) do
          {:ok, occurrence} ->
            run_occurrence(schedule, occurrence, ctx, exec_reference, input, state)

          :held ->
            # Not due, or another node advanced the cursor first.
            schedule_timer(schedule.id, state)

          :overlapping ->
            # An occurrence of this schedule is still open and the
            # schedule forbids overlap: the due one waits, and is looked
            # at again shortly.
            recheck_later(schedule.id, state)

          {:error, :database_error} ->
            retry_later(schedule.id, state)
        end
    end
  end

  # What a run needs of the row, fail-closed: a resolved reference and
  # input that decodes.
  defp runnable(%{resolved_reference: nil}), do: {:error, :unresolved_reference}

  defp runnable(schedule) do
    case decode_json(schedule.input) do
      {:ok, input} -> {:ok, schedule.resolved_reference, input}
      {:error, :invalid_json} -> {:error, :invalid_input}
    end
  end

  # Claiming and advancing are one write. An expression that no longer
  # parses cannot yield a next occurrence — nothing is claimed rather
  # than an occurrence nothing can advance past.
  defp claim(schedule) do
    case compute_next_run(schedule.cron_expression) do
      {:ok, next_run} ->
        ScheduleOccurrences.claim(schedule, node_name(), next_run)

      _unparseable ->
        Logger.warning(
          "[Schedules] schedule #{schedule.id} has an unusable cron expression — not claiming"
        )

        :held
    end
  end

  defp run_occurrence(schedule, occurrence, ctx, exec_reference, input, state) do
    logger_metadata = Cyfr.LoggerContext.capture()

    case Task.Supervisor.start_child(Cyfr.Schedules.TaskSupervisor, fn ->
           Cyfr.LoggerContext.restore(logger_metadata)
           run(schedule, occurrence, ctx, exec_reference, input)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        broadcast_update(ctx)

        task = %{
          ref: ref,
          occurrence_id: occurrence.id,
          athanor_id: occurrence.athanor_id,
          ctx: ctx
        }

        %{state | tasks: Map.put(state.tasks, schedule.id, task)}

      {:error, reason} ->
        Logger.error(
          "[Schedules] failed to spawn task for schedule #{schedule.id}: #{inspect(reason)}"
        )

        _ = ScheduleOccurrences.finish(occurrence.athanor_id, occurrence.id, "failed")
        emit_schedule_failed(schedule.id, ctx, {:spawn_failed, reason})
        record_error(ctx, schedule.id, "spawn_failed: #{inspect(reason)}")
        schedule_timer(schedule.id, state)
    end
  end

  # One invocation through the execution port, the occurrence joined to
  # the execution by its admission; the occurrence closes with the
  # answer, whichever it is.
  defp run(schedule, occurrence, ctx, exec_reference, input) do
    request_id = Cyfr.UUID7.request_id()
    ctx = %{ctx | request_id: request_id}
    execution_id = Cyfr.UUID7.execution_id()

    Emissary.MCP.RequestLog.safe_log_started(ctx, request_id, %{
      tool: "schedule",
      action: "fire",
      method: "cron/fire",
      input: %{schedule_id: schedule.id, reference: exec_reference, input: input}
    })

    start_native = System.monotonic_time()

    :telemetry.execute(
      [:cyfr, :schedules, :fired],
      %{system_time: System.system_time()},
      %{
        request_id: request_id,
        schedule_id: schedule.id,
        occurrence_id: occurrence.id,
        reference: exec_reference,
        execution_id: execution_id,
        athanor_id: ctx.athanor_id,
        user_id: ctx.user_id
      }
    )

    # A schedule fires under its bound profile's consent, through the one
    # door into "start a root", whoever is knocking.
    run_result =
      Cyfr.Execution.run_root(ctx, {:id, schedule.profile_id}, exec_reference, input,
        execution_id: execution_id,
        occurrence_id: occurrence.id,
        schedule_id: schedule.id,
        class: :background,
        retention_class: "schedule"
      )

    duration_ms =
      System.convert_time_unit(System.monotonic_time() - start_native, :native, :millisecond)

    case run_result do
      {:ok, result} ->
        output = Map.get(result, :output, result)
        _ = ScheduleOccurrences.finish(occurrence.athanor_id, occurrence.id, "completed")
        record_run(ctx, schedule.id, execution_id)

        Emissary.MCP.RequestLog.safe_log_completed(ctx, request_id, %{
          output: output,
          duration_ms: duration_ms,
          routed_to: "opus"
        })

        # What `:fired` carried, plus the outcome and the row's own
        # metadata as stored — a consumer that keeps the outcome
        # (`Cyfr.ScheduleNotes`) reads `keep_outcome` off it without a
        # second read of the row.
        :telemetry.execute(
          [:cyfr, :schedules, :completed],
          %{system_time: System.system_time(), duration_ms: duration_ms},
          %{
            request_id: request_id,
            schedule_id: schedule.id,
            occurrence_id: occurrence.id,
            reference: exec_reference,
            execution_id: execution_id,
            athanor_id: ctx.athanor_id,
            user_id: ctx.user_id,
            output: output,
            metadata: schedule.metadata
          }
        )

        Logger.debug("[Schedules] schedule #{schedule.id} completed (#{execution_id})")

      {:error, reason} ->
        # An admission that failed left the occurrence claimed; a run
        # that failed left it started. Either way it ends failed, and
        # nothing was invoked twice.
        _ = ScheduleOccurrences.finish(occurrence.athanor_id, occurrence.id, "failed")

        Emissary.MCP.RequestLog.safe_log_failed(ctx, request_id, %{
          error: inspect(reason),
          duration_ms: duration_ms,
          routed_to: "opus"
        })

        Logger.warning("[Schedules] schedule #{schedule.id} failed: #{inspect(reason)}")
        emit_schedule_failed(schedule.id, ctx, reason, execution_id)
        record_error(ctx, schedule.id, inspect(reason))
    end
  end

  # The runner died without answering: the occurrence it held ends as
  # what the row says — never invoked, or started with an unknown end.
  defp runner_died(schedule_id, task, reason) do
    Logger.warning("[Schedules] schedule #{schedule_id} execution failed: #{inspect(reason)}")
    _ = ScheduleOccurrences.settle_dead(task.athanor_id, task.occurrence_id)
    record_error(task.ctx, schedule_id, inspect(reason))
  end

  defp record_run(ctx, schedule_id, execution_id) do
    case CronSchedule.record_run(ctx, schedule_id, execution_id) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Schedules] failed to record_run for #{schedule_id}: #{inspect(reason)}")
    end
  end

  defp record_error(ctx, schedule_id, message) do
    case CronSchedule.record_error(ctx, schedule_id, message) do
      {:ok, _} ->
        :ok

      {:error, err} ->
        Logger.warning("[Schedules] failed to record_error for #{schedule_id}: #{inspect(err)}")

        :telemetry.execute(
          [:cyfr, :schedules, :scheduler, :record_error_failed],
          %{count: 1},
          %{schedule_id: schedule_id, error: err}
        )
    end
  end

  # A schedule that could not run, or ran and failed: one event the tray
  # bridges into the athanor's badges (`Prism.TelemetryBridge`).
  defp emit_schedule_failed(schedule_id, ctx, reason, execution_id \\ nil) do
    :telemetry.execute([:cyfr, :schedules, :failed], %{count: 1}, %{
      schedule_id: schedule_id,
      athanor_id: ctx.athanor_id,
      user_id: ctx.user_id,
      execution_id: execution_id,
      reason: reason
    })
  end

  defp context_of(schedule),
    do: Sanctum.Context.for_scheduled(schedule.user_id, athanor_id: schedule.athanor_id)

  # ---------------------------------------------------------------------------
  # Timers
  # ---------------------------------------------------------------------------

  # A retry after a failure waits 30 s plus a little noise, so nodes that
  # failed together do not fire together.
  defp retry_later(schedule_id, state) do
    arm(schedule_id, {:fire, schedule_id}, @recheck_ms + jitter_ms(@recheck_ms), state)
  end

  defp recheck_later(schedule_id, state) do
    arm(schedule_id, {:fire, schedule_id}, @recheck_ms + jitter_ms(@recheck_ms), state)
  end

  defp arm(schedule_id, message, delay_ms, state) do
    state = cancel_timer(schedule_id, state)
    timer_ref = Process.send_after(self(), message, delay_ms)
    %{state | timers: Map.put(state.timers, schedule_id, timer_ref)}
  end

  # Up to a tenth of the delay, capped at 30 s: schedules that share a
  # minute boundary spread instead of landing on the same tick.
  defp jitter_ms(delay_ms) do
    case min(30_000, div(delay_ms, 10)) do
      spread when spread > 0 -> :rand.uniform(spread)
      _ -> 0
    end
  end

  defp node_name, do: Atom.to_string(node())

  # The timer for the row's cursor. A cursor in the past fires at once;
  # one beyond the longest timer is looked at again later.
  defp schedule_timer(schedule_id, state) do
    state = cancel_timer(schedule_id, state)

    case CronSchedule.get_for_daemon(schedule_id) do
      {:error, :database_error} ->
        retry_later(schedule_id, state)

      {:ok, %{status: "active", next_run_at: %DateTime{} = next_run}} ->
        delay_ms = max(DateTime.diff(next_run, DateTime.utc_now(), :millisecond), 0)

        if delay_ms > @max_timer_ms,
          do: arm(schedule_id, {:recheck, schedule_id}, @max_timer_ms, state),
          else: arm(schedule_id, {:fire, schedule_id}, delay_ms + jitter_ms(delay_ms), state)

      {:ok, %{status: "active"} = schedule} ->
        # No cursor: one is derived from the expression, or the schedule
        # is orphaned until an update touches it — counted where
        # operators look.
        case compute_next_run(schedule.cron_expression) do
          {:ok, next_run} ->
            delay_ms = max(DateTime.diff(next_run, DateTime.utc_now(), :millisecond), 0)
            arm(schedule_id, {:fire, schedule_id}, delay_ms + jitter_ms(delay_ms), state)

          {:error, reason} ->
            Logger.warning("[Schedules] cannot schedule #{schedule_id}: #{reason}")
            timer_failed(schedule_id, reason)
            state
        end

      _ ->
        state
    end
  rescue
    e in @db_timer_errors ->
      Logger.warning(
        "[Schedules] schedule_timer #{schedule_id} failed (#{Exception.message(e)}), retrying in 30s"
      )

      timer_failed(schedule_id, Exception.message(e))
      retry_later(schedule_id, state)
  catch
    :exit, reason ->
      Logger.warning(
        "[Schedules] schedule_timer #{schedule_id} exited (#{inspect(reason)}), retrying in 30s"
      )

      retry_later(schedule_id, state)
  end

  defp timer_failed(schedule_id, reason) do
    :telemetry.execute([:cyfr, :schedules, :scheduler, :timer_failed], %{count: 1}, %{
      schedule_id: schedule_id,
      reason: reason
    })
  end

  defp cancel_timer(schedule_id, state) do
    case Map.get(state.timers, schedule_id) do
      nil ->
        state

      timer_ref ->
        Process.cancel_timer(timer_ref)
        %{state | timers: Map.delete(state.timers, schedule_id)}
    end
  end

  defp cancel_all_timers(state) do
    Enum.each(state.timers, fn {_id, ref} -> Process.cancel_timer(ref) end)
    %{state | timers: %{}}
  end

  defp compute_next_run(cron_expression) do
    case Cron.parse(cron_expression) do
      {:ok, parsed} -> Cron.next_run(parsed, DateTime.utc_now())
      error -> error
    end
  end

  defp decode_json(nil), do: {:ok, %{}}
  defp decode_json(""), do: {:ok, %{}}

  defp decode_json(json) when is_binary(json) do
    case Cyfr.Json.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :invalid_json}
    end
  end

  defp broadcast_update(ctx) do
    case Phoenix.PubSub.broadcast(Emissary.PubSub, Cyfr.Bus.schedules(ctx), :schedules_updated) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Schedules] PubSub broadcast failed: #{inspect(reason)}")
    end
  end
end
