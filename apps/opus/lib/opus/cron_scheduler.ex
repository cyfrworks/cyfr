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

  # A claim outlives the longest execution a schedule may run; a claimant
  # that dies frees the schedule for the other nodes once this lapses.
  @claim_ttl_seconds 900

  @max_timer_ms 60 * 60 * 1_000
  @pubsub_topic "schedules"

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
      Logger.debug("CronScheduler: skipping #{schedule_id} (already running)")
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
        schedule = Arca.CronSchedule.get_for_daemon(schedule_id)

        ctx =
          if schedule do
            Sanctum.Context.for_scheduled(schedule.user_id, athanor_id: schedule.athanor_id)
          end

        if reason != :normal do
          Logger.warning(
            "CronScheduler: schedule #{schedule_id} execution failed: #{inspect(reason)}"
          )

          if ctx do
            case Arca.CronSchedule.record_error(ctx, schedule_id, inspect(reason)) do
              {:ok, _} ->
                :ok

              {:error, err} ->
                Logger.warning(
                  "CronScheduler: failed to record_error for #{schedule_id}: #{inspect(err)}"
                )

                :telemetry.execute([:cyfr, :cron_scheduler, :record_error_failed], %{count: 1}, %{
                  schedule_id: schedule_id,
                  error: err
                })
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
        "CronScheduler: max retries (#{@max_load_retries}) exhausted loading schedules — retrying in 5 minutes"
      )

      :telemetry.execute([:cyfr, :cron_scheduler, :load_failed], %{count: 1}, %{
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
    Logger.warning("CronScheduler: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.timers, fn {_id, ref} -> Process.cancel_timer(ref) end)

    if MapSet.size(state.running) > 0 do
      ids = state.running |> MapSet.to_list() |> Enum.join(", ")
      Logger.info("CronScheduler: shutting down with running schedules: #{ids}")
    end

    :ok
  end

  # Private helpers

  defp load_all_schedules(state) do
    schedules = Arca.CronSchedule.active_schedules()
    Logger.info("CronScheduler: loading #{length(schedules)} active schedule(s)")

    state =
      Enum.reduce(schedules, state, fn schedule, acc ->
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
                  "CronScheduler: failed to update next_run_at for #{schedule.id}: #{inspect(reason)}"
                )
            end

            schedule_timer(schedule.id, acc)

          {:error, reason} ->
            Logger.warning("CronScheduler: invalid cron for schedule #{schedule.id}: #{reason}")
            acc
        end
      end)

    # Reset retry counter on successful load
    %{state | load_retry_count: 0}
  rescue
    e in @db_load_errors ->
      retry_count = state.load_retry_count + 1
      delay_ms = min(5_000 * Integer.pow(2, retry_count - 1), 60_000)

      # Ownership errors are expected during test sandbox teardown — log at warning, not error
      level = if match?(%DBConnection.OwnershipError{}, e), do: :warning, else: :error

      Logger.log(
        level,
        "CronScheduler: failed to load schedules (#{Exception.message(e)}), retry #{retry_count}/#{@max_load_retries} in #{delay_ms}ms"
      )

      Process.send_after(self(), :retry_load, delay_ms)
      %{state | load_retry_count: retry_count}
  catch
    :exit, reason ->
      retry_count = state.load_retry_count + 1
      delay_ms = min(5_000 * Integer.pow(2, retry_count - 1), 60_000)

      Logger.warning(
        "CronScheduler: load_all_schedules exited (#{inspect(reason)}), retry #{retry_count}/#{@max_load_retries} in #{delay_ms}ms"
      )

      Process.send_after(self(), :retry_load, delay_ms)
      %{state | load_retry_count: retry_count}
  end

  defp fire_schedule(schedule_id, state) do
    case Arca.CronSchedule.get_for_daemon(schedule_id) do
      nil ->
        state

      %{status: "active"} = schedule ->
        ctx =
          Sanctum.Context.for_scheduled(schedule.user_id, athanor_id: schedule.athanor_id)

        if not Sanctum.Tenancy.channel_active?(schedule.athanor_id, schedule.user_id) do
          # The athanor is archived or the creator was denied on this server —
          # skip the run and record why, but never auto-delete: the members
          # who remain decide the schedule's fate.
          Logger.warning(
            "CronScheduler: schedule #{schedule_id} athanor #{schedule.athanor_id} or " <>
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
                "CronScheduler: failed to record_error for #{schedule_id}: #{inspect(err)}"
              )
          end

          schedule_timer(schedule_id, state)
        else
          fire_active_schedule(schedule_id, schedule, ctx, state)
        end

      _other ->
        state
    end
  rescue
    e in @db_fire_errors ->
      Logger.warning(
        "CronScheduler: fire_schedule #{schedule_id} failed (#{Exception.message(e)}), retrying in 30s"
      )

      :telemetry.execute([:cyfr, :cron_scheduler, :fire_failed], %{count: 1}, %{
        schedule_id: schedule_id
      })

      retry_later(schedule_id, state)
  catch
    :exit, reason ->
      Logger.warning(
        "CronScheduler: fire_schedule #{schedule_id} exited (#{inspect(reason)}), retrying in 30s"
      )

      retry_later(schedule_id, state)
  end

  defp fire_active_schedule(schedule_id, schedule, ctx, state) do
    case schedule.resolved_reference do
      nil ->
        Logger.error(
          "CronScheduler: schedule #{schedule_id} has no resolved_reference. " <>
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
              "CronScheduler: failed to record_error for #{schedule_id}: #{inspect(err)}"
            )

            :telemetry.execute([:cyfr, :cron_scheduler, :record_error_failed], %{count: 1}, %{
              schedule_id: schedule_id,
              error: err
            })
        end

        # Skip execution but allow timer rescheduling below
        schedule_timer(schedule_id, state)

      exec_reference ->
        case decode_json(schedule.input) do
          {:error, :invalid_json} ->
            Logger.error(
              "CronScheduler: schedule #{schedule_id} has invalid JSON input, skipping execution"
            )

            emit_schedule_failed(schedule_id, ctx, :invalid_input)

            case Arca.CronSchedule.record_error(ctx, schedule_id, "Invalid JSON input") do
              {:ok, _} ->
                :ok

              {:error, err} ->
                Logger.warning(
                  "CronScheduler: failed to record_error for #{schedule_id}: #{inspect(err)}"
                )

                :telemetry.execute(
                  [:cyfr, :cron_scheduler, :record_error_failed],
                  %{count: 1},
                  %{schedule_id: schedule_id, error: err}
                )
            end

            schedule_timer(schedule_id, state)

          {:ok, input} ->
            case Arca.CronSchedule.claim(schedule_id, node_name(), @claim_ttl_seconds) do
              :held ->
                # Another node holds this firing; take the next one.
                Logger.debug(
                  "CronScheduler: schedule #{schedule_id} claimed elsewhere — skipping"
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
          "CronScheduler: failed to record_run for #{schedule_id}: #{inspect(reason)}"
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
              "CronScheduler: failed to update next_run_at for #{schedule_id}: #{inspect(reason)}"
            )
        end

      _ ->
        :ok
    end

    # Spawn monitored task
    case Task.Supervisor.start_child(Opus.TaskSupervisor, fn ->
           case Registry.register(Opus.ExecutionRegistry, execution_id, :running) do
             {:ok, _} ->
               :ok

             {:error, reg_err} ->
               Logger.warning(
                 "CronScheduler: failed to register execution #{execution_id}: #{inspect(reg_err)}"
               )
           end

           request_id = Emissary.UUID7.request_id()
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
           run_result =
             Opus.run_root(ctx, schedule.profile_id, exec_reference, input,
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

               Logger.debug("CronScheduler: schedule #{schedule_id} completed (#{execution_id})")

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

               Logger.warning("CronScheduler: schedule #{schedule_id} failed: #{inspect(reason)}")
               emit_schedule_failed(schedule_id, ctx, reason, execution_id)

               case Arca.CronSchedule.record_error(ctx, schedule_id, inspect(reason)) do
                 {:ok, _} ->
                   :ok

                 {:error, err} ->
                   Logger.warning(
                     "CronScheduler: failed to record_error for #{schedule_id}: #{inspect(err)}"
                   )

                   :telemetry.execute(
                     [:cyfr, :cron_scheduler, :record_error_failed],
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
          "CronScheduler: failed to spawn task for schedule #{schedule_id}: #{inspect(reason)}"
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
              "CronScheduler: failed to record_error for #{schedule_id}: #{inspect(err)}"
            )

            :telemetry.execute(
              [:cyfr, :cron_scheduler, :record_error_failed],
              %{count: 1},
              %{schedule_id: schedule_id, error: err}
            )
        end

        schedule_timer(schedule_id, state)
    end
  rescue
    e in @db_fire_errors ->
      Logger.warning(
        "CronScheduler: fire_schedule #{schedule_id} failed (#{Exception.message(e)}), retrying in 30s"
      )

      :telemetry.execute([:cyfr, :cron_scheduler, :fire_failed], %{count: 1}, %{
        schedule_id: schedule_id,
        athanor_id: ctx.athanor_id,
        user_id: ctx.user_id
      })

      emit_schedule_failed(schedule_id, ctx, {:db, Exception.message(e)})
      retry_later(schedule_id, state)
  catch
    :exit, reason ->
      Logger.warning(
        "CronScheduler: fire_schedule #{schedule_id} exited (#{inspect(reason)}), retrying in 30s"
      )

      retry_later(schedule_id, state)
  end

  # A schedule that could not run, or ran and failed: one event the tray
  # bridges into the athanor's badges (`Prism.TelemetryBridge`), beside the
  # scheduler-internal `fire_failed`. The athanor is always known here.
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
      %{status: "active"} = schedule ->
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
            Logger.warning("CronScheduler: cannot schedule #{schedule_id}: #{reason}")
            state
        end

      _ ->
        state
    end
  rescue
    e in @db_timer_errors ->
      Logger.warning(
        "CronScheduler: schedule_timer #{schedule_id} failed (#{Exception.message(e)}), retrying in 30s"
      )

      :telemetry.execute([:cyfr, :cron_scheduler, :timer_failed], %{count: 1}, %{
        schedule_id: schedule_id
      })

      retry_later(schedule_id, state)
  catch
    :exit, reason ->
      Logger.warning(
        "CronScheduler: schedule_timer #{schedule_id} exited (#{inspect(reason)}), retrying in 30s"
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
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, :invalid_json}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp broadcast_update(ctx) do
    topic = Sanctum.PubSub.topic(@pubsub_topic, ctx)

    case Phoenix.PubSub.broadcast(Emissary.PubSub, topic, :schedules_updated) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[CronScheduler] PubSub broadcast failed: #{inspect(reason)}")
    end
  end
end
