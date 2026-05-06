defmodule Arca.RetentionScheduler do
  @moduledoc """
  Periodic retention cleanup for Arx mode.

  In Core mode, this GenServer returns `:ignore` and never starts.
  In Arx mode, it runs `Arca.Retention.cleanup_all_executions/2` and
  `Arca.Retention.cleanup_mcp_logs/2` on a configurable interval
  (default 6 hours) to prevent unbounded storage growth.
  """

  use GenServer

  require Logger

  @default_interval_ms :timer.hours(6)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if Sanctum.Edition.arx?() do
      interval = Application.get_env(:cyfr, :retention_scheduler_interval, @default_interval_ms)
      Logger.info("[RetentionScheduler] Starting with interval #{div(interval, 60_000)}m")
      {:ok, %{interval: interval}, {:continue, :first_run}}
    else
      :ignore
    end
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
      case Arca.Retention.cleanup_all_executions(ctx) do
        {:ok, %{users: users, deleted: deleted, errors: []}} ->
          if deleted > 0,
            do:
              Logger.info(
                "[RetentionScheduler] Cleaned #{deleted} executions across #{users} users"
              )

        {:ok, %{users: users, deleted: deleted, errors: errors}} ->
          if deleted > 0,
            do:
              Logger.info(
                "[RetentionScheduler] Cleaned #{deleted} executions across #{users} users"
              )

          for {uid, oid, pid, reason} <- errors do
            Logger.error(
              "[RetentionScheduler] Cleanup failed user=#{uid} org=#{oid} project=#{pid}: #{inspect(reason)}"
            )
          end

        {:ok, _} ->
          :ok
      end
    rescue
      e -> Logger.error("[RetentionScheduler] Execution cleanup crashed: #{Exception.message(e)}")
    end

    try do
      case Arca.Retention.cleanup_mcp_logs(ctx) do
        {:ok, count} when is_integer(count) and count > 0 ->
          Logger.info("[RetentionScheduler] Cleaned #{count} MCP logs")

        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("[RetentionScheduler] MCP log cleanup failed: #{inspect(reason)}")
      end
    rescue
      e -> Logger.error("[RetentionScheduler] MCP log cleanup crashed: #{Exception.message(e)}")
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
          Logger.warning(
            "[RetentionScheduler] Webhook delivery sweep failed: #{inspect(reason)}"
          )
      end
    rescue
      e ->
        Logger.error(
          "[RetentionScheduler] Webhook delivery sweep crashed: #{Exception.message(e)}"
        )
    end
  end
end
