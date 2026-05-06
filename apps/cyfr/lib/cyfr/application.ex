defmodule Cyfr.Application do
  @moduledoc false

  require Logger
  require Arca.Repo.Errors

  use Application

  @impl true
  def start(_type, _args) do
    # Arca storage setup
    ensure_db_directory!()
    maybe_migrate_before_pool()
    Arca.Cache.init()

    # Emissary: Initialize OpenTelemetry instrumentation for Phoenix/Bandit
    if Application.get_env(:cyfr, :opentelemetry_enabled, false) do
      OpentelemetryBandit.setup()
      OpentelemetryPhoenix.setup(adapter: :bandit)
    end

    # Emissary: RunningTasks GenServer is now in the supervision tree

    # Arx-edition warning (license loading + auth_provider validation
    # live in Arx.Application, which boots after Cyfr if apps/arx is present).
    warn_cors_wildcard_in_arx()

    # Arx: Attach OTEL tenant handler if OpenTelemetry is enabled
    if Application.get_env(:cyfr, :opentelemetry_enabled, false) do
      Cyfr.OtelTenantHandler.attach()
    end

    # Compendium: Validate registry configuration
    Compendium.Application.validate_registry_config!()

    # Webhook verify-failed → log at :warning. Operators can disable by
    # detaching `"webhook-verify-failed-log"` if they prefer an alternative
    # sink (e.g. forwarding to SIEM via a Telemetry Metrics consumer).
    attach_webhook_verify_failed_logger()

    children = [
      # Arca storage layer
      Arca.Repo,
      Arca.Cache.Sweeper,
      Arca.RetentionScheduler,
      Arca.AuditHandler,
      # Emissary web layer
      EmissaryWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:cyfr, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Emissary.PubSub},
      {Registry, keys: :unique, name: Emissary.MCP.ExternalServerRegistry},
      {DynamicSupervisor,
       name: Emissary.MCP.ExternalServerSupervisor, strategy: :one_for_one},
      Emissary.MCP.ToolRegistry,
      Emissary.MCP.ResourceRegistry,
      Emissary.MCP.SSEBuffer,
      {Task.Supervisor, name: Emissary.TaskSupervisor},
      Emissary.MCP.RunningTasks,
      EmissaryWeb.Plugs.PersonalNamespaceCache,
      # Compendium registry — Finch pool for cyfr.run REST + OCI HTTP.
      {Finch, name: Compendium.Finch},
      # Sanctum auth sliver — separate Finch pool for IdP OAuth Device-Flow
      # HTTP calls (GitHub / Google). The auth sliver's only permitted edge
      # into Compendium is the post-Session.create probe + CredentialStore.put
      # handoff; a distinct Finch pool keeps OAuth userinfo HTTP from riding
      # the Compendium pool and reinforces that boundary at the supervision
      # level.
      {Finch, name: Sanctum.Auth.Finch},
      # Prism dashboard
      PrismWeb.Telemetry,
      Prism.TelemetryBridge,
      Prism.TinctureRegistry,
      {Task.Supervisor, name: Prism.TaskSupervisor},
      # Endpoints (last)
      EmissaryWeb.Endpoint,
      PrismWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Cyfr.Supervisor, max_restarts: 10, max_seconds: 60]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EmissaryWeb.Endpoint.config_change(changed, removed)
    PrismWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp ensure_db_directory! do
    config = Application.get_env(:cyfr, Arca.Repo, [])

    if db_path = config[:database] do
      # arca:bypass-ok=B — pre-Arca bootstrap; runs before Arca.Repo starts.
      # SQLite-only path; Postgres builds skip this branch (db_path is nil).
      db_path |> Path.dirname() |> File.mkdir_p!()
    end
  end

  # Run migrations before the connection pool starts to avoid
  # "database is locked" errors from pool connections racing with
  # migration DDL statements on first startup.
  defp maybe_migrate_before_pool do
    if Application.get_env(:cyfr, :auto_migrate, true) do
      config = Application.get_env(:cyfr, Arca.Repo, [])
      verify_db_writable!(config[:database])
      # Start a temporary repo with pool_size=1 just for migrations
      {:ok, repo_pid} = Arca.Repo.start_link(Keyword.put(config, :pool_size, 1))
      Ecto.Migrator.run(Arca.Repo, migrations_path(), :up, all: true)
      configure_database()
      # Stop the temporary repo so the supervisor can start the real one
      Supervisor.stop(repo_pid)
    end
  end

  defp verify_db_writable!(nil), do: :ok

  defp verify_db_writable!(path) do
    dir = Path.dirname(path)
    test_file = Path.join(dir, ".cyfr_write_test")

    # arca:bypass-ok=B — pre-Arca bootstrap probe used to surface friendly
    # Docker UID errors before the Repo pool tries to open the DB.
    case File.touch(test_file) do
      :ok ->
        File.rm(test_file)

      {:error, reason} ->
        {uid, 0} = System.cmd("id", ["-u"])
        uid = String.trim(uid)

        raise """
        [Arca] Cannot write to database directory: #{dir} (#{reason})

        If running in Docker with bind mounts (e.g. ./data:/app/data),
        the host directory must be writable by the container user (UID #{uid}).

        Fix: on the host, run:
          sudo chown -R #{uid} #{dir}
        """
    end
  end

  defp configure_database do
    case Application.get_env(:cyfr, :repo_adapter, Ecto.Adapters.SQLite3) do
      Ecto.Adapters.SQLite3 ->
        Arca.Repo.query!("PRAGMA journal_mode=WAL")
        Arca.Repo.query!("PRAGMA busy_timeout=5000")

      _ ->
        :ok
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.warning("[Arca] Database configuration failed: #{Exception.message(e)}")
      :ok
  end

  defp migrations_path do
    Application.app_dir(:cyfr, "priv/repo/migrations")
  end

  defp attach_webhook_verify_failed_logger do
    handler_id = "cyfr-webhook-verify-failed-log"

    # Detaching first makes the call idempotent across application restarts
    # in iex `:application.stop/start` cycles. Errors from detach when no
    # handler is attached are explicitly safe per :telemetry docs.
    _ = :telemetry.detach(handler_id)

    :telemetry.attach(
      handler_id,
      [:cyfr, :emissary, :webhook, :verify_failed],
      &__MODULE__.log_webhook_verify_failed/4,
      nil
    )
  end

  @doc false
  def log_webhook_verify_failed(_event, _measurements, metadata, _config) do
    Logger.warning(
      "[Webhook] verify_failed slug=#{inspect(metadata[:slug])} reason=#{metadata[:reason]}"
    )
  end

  defp warn_cors_wildcard_in_arx do
    if Sanctum.Edition.arx?() do
      origins = Application.get_env(:cyfr, :cors_allowed_origins, [])

      if "*" in List.wrap(origins) do
        Logger.warning(
          "[Cyfr] CORS wildcard \"*\" is configured in Arx mode. " <>
            "This allows any origin to make cross-origin requests. " <>
            "Restrict cors_allowed_origins for production deployments."
        )
      end
    end
  end

end
