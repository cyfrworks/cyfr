# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RetentionScheduler do
  @moduledoc """
  Periodic retention cleanup, enabled when retention is configured.

  When retention is disabled, this GenServer returns `:ignore` and never
  starts. When enabled, it runs `Cyfr.Retention.cleanup_all_executions/2`
  and `Cyfr.Retention.cleanup_mcp_logs/2` on a configurable interval
  (default 6 hours) to prevent unbounded storage growth.
  """

  use GenServer

  require Logger

  @default_interval_ms :timer.hours(6)

  def start_link(opts \\ []) do
    if Application.get_env(:cyfr, :retention_scheduler_enabled, true) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :ignore
    end
  end

  @impl true
  def init(_opts) do
    interval = Application.get_env(:cyfr, :retention_scheduler_interval, @default_interval_ms)
    Logger.info("[RetentionScheduler] Starting with interval #{div(interval, 60_000)}m")
    {:ok, %{interval: interval}, {:continue, :first_run}}
  end

  @impl true
  def handle_continue(:first_run, state) do
    run_cleanup()
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:run_cleanup, state) do
    run_cleanup()
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("#{__MODULE__}: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp schedule(interval) do
    Process.send_after(self(), :run_cleanup, interval)
  end

  defp run_cleanup do
    ctx = Sanctum.system_context()

    try do
      case Cyfr.Retention.cleanup_all_executions(ctx) do
        {:ok, %{tenants: tenants, deleted: deleted, errors: []}} ->
          if deleted > 0,
            do:
              Logger.info(
                "[RetentionScheduler] Cleaned #{deleted} executions across #{tenants} tenants"
              )

        {:ok, %{tenants: tenants, deleted: deleted, errors: errors}} ->
          if deleted > 0,
            do:
              Logger.info(
                "[RetentionScheduler] Cleaned #{deleted} executions across #{tenants} tenants"
              )

          for {athanor_id, reason} <- errors do
            Logger.error(
              "[RetentionScheduler] Cleanup failed athanor=#{athanor_id}: #{inspect(reason)}"
            )
          end

        {:ok, _} ->
          :ok
      end
    rescue
      e -> Logger.error("[RetentionScheduler] Execution cleanup crashed: #{Exception.message(e)}")
    end

    try do
      case Cyfr.Retention.cleanup_all_logs() do
        {:ok,
         %{
           mcp_logs_deleted: mcp,
           policy_logs_deleted: policy,
           conversations_deleted: conversations,
           errors: errors
         }} ->
          if mcp + policy + conversations > 0,
            do:
              Logger.info(
                "[RetentionScheduler] Cleaned #{mcp} MCP logs, #{policy} policy logs, " <>
                  "#{conversations} conversations"
              )

          for {athanor_id, kind, reason} <- errors do
            Logger.warning(
              "[RetentionScheduler] #{kind} cleanup failed athanor=#{athanor_id}: " <>
                inspect(reason)
            )
          end
      end
    rescue
      e -> Logger.error("[RetentionScheduler] Log cleanup crashed: #{Exception.message(e)}")
    end

    sweep_webhook_deliveries()
  end

  # Webhook idempotency table sweep. Default TTL 24h — webhook senders that
  # retry beyond this window cannot rely on idempotency, but in practice
  # senders give up well before that.
  defp sweep_webhook_deliveries do
    ttl = Application.get_env(:cyfr, :webhook_idempotency_ttl_seconds, 86_400)
    cutoff = DateTime.utc_now() |> DateTime.add(-ttl, :second)

    try do
      case Arca.WebhookDeliveryStorage.sweep(cutoff) do
        {:ok, count} when count > 0 ->
          Logger.info("[RetentionScheduler] Cleaned #{count} webhook delivery records")

        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("[RetentionScheduler] Webhook delivery sweep failed: #{inspect(reason)}")
      end
    rescue
      e ->
        Logger.error(
          "[RetentionScheduler] Webhook delivery sweep crashed: #{Exception.message(e)}"
        )
    end
  end
end
