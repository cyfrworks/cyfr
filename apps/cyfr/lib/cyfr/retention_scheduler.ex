# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RetentionScheduler do
  @moduledoc """
  Periodic retention cleanup, enabled when retention is configured.

  When retention is disabled, this GenServer returns `:ignore` and never
  starts. When enabled, each cycle runs `Cyfr.Retention.cleanup_all/1` —
  every kind in `Cyfr.Retention.kinds/0`, every active athanor, each
  inside its own context — plus the declared sweeps below, on a
  configurable interval (default 6 hours) to prevent unbounded storage
  growth. Every step runs behind one crash barrier: a fault in one is
  logged and the cycle moves on.
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
    run_step("retention cleanup", &run_retention/0)

    for {label, fun} <- sweeps(), do: run_step(label, fun)
  end

  # The declared sweep roster — recurring reclaims that are not per-kind
  # retention policy: each is a `{label, fun}` the crash barrier runs.
  defp sweeps do
    [
      {"webhook delivery sweep", &sweep_webhook_deliveries/0},
      {"stale tmp sweep", &sweep_stale_tmp_files/0},
      {"conversation blob orphan sweep", &sweep_conversation_blob_orphans/0},
      {"health probe sweep", &sweep_health_probe_dir/0}
    ]
  end

  # One crash barrier for every step: retention must never take the
  # server down, and one step's fault must not starve the rest.
  defp run_step(label, fun) do
    fun.()
  rescue
    e -> Logger.error("[RetentionScheduler] #{label} crashed: #{Exception.message(e)}")
  end

  defp run_retention do
    {:ok, %{tenants: tenants, deleted: deleted, errors: errors}} = Cyfr.Retention.cleanup_all()

    cleaned = for {kind, count} <- deleted, count > 0, do: "#{count} #{kind}"

    if cleaned != [] do
      Logger.info(
        "[RetentionScheduler] Cleaned #{Enum.join(cleaned, ", ")} across #{tenants} tenants"
      )
    end

    for {athanor_id, kind, reason} <- errors do
      Logger.warning(
        "[RetentionScheduler] #{kind} cleanup failed athanor=#{athanor_id}: #{inspect(reason)}"
      )
    end
  end

  # The storage readiness probe overwrites one fixed key and cleans up
  # after itself; this belt reclaims anything a failed delete (or the old
  # per-probe naming scheme) stranded. A racing probe's in-flight key may
  # go with it — the probe treats that delete race as success. The writer
  # owns the spelling of where it writes.
  defp sweep_health_probe_dir do
    case Arca.delete_tree(Sanctum.system_context(), EmissaryWeb.HealthController.probe_dir()) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[RetentionScheduler] Health-probe sweep failed: #{inspect(reason)}")
    end
  end

  # Conversation blob dirs no row backs (a blob delete that failed after
  # its rows were reclaimed) — swept so the bytes stop counting against
  # the athanor's storage cap forever.
  defp sweep_conversation_blob_orphans do
    case Cyfr.Retention.sweep_conversation_blob_orphans() do
      {:ok, %{dirs_deleted: 0, errors: []}} ->
        :ok

      {:ok, %{dirs_deleted: deleted, tenants: tenants, errors: errors}} ->
        if deleted > 0 do
          Logger.info(
            "[RetentionScheduler] Reclaimed #{deleted} orphaned conversation blob dirs " <>
              "across #{tenants} tenants"
          )
        end

        for {athanor_id, reason} <- errors do
          Logger.warning(
            "[RetentionScheduler] Blob orphan sweep failed athanor=#{athanor_id}: #{inspect(reason)}"
          )
        end

        :ok
    end
  end

  # Orphaned atomic-write temp files are an adapter artifact; the facade
  # asks whichever adapter is configured, and one with nothing to reclaim
  # answers zero.
  defp sweep_stale_tmp_files do
    case Arca.sweep_stale_tmp() do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info("[RetentionScheduler] Removed #{count} stale temp files")

      {:error, reason} ->
        Logger.warning("[RetentionScheduler] Temp sweep failed: #{inspect(reason)}")
    end
  end

  # Webhook idempotency table sweep. Default TTL 24h — webhook senders that
  # retry beyond this window cannot rely on idempotency, but in practice
  # senders give up well before that.
  defp sweep_webhook_deliveries do
    ttl = Application.get_env(:cyfr, :webhook_idempotency_ttl_seconds, 86_400)
    cutoff = DateTime.utc_now() |> DateTime.add(-ttl, :second)

    case Arca.WebhookDeliveryStorage.sweep(cutoff) do
      {:ok, count} when count > 0 ->
        Logger.info("[RetentionScheduler] Cleaned #{count} webhook delivery records")

      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[RetentionScheduler] Webhook delivery sweep failed: #{inspect(reason)}")
    end
  end
end
