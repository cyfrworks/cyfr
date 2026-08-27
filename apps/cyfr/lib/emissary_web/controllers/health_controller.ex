# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.HealthController do
  @moduledoc """
  Health check endpoints for load balancers and monitoring.

  - `/api/health` — liveness probe (always 200)
  - `/api/health/ready` — readiness probe (checks DB + cache)
  """

  use EmissaryWeb, :controller

  require Logger

  def check(conn, _params) do
    json(conn, %{status: "ok", service: "emissary"})
  end

  # Probes from several monitors collapse onto one real check per window;
  # the DB query, PubSub round-trip and storage write are not free (on the
  # S3 adapter the write probe is a billable PUT per uncached hit).
  # Operators on an object store can lengthen the window without a
  # release via `config :cyfr, :health_ready_cache_ms`.
  @default_ready_cache_ms 5_000
  @ready_cache_key {__MODULE__, :ready_cache}

  defp ready_cache_ms,
    do: Application.get_env(:cyfr, :health_ready_cache_ms, @default_ready_cache_ms)

  def ready(conn, _params) do
    checks = cached_checks()

    all_ok = Enum.all?(checks, fn {_k, v} -> v == :ok end)

    status_code = if all_ok, do: 200, else: 503

    unless all_ok do
      Logger.warning("[HealthController] not_ready: #{inspect(checks)}")
    end

    conn
    |> put_status(status_code)
    |> json(%{
      status: if(all_ok, do: "ready", else: "not_ready"),
      checks:
        Map.new(checks, fn {k, v} ->
          # Anonymous callers get pass/fail only; raw DB/storage error
          # internals go to the log line above.
          {k, if(v == :ok, do: "ok", else: "failed")}
        end)
    })
  end

  defp cached_checks do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@ready_cache_key, nil) do
      {checks, expires_at} when expires_at > now ->
        checks

      _ ->
        checks = run_checks()
        :persistent_term.put(@ready_cache_key, {checks, now + ready_cache_ms()})
        checks
    end
  end

  defp run_checks do
    %{
      database: check_database(),
      cache: check_cache(),
      pubsub: check_pubsub(),
      storage: check_storage(),
      tool_registry: check_process(Emissary.MCP.ToolRegistry),
      resource_registry: check_process(Emissary.MCP.ResourceRegistry),
      progress: check_process(Emissary.MCP.Progress.Registry)
    }
  end

  defp check_database do
    case Arca.Repo.query("SELECT 1") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, describe(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Every check failure reads as one shape — a string — so the logged map
  # never mixes Ecto structs, atoms and exception messages.
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp check_cache do
    if :ets.whereis(Arca.Cache.table_name()) != :undefined do
      :ok
    else
      {:error, :ets_missing}
    end
  end

  @doc """
  Where the readiness probe writes — under the `system/` global root.
  This controller is the writer and owns the spelling; the retention
  sweep that reclaims stranded probe files consumes it.
  """
  @spec probe_dir() :: [String.t()]
  def probe_dir, do: ["system", "health"]

  # Round-trips a tiny write through Arca so a full disk, a read-only volume,
  # or broken object-store credentials flip readiness — the boot-time raw-File
  # probe in Cyfr.Application only covers first start, not runtime decay.
  defp check_storage do
    ctx =
      Sanctum.internal_context(
        user_id: "_health_probe",
        permissions: [:storage_read, :storage_write]
      )

    # ONE fixed key: the put overwrites whatever a past failed delete
    # stranded, so the probe self-cleans without ever listing or sweeping
    # the directory (this endpoint is unauthenticated — on an object store
    # a per-probe sweep was a billable LIST + batch DELETE per cache
    # window). Concurrent probes racing on the shared key are covered by
    # the `:not_found` arm below; the retention sweep — which asks this
    # writer where it writes, via `probe_dir/0` — is the belt for legacy
    # `.write_probe.<n>` strays. "system" is in
    # `Arca.Storage.global_prefixes/0` — witnessed in the controller test.
    path = probe_dir() ++ [".write_probe"]

    with :ok <- Arca.put(ctx, path, Integer.to_string(System.system_time(:second))) do
      case Arca.delete(ctx, path) do
        :ok ->
          :ok

        {:error, :not_found} ->
          # A concurrent probe's delete won the race — the write already
          # proved the store.
          :ok

        {:error, reason} ->
          {:error, describe(reason)}
      end
    else
      {:error, reason} -> {:error, describe(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp check_pubsub do
    topic = Prism.Topics.health_check(System.unique_integer([:positive]))

    Phoenix.PubSub.subscribe(Emissary.PubSub, topic)
    Phoenix.PubSub.broadcast(Emissary.PubSub, topic, :ping)

    receive do
      :ping -> :ok
    after
      1_000 -> {:error, :pubsub_timeout}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp check_process(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: :ok, else: {:error, :not_alive}

      nil ->
        {:error, :not_registered}
    end
  end
end
