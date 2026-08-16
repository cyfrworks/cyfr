# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ExecutionSweeper do
  @moduledoc """
  Periodic sweep to mark stale "running" executions as failed.

  Runs every 60 seconds, checking for execution records stuck in "running"
  state longer than 10 minutes with no live BEAM process. This handles:

  - Process crashes that bypass cleanup code
  - BEAM restarts (replaces the one-shot startup sweep)
  - Edge cases where `handle_failure` couldn't complete
  """

  use GenServer
  require Logger

  alias Opus.ExecutionEventBuffer

  @sweep_interval_ms 60_000
  @stale_threshold_seconds 600

  def start_link(opts \\ []) do
    # Timer-driven DB queries from a permanent process poison the test
    # sandbox (the lent connection outlives its owning test) — same gate
    # as CronScheduler/RetentionScheduler; test config turns it off and
    # the sweep logic is exercised directly.
    if Application.get_env(:cyfr, :execution_sweeper_enabled, true) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :ignore
    end
  end

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("[Opus.ExecutionSweeper] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp sweep do
    cutoff = DateTime.add(DateTime.utc_now(), -@stale_threshold_seconds, :second)

    stale =
      try do
        Arca.Execution.list_stale_running(cutoff)
      rescue
        e ->
          Logger.error(
            "[Opus.ExecutionSweeper] Failed to query stale executions: #{Exception.message(e)}"
          )

          []
      end

    for record <- stale do
      should_sweep =
        case Registry.lookup(Opus.ExecutionRegistry, record.id) do
          [{pid, _}] -> not Process.alive?(pid)
          _ -> true
        end

      if should_sweep do
        try do
          mark_failed(record)
        rescue
          e ->
            Logger.error(
              "[Opus.ExecutionSweeper] Failed to mark #{record.id} as failed: #{Exception.message(e)}"
            )
        end
      end
    end

    :ok
  end

  defp mark_failed(record) do
    now = DateTime.utc_now()
    duration_ms = DateTime.diff(now, record.started_at, :millisecond)
    error_msg = "Execution terminated: process exited without cleanup"

    {count, _} =
      Arca.Execution.mark_failed_if_running(record.id, %{
        completed_at: now,
        duration_ms: duration_ms,
        error_message: error_msg
      })

    if count > 0 do
      Logger.info(
        "[Opus.ExecutionSweeper] Marked #{record.id} as failed (stale #{duration_ms}ms)"
      )

      component_type =
        case Opus.ComponentType.parse(record.component_type) do
          {:ok, t} -> t
          _ -> :reagent
        end

      # Emit telemetry so TelemetryBridge broadcasts to PubSub → LiveView
      :telemetry.execute(
        [:cyfr, :opus, :execute, :exception],
        %{duration: duration_ms * 1_000_000, system_time: System.system_time()},
        %{
          execution_id: record.id,
          request_id: record.request_id,
          component: record.reference,
          reference: record.reference,
          component_type: component_type,
          user_id: record.user_id,
          athanor_id: record.athanor_id,
          outcome: :failure,
          error: error_msg,
          duration_ms: duration_ms
        }
      )

      ExecutionEventBuffer.push_terminal(
        record.id,
        "error",
        %{error: error_msg},
        999_999_999,
        record
      )

      # Cascade to children for formula-type executions
      if record.component_type in ["formula"] do
        Opus.Executor.cascade_children_failure_by_id(record.id)
      end
    end
  end
end
