# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
import Config

if config_env() != :test do
  import Dotenvy

  # Load environment variables from .env files
  # For releases, look for .env at RELEASE_ROOT; otherwise use project root
  env_dir = System.get_env("RELEASE_ROOT") || File.cwd!()

  source!([
    Path.join(env_dir, ".env"),
    Path.join(env_dir, ".env.#{config_env()}"),
    Path.join(env_dir, ".env.local"),
    System.get_env()
  ])

  # Runtime configuration for CYFR
  # This file is executed at runtime, not compile time

  parse_integer = fn env_var, raw ->
    case Integer.parse(raw) do
      {n, ""} -> n
      _ -> raise "Invalid integer for #{env_var}: #{inspect(raw)}"
    end
  end

  # Reader handed to `Cyfr.RuntimeConfig` so the pure resolvers (auth provider,
  # storage, repo) read the same Dotenvy-merged environment this file does.
  getenv = fn key -> env!(key, :string, nil) end

  # JSON log format for structured logging (Datadog, Splunk, ELK, Loki)
  if env!("CYFR_LOG_FORMAT", :string, nil) == "json" do
    config :logger, :default_formatter,
      format: {Cyfr.JsonFormatter, :format},
      metadata: [:request_id, :user_id, :athanor_id, :auth_method]
  end

  # PBKDF2 iterations for key derivation (default 100,000)
  if pbkdf2_iterations = env!("CYFR_PBKDF2_ITERATIONS", :string, nil) do
    config :cyfr, :pbkdf2_iterations, parse_integer.("CYFR_PBKDF2_ITERATIONS", pbkdf2_iterations)
  end

  # Maximum concurrent WASM executions (default: 128)
  # Prevents dirty scheduler exhaustion from too many simultaneous WASM executions
  if max_exec = env!("CYFR_MAX_CONCURRENT_EXECUTIONS", :string, nil) do
    config :cyfr,
           :max_concurrent_executions,
           parse_integer.("CYFR_MAX_CONCURRENT_EXECUTIONS", max_exec)
  end

  # Maximum concurrent WASM executions per tenant (default: 16)
  # Bounds the blast radius of one athanor queueing many long-running executions
  if max_tenant_exec = env!("CYFR_MAX_CONCURRENT_EXECUTIONS_PER_TENANT", :string, nil) do
    config :cyfr,
           :max_concurrent_executions_per_tenant,
           parse_integer.("CYFR_MAX_CONCURRENT_EXECUTIONS_PER_TENANT", max_tenant_exec)
  end

  # MCP transport rate limit, per client IP (default: 120 requests / 60s window).
  # Counts requests and SSE connection opens, not stream duration.
  if mcp_rl_max = env!("CYFR_MCP_RATE_LIMIT_MAX", :string, nil) do
    config :cyfr, :mcp_rate_limit_max, parse_integer.("CYFR_MCP_RATE_LIMIT_MAX", mcp_rl_max)
  end

  if mcp_rl_window = env!("CYFR_MCP_RATE_LIMIT_WINDOW_MS", :string, nil) do
    config :cyfr,
           :mcp_rate_limit_window_ms,
           parse_integer.("CYFR_MCP_RATE_LIMIT_WINDOW_MS", mcp_rl_window)
  end

  # Session idle timeout in hours (default 720 / 30 days, 0 = infinite / never expires, minimum 1).
  # Sessions slide forward on activity, so this is an idle timeout rather than a hard cap.
  if session_ttl = env!("CYFR_SESSION_TTL_HOURS", :string, nil) do
    ttl_hours = parse_integer.("CYFR_SESSION_TTL_HOURS", session_ttl)

    if ttl_hours < 0 do
      raise "CYFR_SESSION_TTL_HOURS must be >= 0 (0 = infinite, minimum non-zero is 1)"
    end

    config :cyfr, :session_ttl_hours, ttl_hours
  end

  # CYFR_SECRET_KEY_BASE env var overrides config-level secret_key_base (from dev.exs/test.exs).
  # In production, this env var is required. In dev/test, the config file provides a static key.
  env_key_base = env!("CYFR_SECRET_KEY_BASE", :string, nil)

  if is_binary(env_key_base) and env_key_base != "" do
    config :cyfr, :secret_key_base, env_key_base
  end

  if config_env() == :prod do
    secret_key_base =
      env_key_base ||
        raise """
        environment variable CYFR_SECRET_KEY_BASE is missing.
        You can generate one by calling: mix phx.gen.secret
        """

    # A misspelled bind address used to fall back to loopback, which starts
    # the server on an interface nobody asked for and reads as "the deploy
    # worked" until the first request from outside never arrives.
    parse_ip = fn var, ip_string ->
      case :inet.parse_address(String.to_charlist(ip_string)) do
        {:ok, ip_tuple} ->
          ip_tuple

        {:error, _} ->
          raise "environment variable #{var} is not a valid IP address: #{inspect(ip_string)}"
      end
    end

    emissary_bind = parse_ip.("CYFR_BIND_ADDRESS", env!("CYFR_BIND_ADDRESS", :string, "0.0.0.0"))

    prism_bind =
      parse_ip.("CYFR_PRISM_BIND_ADDRESS", env!("CYFR_PRISM_BIND_ADDRESS", :string, "0.0.0.0"))

    host = env!("CYFR_HOST", :string, "localhost")
    port = parse_integer.("CYFR_PORT", env!("CYFR_PORT", :string, "4000"))

    # Origins the browser will send for this deployment. We include both schemes
    # so the same compose stack works whether Caddy serves plain HTTP on :80 (a
    # localhost / bare-IP deploy) or terminates TLS for a real domain. Localhost
    # variants stay in the list so the host-bound CLI / dev curls still work.
    host_origins = [
      "https://#{host}",
      "http://#{host}",
      "https://#{host}:#{port}",
      "http://#{host}:#{port}"
    ]

    localhost_origins = [
      "http://localhost",
      "https://localhost",
      "http://localhost:#{port}",
      "https://localhost:#{port}",
      "http://127.0.0.1",
      "https://127.0.0.1",
      "http://[::1]",
      "https://[::1]"
    ]

    config :cyfr, EmissaryWeb.Endpoint,
      url: [host: host, port: port],
      http: [
        ip: emissary_bind,
        port: port,
        thousand_island_options: [shutdown_timeout: 30_000, read_timeout: 60_000]
      ],
      check_origin: host_origins ++ localhost_origins,
      secret_key_base: secret_key_base,
      server: true

    # MCP origin allowlist (EmissaryWeb.Plugs.MCPOrigin). Same set as
    # check_origin above, plus any extra origins listed in
    # CYFR_MCP_ALLOWED_ORIGINS (comma-separated) for embedding the PWA on a
    # different origin or running multiple frontends against the same server.
    extra_mcp_origins =
      case env!("CYFR_MCP_ALLOWED_ORIGINS", :string, nil) do
        nil -> []
        s -> s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      end

    config :cyfr, :mcp_allowed_origins, host_origins ++ localhost_origins ++ extra_mcp_origins

    # Prism Dashboard Endpoint (production)
    prism_port = parse_integer.("CYFR_PRISM_PORT", env!("CYFR_PRISM_PORT", :string, "4001"))
    prism_host = env!("CYFR_PRISM_HOST", :string, host)

    config :cyfr, PrismWeb.Endpoint,
      url: [host: prism_host, port: prism_port],
      http: [
        ip: prism_bind,
        port: prism_port,
        thousand_island_options: [shutdown_timeout: 30_000, read_timeout: 60_000]
      ],
      check_origin: [
        "https://#{prism_host}",
        "http://#{prism_host}",
        "https://#{prism_host}:#{prism_port}",
        "http://#{prism_host}:#{prism_port}",
        "http://localhost",
        "https://localhost",
        "http://localhost:#{prism_port}",
        "https://localhost:#{prism_port}"
      ],
      secret_key_base: secret_key_base,
      server: true

    # Derive signing salts from secret_key_base (or use explicit env overrides)
    emissary_salt =
      env!("CYFR_EMISSARY_SESSION_SALT", :string, nil) ||
        :crypto.hash(:sha256, "emissary_session" <> secret_key_base)
        |> Base.url_encode64(padding: false)
        |> binary_part(0, 16)

    prism_salt =
      env!("CYFR_PRISM_SESSION_SALT", :string, nil) ||
        :crypto.hash(:sha256, "prism_session" <> secret_key_base)
        |> Base.url_encode64(padding: false)
        |> binary_part(0, 16)

    prism_lv_salt =
      env!("CYFR_PRISM_LV_SALT", :string, nil) ||
        :crypto.hash(:sha256, "prism_live_view" <> secret_key_base)
        |> Base.url_encode64(padding: false)
        |> binary_part(0, 16)

    config :cyfr, :emissary_session_salt, emissary_salt
    config :cyfr, :prism_session_salt, prism_salt
    config :cyfr, PrismWeb.Endpoint, live_view: [signing_salt: prism_lv_salt]

    # Session cookies must be secure in production (HTTPS-only).
    # Dev/test leave this false so http://localhost works.
    config :cyfr, :cookie_secure, true

    # Database connection config. The adapter is selected at compile time in
    # config.exs from CYFR_DATABASE; here we supply connection parameters for
    # whichever adapter was built — gated so SQLite-only keys (journal_mode,
    # busy_timeout) never bleed into a Postgres build and vice versa.
    case Cyfr.RuntimeConfig.repo_adapter() do
      Ecto.Adapters.SQLite3 ->
        config :cyfr, Arca.Repo,
          database: env!("CYFR_DATABASE_PATH", :string, "data/cyfr.db"),
          pool_size:
            parse_integer.("CYFR_DB_POOL_SIZE", env!("CYFR_DB_POOL_SIZE", :string, "20")),
          journal_mode: :wal,
          busy_timeout: Cyfr.RuntimeConfig.sqlite_busy_timeout_ms()

      Ecto.Adapters.Postgres ->
        # A Postgres build carries no connection config from config.exs, so a
        # CYFR_DATABASE_URL is required — its absence is a hard boot error
        # rather than a silent attempt against a default localhost.
        case Cyfr.RuntimeConfig.resolve_postgres(getenv) do
          {:ok, repo_opts} -> config :cyfr, Arca.Repo, repo_opts
          {:error, message} -> raise message
        end
    end

    components_path = env!("CYFR_COMPONENTS_PATH", :string, "components") |> Path.expand()
    config :cyfr, :components_path, components_path

    # Warn if plain HTTP in production without a reverse proxy declaration
    unless env!("CYFR_BEHIND_PROXY", :string, nil) do
      IO.puts(
        :stderr,
        "[warning] CYFR is running plain HTTP in production. " <>
          "Set CYFR_BEHIND_PROXY=true if behind a TLS-terminating reverse proxy, " <>
          "and set CYFR_BIND_ADDRESS=127.0.0.1 to bind only to localhost."
      )
    end

    # If behind a proxy, enable X-Forwarded-For trust for IP-based API key allowlists.
    # The client IP is taken right-to-left from the XFF chain, stripping the
    # trusted proxies (Sanctum.ClientIp). With one proxy layer (the shipped
    # Caddy) the default of 1 hop is correct; stacking more layers requires
    # raising CYFR_TRUSTED_PROXY_HOPS to match, or listing the proxies in
    # CYFR_TRUSTED_PROXY_CIDRS (comma-separated IPs/CIDRs, takes precedence).
    if env!("CYFR_BEHIND_PROXY", :string, nil) do
      config :cyfr, :trust_x_forwarded_for, true

      config :cyfr,
             :trusted_proxy_hops,
             parse_integer.(
               "CYFR_TRUSTED_PROXY_HOPS",
               env!("CYFR_TRUSTED_PROXY_HOPS", :string, "1")
             )

      if cidrs = env!("CYFR_TRUSTED_PROXY_CIDRS", :string, nil) do
        config :cyfr,
               :trusted_proxy_cidrs,
               cidrs |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      end
    end
  end

  # CORS allowlist for the browser-facing HTTP surface (comma-separated
  # origins). The boot guard refuses to start a release that has
  # authentication configured while the wildcard default is in effect, so any
  # deployment with OAuth/OIDC enabled must set this. An empty value allows no
  # cross-origin callers at all (fail-closed).
  if cors_origins = env!("CYFR_CORS_ALLOWED_ORIGINS", :string, nil) do
    config :cyfr,
           :cors_allowed_origins,
           cors_origins
           |> String.split(",")
           |> Enum.map(&String.trim/1)
           |> Enum.reject(&(&1 == ""))
  end

  # GitHub OAuth
  # Device Flow (CLI) only needs client ID - no secret required
  # Server-side OAuth (web login) requires both client ID and secret
  github_id = env!("CYFR_GITHUB_CLIENT_ID", :string, nil)
  github_secret = env!("CYFR_GITHUB_CLIENT_SECRET", :string, nil)

  if github_id && github_secret do
    config :ueberauth, Ueberauth.Strategy.Github.OAuth,
      client_id: github_id,
      client_secret: github_secret
  end

  # Google OAuth
  # Device Flow (CLI) and server-side OAuth (web login) BOTH require client
  # ID + secret. Unlike GitHub, Google's device-flow token endpoint rejects
  # exchanges that omit client_secret with {"error": "invalid_request"}.
  google_id = env!("CYFR_GOOGLE_CLIENT_ID", :string, nil)
  google_secret = env!("CYFR_GOOGLE_CLIENT_SECRET", :string, nil)

  if google_id && google_secret do
    config :ueberauth, Ueberauth.Strategy.Google.OAuth,
      client_id: google_id,
      client_secret: google_secret
  end

  # Device Flow credentials for Google. `google_client_id` is sent on both
  # the device-code request and the token exchange; `google_client_secret`
  # is sent only on the token exchange (required per Google OAuth spec for
  # all device-flow clients).
  if google_id do
    config :cyfr, :google_client_id, google_id
  end

  if google_secret do
    config :cyfr, :google_client_secret, google_secret
  end

  # Registry URL (REST API) and OCI Registry URL (OCI Distribution endpoint).
  # Default: `registry_url` is `"cyfr.run"` and `oci_registry_url` derives as
  # `"registry.#{registry_url}"`. Self-hosted deployments may override both
  # independently for co-host or split topologies.
  #
  # cyfr.run issues per-user push tokens automatically via
  # `/v1/identity/probe` after login, so there is no static
  # username/password to configure at deploy time.
  registry_url_config = env!("CYFR_REGISTRY_URL", :string, "cyfr.run")
  config :cyfr, :registry_url, registry_url_config

  # The address this instance is reachable at from outside — needed to hand a
  # webhook sender an absolute URL, which behind a proxy or a tunnel is
  # neither the bind address nor any request's Host. Unset means the console
  # and the CLI show the path and say to set this.
  config :cyfr, :public_url, env!("CYFR_PUBLIC_URL", :string, nil)

  oci_registry_url_config =
    env!("CYFR_OCI_REGISTRY_URL", :string, "registry.#{registry_url_config}")

  config :cyfr, :oci_registry_url, oci_registry_url_config

  # Device Flow Client IDs for Sanctum authentication
  # Device Flow only needs client ID, no secret required
  if github_id = env!("CYFR_GITHUB_CLIENT_ID", :string, nil) do
    config :cyfr, :github_client_id, github_id
  end

  # Platform admins (comma-separated emails). On first sign-in, a listed email
  # is granted a platform-scope membership (full access, bypasses the tenant
  # gate). This is the bootstrap mechanism for any deployment — a solo operator
  # lists their own email; a shared server lists the platform staff.
  platform_admins =
    (env!("CYFR_PLATFORM_ADMIN_EMAILS", :string, nil) || "")
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))

  config :cyfr, :platform_admin_emails, platform_admins

  # The public-door caps (Sanctum.Tenancy.Caps). Unset means off: a private
  # box needs none of them; a server whose door is `*` sets them.
  config :cyfr, :caps,
    max_athanors: env!("CYFR_MAX_ATHANORS", :integer, nil),
    max_groups_per_person: env!("CYFR_MAX_GROUPS_PER_PERSON", :integer, nil),
    max_members_per_group: env!("CYFR_MAX_MEMBERS_PER_GROUP", :integer, nil),
    mint_per_hour: env!("CYFR_MINT_PER_HOUR", :integer, nil),
    athanor_storage_bytes: env!("CYFR_ATHANOR_STORAGE_BYTES", :integer, nil)

  # Auto-configure the auth provider from the environment.
  # Priority: explicit config > GitHub/Google credentials > none.
  #
  # The provider is selected purely from configuration. A deployment with
  # GitHub/Google credentials uses the built-in OAuth provider. A deployment
  # that federates against an enterprise IdP supplies its own release runtime
  # config setting `:cyfr, :auth_provider` to its own module. A deployment with
  # no credentials runs without sign-in: requests reach the public read-only
  # surface as an unauthenticated context (tenant-scoped routes are rejected).
  github_configured? = env!("CYFR_GITHUB_CLIENT_ID", :string, nil) != nil
  google_configured? = env!("CYFR_GOOGLE_CLIENT_ID", :string, nil) != nil

  # Set-or-default: an unset CYFR_AUTH_PROVIDER auto-detects from credentials;
  # an explicit value must be satisfiable or the boot fails — it never silently
  # degrades to no authentication.
  auth_provider =
    case Cyfr.RuntimeConfig.resolve_auth_provider(getenv) do
      {:ok, provider} -> provider
      {:error, message} -> raise message
    end

  config :cyfr, :auth_provider, auth_provider

  # Build Ueberauth providers list dynamically
  providers = []

  providers =
    if github_configured? do
      [{:github, {Ueberauth.Strategy.Github, [default_scope: "user:email"]}} | providers]
    else
      providers
    end

  providers =
    if google_configured? do
      [{:google, {Ueberauth.Strategy.Google, [default_scope: "email profile"]}} | providers]
    else
      providers
    end

  # Generic OIDC. When selected, register the issuer for ueberauth_oidcc and add
  # the strategy. CYFR_OIDC_ISSUER is also pinned at `:cyfr, :oidc_issuer` — the
  # single source both the boot reserved-host check
  # (`Cyfr.Application.validate_oidc_issuer_config!/0`) and the login id builder
  # (`Sanctum.Auth.OIDC.resolve_issuer/2`) read.
  providers =
    if auth_provider == Sanctum.Auth.OIDC do
      {:ok, oidc} = Cyfr.RuntimeConfig.oidc_config(getenv)

      config :cyfr, :oidc_issuer, oidc.issuer
      config :ueberauth_oidcc, :issuers, [%{name: :cyfr_oidc, issuer: oidc.issuer}]

      # Provider key `:oidcc` (not `:oidc`) so `auth.provider` matches the
      # generic-OIDC email-verification lane (`Sanctum.Auth.EmailVerification`)
      # and the canonical `oidcc|<iss>|<sub>` id form.
      oidc_provider =
        {:oidcc,
         {Ueberauth.Strategy.Oidcc,
          issuer: :cyfr_oidc, client_id: oidc.client_id, client_secret: oidc.client_secret}}

      [oidc_provider | providers]
    else
      providers
    end

  if providers != [] do
    config :ueberauth, Ueberauth, providers: providers
  end

  # Storage backend. Unset/`local` keeps the filesystem default from config.exs;
  # `s3` flips the adapter and requires the S3 credentials (fail loud if partial).
  case Cyfr.RuntimeConfig.resolve_storage(getenv) do
    {:ok, :local} ->
      :ok

    {:ok, {:s3, s3_opts}} ->
      config :cyfr, :storage_adapter, Arca.Adapters.S3
      config :cyfr, :s3, s3_opts

    {:error, message} ->
      raise message
  end

  # Sigstore Configuration
  if cosign_key = env!("CYFR_COSIGN_KEY", :string, nil) do
    config :cyfr, :sigstore,
      verification: :keyed,
      key_path: cosign_key,
      password: env!("CYFR_COSIGN_PASSWORD", :string, nil)
  else
    config :cyfr, :sigstore, verification: :keyless
  end

  # Prometheus metrics — the /metrics endpoint is unauthenticated, so it is
  # opt-in. Bind to a private interface or proxy-allowlist it when enabled.
  if env!("CYFR_PROMETHEUS_METRICS", :string, nil) == "true" do
    config :cyfr, :prometheus_metrics_enabled, true
  end

  # OpenTelemetry Configuration
  # Set CYFR_OTEL_ENABLED=true to enable distributed tracing.
  # Traces are exported via OTLP to the endpoint specified by OTEL_EXPORTER_OTLP_ENDPOINT
  # (defaults to http://localhost:4318 for HTTP/protobuf).
  if env!("CYFR_OTEL_ENABLED", :string, nil) == "true" do
    config :cyfr, :opentelemetry_enabled, true

    config :opentelemetry,
      resource: %{service: %{name: "cyfr"}},
      span_processor: :batch,
      traces_exporter: :otlp

    config :opentelemetry_exporter,
      otlp_protocol: :http_protobuf,
      otlp_endpoint: env!("OTEL_EXPORTER_OTLP_ENDPOINT", :string, "http://localhost:4318")
  else
    config :opentelemetry,
      traces_exporter: :none
  end
end
