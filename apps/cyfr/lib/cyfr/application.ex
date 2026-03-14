defmodule Cyfr.Application do
  @moduledoc false

  require Logger

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

    # Emissary: Initialize ETS table for tracking running MCP tool executions
    Emissary.MCP.RunningTasks.init()

    # SanctumArx: Load and validate license (conditionally for Arx edition)
    maybe_load_license()

    # SanctumArx: Validate auth provider is configured for Arx edition
    validate_auth_provider_config()

    # Compendium: Validate registry configuration
    Compendium.Application.validate_registry_config!()

    # Compendium: Initialize OCI auth token cache
    Compendium.OCI.Auth.init_cache()

    children = [
      # Arca storage layer
      Arca.Repo,
      Arca.Cache.Sweeper,
      # Emissary web layer
      EmissaryWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:cyfr, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Emissary.PubSub},
      Emissary.MCP.ToolRegistry,
      Emissary.MCP.ResourceRegistry,
      Emissary.MCP.SSEBuffer,
      {Task.Supervisor, name: Emissary.TaskSupervisor},
      # Compendium registry
      {Finch, name: Compendium.Finch},
      # Prism dashboard
      PrismWeb.Telemetry,
      Prism.TelemetryBridge,
      Prism.AppRegistry,
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
      # Start a temporary repo with pool_size=1 just for migrations
      {:ok, repo_pid} = Arca.Repo.start_link(Keyword.put(config, :pool_size, 1))
      Ecto.Migrator.run(Arca.Repo, migrations_path(), :up, all: true)
      enable_wal_mode()
      # Stop the temporary repo so the supervisor can start the real one
      Supervisor.stop(repo_pid)
    end
  end

  defp enable_wal_mode do
    Arca.Repo.query!("PRAGMA journal_mode=WAL")
    Arca.Repo.query!("PRAGMA busy_timeout=5000")
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.warning("[Arca] WAL mode failed: #{Exception.message(e)}")
      :ok
  end

  defp migrations_path do
    Application.app_dir(:cyfr, "priv/repo/migrations")
  end

  defp validate_auth_provider_config do
    if SanctumArx.License.edition() == :arx do
      auth_provider = Application.get_env(:cyfr, :auth_provider)

      if is_nil(auth_provider) do
        raise "[SanctumArx] FATAL: Arx edition requires an auth_provider but none is configured. " <>
                "Set config :cyfr, :auth_provider to a module implementing current_user/1."
      end
    end
  end

  defp maybe_load_license do
    case SanctumArx.License.load() do
      {:ok, :core} ->
        Logger.info("[SanctumArx] Starting in core mode (no Arx license)")

      {:ok, license} ->
        Logger.info("[SanctumArx] Starting in Sanctum Arx edition",
          customer_id: license.customer_id,
          expires_at: DateTime.to_iso8601(license.expires_at)
        )

      {:error, :expired} ->
        Logger.warning(
          "[SanctumArx] Arx license expired - running in zombie mode. " <>
            "Some features may be restricted. Please renew your license."
        )

      {:error, {:license_file_missing, path}} ->
        if SanctumArx.License.edition() == :arx do
          Logger.error(
            "[SanctumArx] Arx edition configured but license file not found at #{path}. " <>
              "Please provide a valid license file or switch to Sanctum."
          )
        end

      {:error, reason} ->
        Logger.error("[SanctumArx] License validation failed: #{inspect(reason)}")
    end
  end
end
