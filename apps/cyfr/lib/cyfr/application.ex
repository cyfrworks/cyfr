# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

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

    # Resolve the at-rest cipher keyring before any worker can encrypt or
    # decrypt. Explicit `CYFR_CRYPTO_KEYRING` (JSON) wins; otherwise derive a
    # single-key keyring from `:secret_key_base` so single-user deployments
    # work zero-config. Rotating `:secret_key_base` invalidates every blob
    # encrypted under the derived key — platform deployments should set an
    # explicit keyring to avoid that coupling.
    resolve_crypto_keyring!()

    # CORS hardening once authentication is configured (and thus users other
    # than the operator can make credentialed cross-origin requests).
    enforce_cors_not_wildcard_with_auth()

    # OIDC issuer reserved-host check — only when OIDC is the configured
    # auth provider. A misconfigured generic-OIDC issuer would otherwise
    # only surface as a 500 at the user's login callback.
    validate_oidc_issuer_config!()

    # Warn (don't block) if auth is configured but no platform admin is
    # declared — no user could access the system until one is seeded.
    warn_if_no_platform_admin()

    # Attach OTEL tenant handler if OpenTelemetry is enabled
    if Application.get_env(:cyfr, :opentelemetry_enabled, false) do
      Cyfr.OtelTenantHandler.attach()
    end

    # Compendium: Validate registry configuration
    Compendium.Application.validate_registry_config!()

    # Webhook verify-failed → log at :warning. Operators can disable by
    # detaching `"webhook-verify-failed-log"` if they prefer an alternative
    # sink (e.g. forwarding to SIEM via a Telemetry Metrics consumer).
    attach_webhook_verify_failed_logger()

    infra_children = [
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
      {DynamicSupervisor, name: Emissary.MCP.ExternalServerSupervisor, strategy: :one_for_one},
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
      # OAuth refresh single-flight (see Sanctum.OAuth.RefreshLock)
      {Registry, keys: :unique, name: Sanctum.OAuth.RefreshRegistry},
      {Task.Supervisor, name: Sanctum.OAuth.RefreshTaskSupervisor},
      # Single-use consent authorizations. Node-local, like the refresh
      # lock above: a proof outlives one operator interaction, not a
      # deployment.
      Sanctum.Consent.Proof.Memory,
      # Vault mutations must bite immediately for external MCP servers
      # holding resolved header credentials (§4.6).
      Emissary.MCP.ExternalServerReconciler,
      # Prism dashboard
      PrismWeb.Telemetry,
      Prism.TelemetryBridge,
      Prism.TinctureRegistry,
      {Task.Supervisor, name: Prism.TaskSupervisor}
    ]

    web_children = [
      EmissaryWeb.Endpoint,
      PrismWeb.Endpoint
    ]

    # Two tiers under a :rest_for_one root so each has its own restart budget:
    # a crash-looping endpoint exhausts only the web tier (infra keeps running,
    # then the root restarts just the web tier), while an infra collapse
    # restarts infra AND the web tier so endpoints rebind to fresh
    # Repo/PubSub/registries instead of holding dead references. Shutdown is
    # reverse start order: endpoints drain before infra goes down.
    children = [
      tier(Cyfr.InfraSupervisor, infra_children),
      tier(Cyfr.WebSupervisor, web_children)
    ]

    opts = [strategy: :rest_for_one, name: Cyfr.Supervisor, max_restarts: 10, max_seconds: 60]
    Supervisor.start_link(children, opts)
  end

  defp tier(name, children) do
    %{
      id: name,
      start:
        {Supervisor, :start_link,
         [children, [strategy: :one_for_one, name: name, max_restarts: 10, max_seconds: 60]]},
      type: :supervisor
    }
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

  # A wildcard CORS origin is a CSRF/credential-leak risk once authentication
  # is configured (users beyond the operator can make credentialed cross-origin
  # requests) — it must then be an explicit allowlist. Fail closed at boot in a
  # real release (gated on RELEASE_ROOT, so dev/test are never blocked); warn
  # loudly otherwise. A no-auth deployment keeps the wildcard default.
  defp enforce_cors_not_wildcard_with_auth do
    decision =
      cors_enforcement(
        Sanctum.auth_configured?(),
        Application.get_env(:cyfr, :cors_allowed_origins, []),
        System.get_env("RELEASE_ROOT") != nil
      )

    case decision do
      :ok -> :ok
      {:raise, message} -> raise message
      {:warn, message} -> Logger.warning(message)
    end
  end

  @doc false
  # Pure decision seam (testable without booting). A wildcard CORS origin in a
  # deployment that has authentication configured lets ANY origin make
  # credentialed cross-origin requests — it must be an explicit allowlist. Fail
  # closed at boot in a real release (gated on RELEASE_ROOT, so dev/test are
  # never blocked); warn loudly otherwise.
  @spec cors_enforcement(boolean(), term(), boolean()) ::
          :ok | {:raise, String.t()} | {:warn, String.t()}
  def cors_enforcement(auth_configured?, origins, real_release?) do
    if auth_configured? and "*" in List.wrap(origins) do
      message =
        "[Cyfr] FATAL: CORS wildcard \"*\" is configured in a deployment with " <>
          "authentication enabled. This allows ANY origin to make credentialed " <>
          "cross-origin requests. Set CYFR_CORS_ALLOWED_ORIGINS (comma-separated " <>
          "origins) — or :cyfr, :cors_allowed_origins in config — to an " <>
          "explicit origin allowlist."

      if real_release? do
        {:raise, message}
      else
        {:warn, message <> " (boot-raise suppressed outside a release)"}
      end
    else
      :ok
    end
  end

  # When auth is configured but no platform admin is declared, no user can be
  # admitted until a membership row is seeded (authentication succeeds but the
  # tenant gate yields no_org). Warn at boot — both under `mix phx.server` and in
  # releases — so the operator knows to set CYFR_PLATFORM_ADMIN_EMAILS. Stays
  # quiet in test, where no auth provider is configured.
  defp warn_if_no_platform_admin do
    auth_configured? = Sanctum.auth_configured?()
    no_admins? = Application.get_env(:cyfr, :platform_admin_emails, []) == []

    if auth_configured? and no_admins? do
      Logger.warning(
        "[Cyfr] WARNING: :auth_provider is configured but CYFR_PLATFORM_ADMIN_EMAILS " <>
          "is empty — no user can access the system. Set CYFR_PLATFORM_ADMIN_EMAILS=" <>
          "<your_email> or seed a membership row manually."
      )
    end
  end

  # OIDC issuer reserved-host check. A generic-OIDC issuer pointed at a
  # reserved direct-provider host (github.com, accounts.google.com) would
  # produce cross-deployment colliding user ids and silently break login.
  # Surface it at boot so a deploy fails loudly instead of every login.
  defp validate_oidc_issuer_config! do
    if Application.get_env(:cyfr, :auth_provider) == Sanctum.Auth.OIDC do
      case check_oidc_issuer(Application.get_env(:cyfr, :oidc_issuer)) do
        :ok -> :ok
        {:error, message} -> raise "[Cyfr] FATAL: #{message}"
      end
    end
  end

  @doc false
  # Pure validation seam (testable without booting). Mirrors the runtime
  # assertion in Sanctum.Auth.OIDC.resolve_issuer/2.
  @spec check_oidc_issuer(term()) :: :ok | {:error, String.t()}
  def check_oidc_issuer(issuer) when is_binary(issuer) and issuer != "" do
    if Sanctum.Context.normalized_issuer_host(issuer) in ["github.com", "accounts.google.com"] do
      {:error,
       "CYFR_OIDC_ISSUER (#{issuer}) is a reserved direct-provider host. " <>
         "ueberauth_oidcc against github.com/accounts.google.com produces " <>
         "cross-deployment colliding user ids; use GitHub/Google OAuth directly " <>
         "(CYFR_GITHUB_CLIENT_ID / CYFR_GOOGLE_CLIENT_ID)."}
    else
      :ok
    end
  end

  def check_oidc_issuer(_),
    do:
      {:error,
       "CYFR_AUTH_PROVIDER=oidc is selected but :cyfr, :oidc_issuer is absent or blank. " <>
         "Set CYFR_OIDC_ISSUER to your identity provider's issuer URL."}

  # Resolve and pin `:cyfr, :crypto_keyring`. Idempotent — re-runs on app
  # restart simply re-derive (or re-parse) the same keyring.
  defp resolve_crypto_keyring! do
    case Application.get_env(:cyfr, :crypto_keyring) do
      %{primary: _, keys: _} = keyring when map_size(keyring.keys) > 0 ->
        :ok

      _ ->
        keyring =
          case System.get_env("CYFR_CRYPTO_KEYRING") do
            nil ->
              derive_keyring_from_secret_key_base!()

            "" ->
              derive_keyring_from_secret_key_base!()

            json ->
              parse_keyring_env!(json)
          end

        Application.put_env(:cyfr, :crypto_keyring, keyring)
    end
  end

  defp derive_keyring_from_secret_key_base! do
    case Application.get_env(:cyfr, :secret_key_base) do
      key when is_binary(key) and byte_size(key) >= 32 ->
        master = :crypto.hash(:sha256, "cyfr-cipher-keyring|" <> key)
        %{primary: "default", keys: %{"default" => master}}

      _ ->
        raise """
        [Cyfr] FATAL: cannot derive :crypto_keyring — :secret_key_base is
        missing or shorter than 32 bytes. Set CYFR_SECRET_KEY_BASE (>= 32
        bytes) or provide CYFR_CRYPTO_KEYRING as JSON
        `{"primary": "label", "keys": {"label": "<base64-32-bytes>"}}`.
        """
    end
  end

  defp parse_keyring_env!(json) do
    case Jason.decode(json) do
      {:ok, %{"primary" => primary, "keys" => keys}}
      when is_binary(primary) and primary != "" and is_map(keys) and map_size(keys) > 0 ->
        decoded =
          Map.new(keys, fn {label, b64} ->
            case Base.decode64(b64) do
              {:ok, bin} when byte_size(bin) >= 32 ->
                {label, bin}

              _ ->
                raise "[Cyfr] FATAL: CYFR_CRYPTO_KEYRING key #{inspect(label)} is not >= 32 bytes of base64"
            end
          end)

        unless Map.has_key?(decoded, primary) do
          raise "[Cyfr] FATAL: CYFR_CRYPTO_KEYRING primary #{inspect(primary)} is not in :keys"
        end

        %{primary: primary, keys: decoded}

      _ ->
        raise "[Cyfr] FATAL: CYFR_CRYPTO_KEYRING must be JSON of the form " <>
                ~s({"primary": "label", "keys": {"label": "<base64-32-bytes>"}})
    end
  end
end
