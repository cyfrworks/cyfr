# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Sweeper do
  @moduledoc """
  Periodic sweep that lapses running executions whose lease lapsed.

  Runs every 60 seconds. A running row's attempt carries a lease
  (`execution_attempts.lease_until`) that its runner renews while the work
  runs, or that a turn root's keeper renews; a lapsed lease means nothing
  renewed it — the runner or its worker service is gone, a partition
  outlasted the lease, or a boot restarted. Each such execution is lapsed
  (`Cyfr.Execution.Lapse`), wherever it was dispatched, and the attempt
  process still open for it is stopped (`Cyfr.Execution.Attempt.stop_unclosed/2`),
  so its waiter answers the lapsed row.

  A tick sweeps only while this boot owns the control plane
  (`Cyfr.ControlPlane.when_owner/1`). The process starts only when
  `config :cyfr, :execution_sweeper_enabled` is true (the default).
  """

  use GenServer
  require Logger

  alias Cyfr.Execution.{Attempt, Lapse}

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

    for record <- stale do
      if Lapse.lapse(record),
        do:
          Attempt.stop_unclosed(record.attempt, %{
            service_id: record.service_id,
            boot_id: record.boot_id,
            runner: nil
          })
    end

    :ok
  end
end
