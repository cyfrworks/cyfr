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

    # SanctumArx: Load and validate license (conditionally for Arx edition)
    maybe_load_license()

    # SanctumArx: Validate auth provider is configured for Arx edition
    validate_auth_provider_config()

    # Arx: Warn about CORS wildcard
    warn_cors_wildcard_in_arx()

    # Arx: Attach OTEL tenant handler if OpenTelemetry is enabled
    if Application.get_env(:cyfr, :opentelemetry_enabled, false) do
      Cyfr.OtelTenantHandler.attach()
    end

    # Compendium: Validate registry configuration
    Compendium.Application.validate_registry_config!()

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

  defp validate_auth_provider_config do
    if Code.ensure_loaded?(SanctumArx.License) and SanctumArx.License.edition() == :arx do
      auth_provider = Application.get_env(:cyfr, :auth_provider)

      if is_nil(auth_provider) do
        raise "[SanctumArx] FATAL: Arx edition requires an auth_provider but none is configured. " <>
                "Set config :cyfr, :auth_provider to a module implementing current_user/1."
      end
    end
  end

  defp warn_cors_wildcard_in_arx do
    if Application.get_env(:cyfr, :edition, :core) == :arx do
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

  defp maybe_load_license do
    if Code.ensure_loaded?(SanctumArx.License) do
      SanctumArx.License.load() |> handle_license_result()
    else
      Logger.info("[SanctumArx] Starting in core mode (SanctumArx not available)")
    end
  end

  @doc false
  def handle_license_result(result) do
    case result do
      {:ok, :core} ->
        Logger.info("[SanctumArx] Starting in core mode (no Arx license)")

      {:ok, license} ->
        Logger.info(
          "[SanctumArx] Starting in Sanctum Arx edition " <>
            "customer_id=#{license.customer_id} expires_at=#{DateTime.to_iso8601(license.expires_at)}"
        )

      {:error, :expired} ->
        Logger.warning(
          "[SanctumArx] Arx license expired - running in zombie mode. " <>
            "Some features may be restricted. Please renew your license."
        )

      {:error, {:license_file_missing, path}} ->
        if Code.ensure_loaded?(SanctumArx.License) and SanctumArx.License.edition() == :arx do
          Logger.error(
            "[SanctumArx] Arx edition configured but license file not found at #{path}. " <>
              "Please provide a valid license file or switch to Sanctum."
          )

          raise "[SanctumArx] FATAL: Arx edition requires a license file at #{path}."
        end

      {:error, reason} ->
        Logger.error("[SanctumArx] License validation failed: #{inspect(reason)}")

        if Code.ensure_loaded?(SanctumArx.License) and SanctumArx.License.edition() == :arx do
          raise "[SanctumArx] FATAL: Arx license validation failed: #{inspect(reason)}."
        end
    end
  end
end
