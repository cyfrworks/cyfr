# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.CronScheduler do
  @moduledoc """
  OTP-native cron scheduler for recurring WASM component execution.

  Uses `Process.send_after/3` for timer management. Skips missed runs on
  restart — only computes next future run. Prevents overlapping executions
  of the same schedule.
  """

  use GenServer
  require Logger
  require Arca.Repo.Errors

  # Pre-compute rescue lists (rescue clauses require compile-time lists)
  @db_load_errors Arca.Repo.Errors.db_errors() ++ [DBConnection.OwnershipError, RuntimeError]
  @db_fire_errors Arca.Repo.Errors.db_errors() ++ [DBConnection.OwnershipError]
  @db_timer_errors Arca.Repo.Errors.db_errors() ++ [DBConnection.OwnershipError, ArgumentError]

  # A claim must outlive the longest execution a schedule may run, or a
  # still-running fire loses its claim and another node picks the schedule up
  # and fires it again. This was a flat 900s while the platform ceiling
  # permits a 30-minute timeout (`Sanctum.Policy.Ceiling`), so any schedule
  # running past 15 minutes was double-fireable on a multi-node deployment —
  # single-node was saved only by the in-memory `running` set.
  #
  # Derived from the ceiling, plus headroom for the semaphore wait and the
  # record write that bracket the execution itself, so raising the ceiling
  # cannot silently reintroduce the gap.
  @claim_headroom_seconds 300
  def claim_ttl_seconds do
    ceiling_timeout_seconds() + @claim_headroom_seconds
  end

  defp ceiling_timeout_seconds do
    case Sanctum.Policy.Ceiling.platform_ceiling() do
      %{timeout: timeout} ->
        case Sanctum.Limits.parse_duration(timeout) do
          {:ok, ms} -> div(ms, 1000)
          # An unparseable ceiling is a bug upstream; take the widest value
          # the ceiling could mean rather than a claim that expires early.
          _ -> 30 * 60
        end

      _ ->
        30 * 60
    end
  end

  @max_timer_ms 60 * 60 * 1_000

  def start_link(opts \\ []) do
    # The scheduler is a long-lived process that queries on boot and on
    # timers. Under the test sandbox it gets lent a test's connection and
    # then keeps using it after that test's owner exits, which tears down
    # the pooled connection and fails whichever test runs next — a flake
    # that lands nowhere near its cause. Its own suite starts it
    # explicitly; nothing else needs it running.
    if Application.get_env(:cyfr, :cron_scheduler_enabled, true) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :ignore
    end
  end

  # Public API

  def add(schedule_id), do: GenServer.cast(__MODULE__, {:add, schedule_id})
  def remove(schedule_id), do: GenServer.cast(__MODULE__, {:remove, schedule_id})
  def pause(schedule_id), do: GenServer.cast(__MODULE__, {:pause, schedule_id})
  def resume(schedule_id), do: GenServer.cast(__MODULE__, {:resume, schedule_id})

  def update(schedule_id) do
    GenServer.cast(__MODULE__, {:update, schedule_id})
  end

  def reload, do: GenServer.cast(__MODULE__, :reload)

  # GenServer callbacks

  @impl true
  @max_load_retries 5

  def init(_opts) do
    Process.flag(:trap_exit, true)
    state = %{timers: %{}, running: MapSet.new(), tasks: %{}, load_retry_count: 0}
    {:ok, state, {:continue, :load_schedules}}
  end

  @impl true
  def handle_continue(:load_schedules, state) do
    state = load_all_schedules(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:add, schedule_id}, state) do
    {:noreply, schedule_timer(schedule_id, state)}
  end

  @impl true
  def handle_cast({:remove, schedule_id}, state) do
    {:noreply, cancel_timer(schedule_id, state)}
  end

  @impl true
  def handle_cast({:pause, schedule_id}, state) do
    {:noreply, cancel_timer(schedule_id, state)}
  end

  @impl true
  def handle_cast({:resume, schedule_id}, state) do
    {:noreply, schedule_timer(schedule_id, state)}
  end

  @impl true
  def handle_cast({:update, schedule_id}, state) do
    state = cancel_timer(schedule_id, state)
    {:noreply, schedule_timer(schedule_id, state)}
  end

  @impl true
  def handle_cast(:reload, state) do
    state = cancel_all_timers(state)
    state = load_all_schedules(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:fire, schedule_id}, state) do
    state = %{state | timers: Map.delete(state.timers, schedule_id)}

    if MapSet.member?(state.running, schedule_id) do
      Logger.debug("[CronScheduler] skipping #{schedule_id} (already running)")
      {:noreply, schedule_timer(schedule_id, state)}
    else
      state = fire_schedule(schedule_id, state)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:recheck, schedule_id}, state) do
    state = %{state | timers: Map.delete(state.timers, schedule_id)}
    {:noreply, schedule_timer(schedule_id, state)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.tasks, fn {_id, task_ref} -> task_ref == ref end) do
      {schedule_id, _} ->
        state = %{
          state
          | running: MapSet.delete(state.running, schedule_id),
            tasks: Map.delete(state.tasks, schedule_id)
        }

        # The firing is over either way; the claim goes back.
        Arca.CronSchedule.release_claim(schedule_id, node_name())

        # Look up schedule for tenant context
        schedule =
          case Arca.CronSchedule.get_for_daemon(schedule_id) do
            {:ok, row} -> row
            {:error, _} -> nil
          end

        ctx =
          if schedule do
            Sanctum.Context.for_scheduled(schedule.user_id, athanor_id: schedule.athanor_id)
          end

        if failed_run?(reason) do
          Logger.warning(
            "[CronScheduler] schedule #{schedule_id} execution failed: #{inspect(reason)}"
          )

          if ctx do
            case Arca.CronSchedule.record_error(ctx, schedule_id, inspect(reason)) do
              {:ok, _} ->
                :ok

              {:error, err} ->
                Logger.warning(
                  "[CronScheduler] failed to record_error for #{schedule_id}: #{inspect(err)}"
                )

                :telemetry.execute(
                  [:cyfr, :opus, :cron_scheduler, :record_error_failed],
                  %{count: 1},
                  %{
                    schedule_id: schedule_id,
                    error: err
                  }
                )
            end
          end
        end

        if ctx, do: broadcast_update(ctx)
        {:noreply, schedule_timer(schedule_id, state)}

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:retry_load, state) do
    if state.load_retry_count >= @max_load_retries do
      Logger.error(
        "[CronScheduler] max retries (#{@max_load_retries}) exhausted loading schedules — retrying in 5 minutes"
      )

      :telemetry.execute([:cyfr, :opus, :cron_scheduler, :load_failed], %{count: 1}, %{
        retries: state.load_retry_count
      })

      Process.send_after(self(), :retry_load, 300_000)
      {:noreply, state}
    else
      state = load_all_schedules(state)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.timers, fn {_id, ref} -> Process.cancel_timer(ref) end)

    if MapSet.size(state.running) > 0 do
      ids = state.running |> MapSet.to_list() |> Enum.join(", ")
      Logger.info("[CronScheduler] shutting down with running schedules: #{ids}")
    end

    :ok
  end

  # Private helpers

  defp load_all_schedules(state) do
    case Arca.CronSchedule.active_schedules() do
      # The storage layer already logged the fault; ride the same backoff
      # the raise path below uses.
      {:error, :database_error} ->
        load_retry(state, "storage unavailable")

      {:ok, schedules} ->
        do_load_all_schedules(state, schedules)
    end
  rescue
    e in @db_load_errors ->
      # Ownership errors are expected during test sandbox teardown — log at
      # warning, not error.
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
      "[CronScheduler] failed to load schedules (#{why}), retry #{retry_count}/#{@max_load_retries} in #{delay_ms}ms"
    )

    Process.send_after(self(), :retry_load, delay_ms)
    %{state | load_retry_count: retry_count}
  end

  defp do_load_all_schedules(state, schedules) do
    Logger.info("[CronScheduler] loading #{length(schedules)} active schedule(s)")

    state = Enum.reduce(schedules, state, &load_one_schedule/2)

    # Reset retry counter on successful load
    %{state | load_retry_count: 0}
  end

  # Guarded per schedule: a raise mid-reduce used to unwind the whole load
  # into the outer rescue, discarding the accumulated state and with it the
  # refs of every timer already created — untracked timers that still fire
  # and can never be cancelled. One bad schedule now logs and the rest keep
  # their timers.
  defp load_one_schedule(schedule, acc) do
    # Recompute next_run from now (skip missed runs)
    case compute_next_run(schedule.cron_expression) do
      {:ok, next_run} ->
        ctx =
          Sanctum.Context.for_scheduled(schedule.user_id, athanor_id: schedule.athanor_id)

        case Arca.CronSchedule.update(ctx, schedule.id, %{next_run_at: next_run}) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[CronScheduler] failed to update next_run_at for #{schedule.id}: #{inspect(reason)}"
            )
        end

        schedule_timer(schedule.id, acc)

      {:error, reason} ->
        Logger.warning("[CronScheduler] invalid cron for schedule #{schedule.id}: #{reason}")
        acc
    end
  rescue
    e ->
      Logger.warning(
        "[CronScheduler] failed to load schedule #{schedule.id}: #{Exception.message(e)}"
      )

      :telemetry.execute([:cyfr, :opus, :cron_scheduler, :timer_failed], %{count: 1}, %{
        schedule_id: schedule.id,
        reason: Exception.message(e)
      })

      acc
  catch
    :exit, reason ->
      Logger.warning(
        "[CronScheduler] failed to load schedule #{schedule.id}: exited #{inspect(reason)}"
      )

      :telemetry.execute([:cyfr, :opus, :cron_scheduler, :timer_failed], %{count: 1}, %{
        schedule_id: schedule.id,
        reason: inspect(reason)
      })

      acc
  end

  defp fire_schedule(schedule_id, state) do
    case Arca.CronSchedule.get_for_daemon(schedule_id) do
      {:error, :not_found} ->
        state

      {:error, :database_error} ->
        retry_later(schedule_id, state)

      {:ok, %{status: "active"} = schedule} ->
        ctx =
          Sanctum.Context.for_scheduled(schedule.user_id, athanor_id: schedule.athanor_id)

        if not Sanctum.Tenancy.channel_active?(schedule.athanor_id, schedule.user_id) do
          # The athanor is archived or the creator was denied on this server —
          # skip the run and record why, but never auto-delete: the members
          # who remain decide the schedule's fate.
          Logger.warning(
            "[CronScheduler] schedule #{schedule_id} athanor #{schedule.athanor_id} or " <>
              "creator #{inspect(schedule.user_id)} no longer active — skipping run"
          )

          case Arca.CronSchedule.record_error(
                 ctx,
                 schedule_id,
                 "Athanor or creator no longer active — run skipped"
               ) do
            {:ok, _} ->
              :ok

            {:error, err} ->
              Logger.warning(
                "[CronScheduler] failed to record_error for #{schedule_id}: #{inspect(err)}"
              )
          end

          # Announced like the other two pre-execution skips (unresolved
          # reference, invalid input). This event is what reaches the
          # athanor's tray, so without it a schedule simply stopped firing
          # after an archive with nothing anywhere to say so.
          emit_schedule_failed(schedule_id, ctx, "athanor_or_creator_inactive")

          schedule_timer(schedule_id, state)
        else
          fire_active_schedule(schedule_id, schedule, ctx, state)
        end

      {:ok, _other_status} ->
        state
    end
  rescue
    e in @db_fire_errors ->
      Logger.warning(
        "[CronScheduler] fire_schedule #{schedule_id} failed (#{Exception.message(e)}), retrying in 30s"
      )

      :telemetry.execute([:cyfr, :opus, :cron_scheduler, :fire_failed], %{count: 1}, %{
        schedule_id: schedule_id
      })

      retry_later(schedule_id, state)
  catch
    :exit, reason ->
      Logger.warning(
        "[CronScheduler] fire_schedule #{schedule_id} exited (#{inspect(reason)}), retrying in 30s"
      )

      retry_later(schedule_id, state)
  end

  defp fire_active_schedule(schedule_id, schedule, ctx, state) do
    case schedule.resolved_reference do
      nil ->
        Logger.error(
          "[CronScheduler] schedule #{schedule_id} has no resolved_reference. " <>
            "Cannot execute with unresolved reference '#{schedule.reference}'. " <>
            "Re-create or update the schedule to pin a resolved version."
        )

        emit_schedule_failed(schedule_id, ctx, :unresolved_reference)

        case Arca.CronSchedule.record_error(
               ctx,
               schedule_id,
               "No resolved reference — re-create or update the schedule"
             ) do
          {:ok, _} ->
            :ok

          {:error, err} ->
            Logger.warning(
              "[CronScheduler] failed to record_error for #{schedule_id}: #{inspect(err)}"
            )

            :telemetry.execute(
              [:cyfr, :opus, :cron_scheduler, :record_error_failed],
              %{count: 1},
              %{
                schedule_id: schedule_id,
                error: err
              }
            )
        end

        # Skip execution but allow timer rescheduling below
        schedule_timer(schedule_id, state)

      exec_reference ->
        case decode_json(schedule.input) do
          {:error, :invalid_json} ->
            Logger.error(
              "[CronScheduler] schedule #{schedule_id} has invalid JSON input, skipping execution"
            )

            emit_schedule_failed(schedule_id, ctx, :invalid_input)

            case Arca.CronSchedule.record_error(ctx, schedule_id, "Invalid JSON input") do
              {:ok, _} ->
                :ok

              {:error, err} ->
                Logger.warning(
                  "[CronScheduler] failed to record_error for #{schedule_id}: #{inspect(err)}"
                )

                :telemetry.execute(
                  [:cyfr, :opus, :cron_scheduler, :record_error_failed],
                  %{count: 1},
                  %{schedule_id: schedule_id, error: err}
                )
            end

            schedule_timer(schedule_id, state)

          {:ok, input} ->
            case Arca.CronSchedule.claim(schedule_id, node_name(), claim_ttl_seconds()) do
              {:error, :database_error} ->
                retry_later(schedule_id, state)

              :held ->
                # Another node holds this firing; take the next one.
                Logger.debug(
                  "[CronScheduler] schedule #{schedule_id} claimed elsewhere — skipping"
                )

                schedule_timer(schedule_id, state)

              :claimed ->
                run_claimed_schedule(schedule_id, schedule, ctx, exec_reference, input, state)
            end
        end
    end
  end

  defp run_claimed_schedule(schedule_id, schedule, ctx, exec_reference, input, state) do
    execution_id = Opus.ExecutionRecord.generate_id()

    # Record execution start on schedule
    case Arca.CronSchedule.record_run(ctx, schedule_id, execution_id) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[CronScheduler] failed to record_run for #{schedule_id}: #{inspect(reason)}"
        )
    end

    # Compute and persist next_run_at
    case compute_next_run(schedule.cron_expression) do
      {:ok, next_run} ->
        case Arca.CronSchedule.update(ctx, schedule_id, %{next_run_at: next_run}) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[CronScheduler] failed to update next_run_at for #{schedule_id}: #{inspect(reason)}"
            )
        end

      _ ->
        :ok
    end

    # Spawn monitored task
    logger_metadata = Cyfr.LoggerContext.capture()

    case Task.Supervisor.start_child(Opus.TaskSupervisor, fn ->
           Cyfr.LoggerContext.restore(logger_metadata)

           case Registry.register(Opus.ExecutionRegistry, execution_id, :running) do
             {:ok, _} ->
               :ok

             {:error, reg_err} ->
               Logger.warning(
                 "[CronScheduler] failed to register execution #{execution_id}: #{inspect(reg_err)}"
               )
           end

           request_id = Cyfr.UUID7.request_id()
           ctx = %{ctx | request_id: request_id}

           Emissary.MCP.RequestLog.safe_log_started(ctx, request_id, %{
             tool: "schedule",
             action: "fire",
             method: "cron/fire",
             input: %{
               schedule_id: schedule_id,
               reference: exec_reference,
               input: input
             }
           })

           start_native = System.monotonic_time()

           :telemetry.execute(
             [:cyfr, :opus, :schedule, :fired],
             %{system_time: System.system_time()},
             %{
               request_id: request_id,
               schedule_id: schedule_id,
               reference: exec_reference,
               execution_id: execution_id,
               athanor_id: ctx.athanor_id,
               user_id: ctx.user_id
             }
           )

           # A schedule fires under its bound profile's consent —
           # the binding is enforced at create/update and by the
           # NOT NULL column.
           # Through the port for the same reason the MCP ingress is: one
           # door into "start a root", whoever is knocking.
           run_result =
             Cyfr.Execution.run_root(ctx, schedule.profile_id, exec_reference, input,
               execution_id: execution_id,
               class: :background
             )

           case run_result do
             {:ok, result} ->
               duration_ms =
                 System.convert_time_unit(
                   System.monotonic_time() - start_native,
                   :native,
                   :millisecond
                 )

               Emissary.MCP.RequestLog.safe_log_completed(ctx, request_id, %{
                 output: Map.get(result, :output, result),
                 duration_ms: duration_ms,
                 routed_to: "opus"
               })

               Logger.debug("[CronScheduler] schedule #{schedule_id} completed (#{execution_id})")

             {:error, reason} ->
               duration_ms =
                 System.convert_time_unit(
                   System.monotonic_time() - start_native,
                   :native,
                   :millisecond
                 )

               Emissary.MCP.RequestLog.safe_log_failed(ctx, request_id, %{
                 error: inspect(reason),
                 duration_ms: duration_ms,
                 routed_to: "opus"
               })

               Logger.warning(
                 "[CronScheduler] schedule #{schedule_id} failed: #{inspect(reason)}"
               )

               emit_schedule_failed(schedule_id, ctx, reason, execution_id)

               case Arca.CronSchedule.record_error(ctx, schedule_id, inspect(reason)) do
                 {:ok, _} ->
                   :ok

                 {:error, err} ->
                   Logger.warning(
                     "[CronScheduler] failed to record_error for #{schedule_id}: #{inspect(err)}"
                   )

                   :telemetry.execute(
                     [:cyfr, :opus, :cron_scheduler, :record_error_failed],
                     %{count: 1},
                     %{schedule_id: schedule_id, error: err}
                   )
               end
           end
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        broadcast_update(ctx)

        %{
          state
          | running: MapSet.put(state.running, schedule_id),
            tasks: Map.put(state.tasks, schedule_id, ref)
        }

      {:error, reason} ->
        Logger.error(
          "[CronScheduler] failed to spawn task for schedule #{schedule_id}: #{inspect(reason)}"
        )

        Arca.CronSchedule.release_claim(schedule_id, node_name())
        emit_schedule_failed(schedule_id, ctx, {:spawn_failed, reason})

        case Arca.CronSchedule.record_error(
               ctx,
               schedule_id,
               "spawn_failed: #{inspect(reason)}"
             ) do
          {:ok, _} ->
            :ok

          {:error, err} ->
            Logger.warning(
              "[CronScheduler] failed to record_error for #{schedule_id}: #{inspect(err)}"
            )

            :telemetry.execute(
              [:cyfr, :opus, :cron_scheduler, :record_error_failed],
              %{count: 1},
              %{schedule_id: schedule_id, error: err}
            )
        end

        schedule_timer(schedule_id, state)
    end
  rescue
    e in @db_fire_errors ->
      Logger.warning(
        "[CronScheduler] fire_schedule #{schedule_id} failed (#{Exception.message(e)}), retrying in 30s"
      )

      :telemetry.execute([:cyfr, :opus, :cron_scheduler, :fire_failed], %{count: 1}, %{
        schedule_id: schedule_id,
        athanor_id: ctx.athanor_id,
        user_id: ctx.user_id
      })

      # The claim may already be ours (a raise between :claimed and the
      # spawn), and it is not holder-re-entrant: leaked, the 30s retry and
      # every fire after it answer :held until the TTL (~35 min) lapses.
      # The release is CAS'd on the holder, so releasing an unheld claim
      # is a no-op.
      Arca.CronSchedule.release_claim(schedule_id, node_name())

      emit_schedule_failed(schedule_id, ctx, {:db, Exception.message(e)})
      retry_later(schedule_id, state)
  catch
    :exit, reason ->
      Logger.warning(
        "[CronScheduler] fire_schedule #{schedule_id} exited (#{inspect(reason)}), retrying in 30s"
      )

      Arca.CronSchedule.release_claim(schedule_id, node_name())
      retry_later(schedule_id, state)
  end

  # A schedule that could not run, or ran and failed: one event the tray
  # bridges into the athanor's badges (`Prism.TelemetryBridge`), beside the
  # scheduler-internal `fire_failed`. The athanor is always known here.
  @doc false
  # Whether a task's exit reason means the run failed.
  #
  # `:noproc` does not: the task is monitored a moment AFTER it is spawned, so
  # one that finished inside that window makes the monitor fire immediately
  # with `:noproc` — the run succeeded and was simply over first. Reading any
  # non-`:normal` reason as a failure wrote `record_error(":noproc")` onto
  # rows whose run had just completed, and fast-failing schedules (a bad
  # reference, a denied consent — the ones that return quickest) collected a
  # phantom second error every time. `:shutdown` is the scheduler's own
  # teardown, not the schedule's.
  @spec failed_run?(term()) :: boolean()
  def failed_run?(:normal), do: false
  def failed_run?(:noproc), do: false
  def failed_run?(:shutdown), do: false
  def failed_run?({:shutdown, _}), do: false
  def failed_run?(_reason), do: true

  defp emit_schedule_failed(schedule_id, ctx, reason, execution_id \\ nil) do
    :telemetry.execute([:cyfr, :opus, :schedule, :failed], %{count: 1}, %{
      schedule_id: schedule_id,
      athanor_id: ctx.athanor_id,
      user_id: ctx.user_id,
      execution_id: execution_id,
      reason: reason
    })
  end

  # A retry after a failure waits 30 s plus a little noise, so nodes that
  # failed together do not fire together.
  defp retry_later(schedule_id, state) do
    timer_ref = Process.send_after(self(), {:fire, schedule_id}, 30_000 + jitter_ms(30_000))
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

  defp schedule_timer(schedule_id, state) do
    # Cancel existing timer if any
    state = cancel_timer(schedule_id, state)

    case Arca.CronSchedule.get_for_daemon(schedule_id) do
      # A row the store could not answer for must be retried — silently
      # dropping the timer would orphan the schedule until restart.
      {:error, :database_error} ->
        retry_later(schedule_id, state)

      {:ok, %{status: "active"} = schedule} ->
        case compute_next_run(schedule.cron_expression) do
          {:ok, next_run} ->
            delay_ms = max(DateTime.diff(next_run, DateTime.utc_now(), :millisecond), 1_000)

            if delay_ms > @max_timer_ms do
              # Too far out — set a recheck timer
              timer_ref = Process.send_after(self(), {:recheck, schedule_id}, @max_timer_ms)
              %{state | timers: Map.put(state.timers, schedule_id, timer_ref)}
            else
              timer_ref =
                Process.send_after(self(), {:fire, schedule_id}, delay_ms + jitter_ms(delay_ms))

              %{state | timers: Map.put(state.timers, schedule_id, timer_ref)}
            end

          {:error, reason} ->
            # No timer means the schedule is orphaned until a restart or an
            # update touches this row — not silent: counted where operators
            # look, beside the other timer failures.
            Logger.warning("[CronScheduler] cannot schedule #{schedule_id}: #{reason}")

            :telemetry.execute([:cyfr, :opus, :cron_scheduler, :timer_failed], %{count: 1}, %{
              schedule_id: schedule_id,
              reason: reason
            })

            state
        end

      _ ->
        state
    end
  rescue
    e in @db_timer_errors ->
      Logger.warning(
        "[CronScheduler] schedule_timer #{schedule_id} failed (#{Exception.message(e)}), retrying in 30s"
      )

      :telemetry.execute([:cyfr, :opus, :cron_scheduler, :timer_failed], %{count: 1}, %{
        schedule_id: schedule_id
      })

      retry_later(schedule_id, state)
  catch
    :exit, reason ->
      Logger.warning(
        "[CronScheduler] schedule_timer #{schedule_id} exited (#{inspect(reason)}), retrying in 30s"
      )

      retry_later(schedule_id, state)
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
    case Opus.CronParser.parse(cron_expression) do
      {:ok, parsed} -> Opus.CronParser.next_run(parsed, DateTime.utc_now())
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
    topic = Cyfr.Topics.schedules(ctx)

    case Phoenix.PubSub.broadcast(Emissary.PubSub, topic, :schedules_updated) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[CronScheduler] PubSub broadcast failed: #{inspect(reason)}")
    end
  end
end
