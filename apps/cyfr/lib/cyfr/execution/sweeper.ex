# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Sweeper do
  @moduledoc """
  Periodic sweep to mark stale "running" executions as failed.

  Runs every 60 seconds, checking for execution records still "running"
  whose lease has lapsed. A running row is leased by the node executing it
  (`execution_attempts.runner_id`, `lease_until`) and the executor renews the lease
  while the work runs; a lapsed lease means the runner stopped renewing —
  crashed, or a whole node gone. This handles:

  - Process crashes that bypass cleanup code
  - BEAM restarts
  - Another node's crash, when several nodes share the database
  - Edge cases where a runner's failure handling couldn't complete

  A lapsed lease held by *this* node is double-checked against the local
  execution registry — a live process is left alone (it will renew).

  A tick sweeps only while this boot owns the control plane
  (`Cyfr.ControlPlane.when_owner/1`). The process starts only when
  `config :cyfr, :execution_sweeper_enabled` is true (the default).
  """

  use GenServer
  require Logger

  alias Cyfr.Execution.{Cascade, Events, Record, Telemetry}

  @sweep_interval_ms 60_000

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
    _ = Cyfr.ControlPlane.when_owner(&sweep/0)
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  @doc false
  def sweep do
    stale =
      try do
        Arca.Execution.list_stale_running(DateTime.utc_now())
      rescue
        e ->
          Logger.error(
            "[Cyfr.Execution.Sweeper] Failed to query stale executions: #{Exception.message(e)}"
          )

          []
      end

    me = Record.runner_id()

    for record <- stale do
      # Another node's lapsed lease is that node's crash; our own is
      # checked against the live process — a running one just renews late.
      should_sweep =
        record.runner_id != me or
          case Registry.lookup(Cyfr.Execution.Registry, record.id) do
            [{pid, _}] -> not Process.alive?(pid)
            _ -> true
          end

      if should_sweep do
        try do
          mark_failed(record)
        rescue
          e ->
            Logger.error(
              "[Cyfr.Execution.Sweeper] Failed to mark #{record.id} as failed: #{Exception.message(e)}"
            )
        end
      end
    end

    :ok
  end

  defp mark_failed(record) do
    now = DateTime.utc_now()
    duration_ms = DateTime.diff(now, record.started_at, :millisecond)
    error_msg = "Execution terminated: runner stopped without cleanup"

    # Fenced on what this sweep observed: the attempt that owns the row and
    # the exact lease it saw lapse. A renewal that landed between the scan
    # and this write changed `lease_until`, and the update matches nothing —
    # a live execution is never failed by a stale observation.
    {count, event_seq} =
      Arca.Execution.mark_failed_if_running(
        record.id,
        %{completed_at: now, duration_ms: duration_ms, error_message: error_msg},
        attempt: record.attempt,
        lease_until: record.lease_until,
        event: "execution.lapsed"
      )

    if count > 0 do
      Logger.info(
        "[Cyfr.Execution.Sweeper] Marked #{record.id} as failed (stale #{duration_ms}ms)"
      )

      Telemetry.row_failed(record, error_msg, duration_ms)

      Events.publish(record.id, record, "execution.lapsed", event_seq, %{
        "status" => "failed",
        "error" => error_msg
      })

      # Cascade to children for executions that run children: formulas
      # and turn roots.
      if record.component_type in ["formula", "agent"] do
        Cascade.fail_children_of(record.id)
      end
    end
  end
end
