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

  # JSON log format for structured logging (Datadog, Splunk, ELK, Loki)
  if env!("CYFR_LOG_FORMAT", :string, nil) == "json" do
    config :logger, :default_formatter,
      format: {Cyfr.JsonFormatter, :format},
      metadata: [:request_id, :user_id, :org_id, :project_id, :auth_method]
  end

  # PBKDF2 iterations for key derivation (default 100,000)
  if pbkdf2_iterations = env!("CYFR_PBKDF2_ITERATIONS", :string, nil) do
    config :cyfr, :pbkdf2_iterations, parse_integer.("CYFR_PBKDF2_ITERATIONS", pbkdf2_iterations)
  end

  # Maximum concurrent WASM executions (default: System.schedulers_online() * 2)
  # Prevents dirty scheduler exhaustion from too many simultaneous WASM executions
  if max_exec = env!("CYFR_MAX_CONCURRENT_EXECUTIONS", :string, nil) do
    config :cyfr, :max_concurrent_executions, parse_integer.("CYFR_MAX_CONCURRENT_EXECUTIONS", max_exec)
  end

  # Maximum poll calls per formula batch (default: 10,000)
  # Catches infinite polling loops in formula components
  if max_polls = env!("CYFR_MAX_POLL_CALLS", :string, nil) do
    config :cyfr, :max_poll_calls, parse_integer.("CYFR_MAX_POLL_CALLS", max_polls)
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

  # JWT clock skew tolerance in seconds (default 60)
  if clock_skew = env!("CYFR_JWT_CLOCK_SKEW_SECONDS", :string, nil) do
    config :cyfr, :jwt_clock_skew_seconds, parse_integer.("CYFR_JWT_CLOCK_SKEW_SECONDS", clock_skew)
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

    parse_ip = fn ip_string ->
      case :inet.parse_address(String.to_charlist(ip_string)) do
        {:ok, ip_tuple} -> ip_tuple
        {:error, _} -> {127, 0, 0, 1}
      end
    end

    emissary_bind = parse_ip.(env!("CYFR_BIND_ADDRESS", :string, "0.0.0.0"))
    prism_bind = parse_ip.(env!("CYFR_PRISM_BIND_ADDRESS", :string, "0.0.0.0"))

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
    emissary_salt = env!("CYFR_EMISSARY_SESSION_SALT", :string, nil) ||
      (:crypto.hash(:sha256, "emissary_session" <> secret_key_base)
       |> Base.url_encode64(padding: false) |> binary_part(0, 16))

    prism_salt = env!("CYFR_PRISM_SESSION_SALT", :string, nil) ||
      (:crypto.hash(:sha256, "prism_session" <> secret_key_base)
       |> Base.url_encode64(padding: false) |> binary_part(0, 16))

    prism_lv_salt = env!("CYFR_PRISM_LV_SALT", :string, nil) ||
      (:crypto.hash(:sha256, "prism_live_view" <> secret_key_base)
       |> Base.url_encode64(padding: false) |> binary_part(0, 16))

    config :cyfr, :emissary_session_salt, emissary_salt
    config :cyfr, :prism_session_salt, prism_salt
    config :cyfr, PrismWeb.Endpoint, live_view: [signing_salt: prism_lv_salt]

    # Session cookies must be secure in production (HTTPS-only).
    # Dev/test leave this false so http://localhost works.
    config :cyfr, :cookie_secure, true

    # Database configuration. CYFR_DATABASE_PATH is honored in both editions;
    # default `data/cyfr.db` keeps the historical path for unconfigured deploys.
    config :cyfr, Arca.Repo,
      database: env!("CYFR_DATABASE_PATH", :string, "data/cyfr.db"),
      pool_size: parse_integer.("CYFR_DB_POOL_SIZE", env!("CYFR_DB_POOL_SIZE", :string, "20")),
      journal_mode: :wal,
      busy_timeout: 5_000

    components_path = env!("CYFR_COMPONENTS_PATH", :string, "components") |> Path.expand()
    config :cyfr, :components_path, components_path

    # Warn if plain HTTP in production without a reverse proxy declaration
    unless env!("CYFR_BEHIND_PROXY", :string, nil) do
      IO.puts(:stderr,
        "[warning] CYFR is running plain HTTP in production. " <>
        "Set CYFR_BEHIND_PROXY=true if behind a TLS-terminating reverse proxy, " <>
        "and set CYFR_BIND_ADDRESS=127.0.0.1 to bind only to localhost."
      )
    end

    # If behind a proxy, enable X-Forwarded-For trust for IP-based API key allowlists
    if env!("CYFR_BEHIND_PROXY", :string, nil) do
      config :cyfr, :trust_x_forwarded_for, true
    end
  end

  # OIDC Provider configuration (all environments)
  if oidc_issuer = env!("CYFR_OIDC_ISSUER", :string, nil) do
    config :ueberauth, Ueberauth.Strategy.OIDCC, issuer: oidc_issuer

    if client_id = env!("CYFR_OIDC_CLIENT_ID", :string, nil) do
      config :ueberauth, Ueberauth.Strategy.OIDCC,
        client_id: client_id,
        client_secret: env!("CYFR_OIDC_CLIENT_SECRET", :string, nil)
    end
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
  # Core: registry_url defaults to "cyfr.run"; oci_registry_url derives as
  # "registry.#{registry_url}". Arx: both can be overridden independently for
  # co-host or split topologies.
  #
  # The legacy `:cyfr, :registry` keyword list and `CYFR_REGISTRY_USERNAME` /
  # `CYFR_REGISTRY_PASSWORD` env vars are REMOVED post auth refactor: cyfr.run
  # issues per-user push tokens automatically via `/v1/identity/probe` after
  # login, so there is no static username/password to configure at deploy time.
  registry_url_config = env!("CYFR_REGISTRY_URL", :string, "cyfr.run")
  config :cyfr, :registry_url, registry_url_config

  oci_registry_url_config =
    env!("CYFR_OCI_REGISTRY_URL", :string, "registry.#{registry_url_config}")

  config :cyfr, :oci_registry_url, oci_registry_url_config

  # OCI Distribution Configuration
  if oci_cache_dir = env!("CYFR_OCI_CACHE_DIR", :string, nil) do
    config :cyfr, :oci_cache_dir, oci_cache_dir
  end

  # JWT Signing Key for Sanctum (required for JWT-based authentication)
  if jwt_key = env!("CYFR_JWT_SIGNING_KEY", :string, nil) do
    config :cyfr, :jwt_signing_key, jwt_key
  end

  # Device Flow Client IDs for Sanctum authentication
  # Device Flow only needs client ID, no secret required
  if github_id = env!("CYFR_GITHUB_CLIENT_ID", :string, nil) do
    config :cyfr, :github_client_id, github_id
  end

  # Sanctum Edition Configuration
  if edition = env!("CYFR_EDITION", :string, nil) do
    normalized = edition |> String.trim() |> String.downcase()

    unless normalized in ~w(core arx) do
      raise """
      Invalid CYFR_EDITION: "#{edition}".

      Valid values: "core" (default) or "arx" (enterprise).
      """
    end

    config :cyfr, :edition, String.to_atom(normalized)
  end

  # License file path for Sanctum Arx
  if license_path = env!("CYFR_LICENSE_PATH", :string, nil) do
    config :cyfr, :license_path, license_path
  end

  # Allowed users (comma-separated emails) — enforced for all auth paths
  if allowed_users = env!("CYFR_ALLOWED_USER", :string, nil) do
    users =
      allowed_users
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    config :cyfr, :allowed_users, users
  end

  # Auto-configure auth provider based on environment
  # Priority: explicit config > Sanctum Arx with license > SimpleOAuth with credentials
  github_configured? = env!("CYFR_GITHUB_CLIENT_ID", :string, nil) != nil
  google_configured? = env!("CYFR_GOOGLE_CLIENT_ID", :string, nil) != nil
  license_configured? = env!("CYFR_LICENSE_PATH", :string, nil) != nil
  oidc_configured? = env!("CYFR_OIDC_ISSUER", :string, nil) != nil
  explicit_auth_provider = env!("CYFR_AUTH_PROVIDER", :string, nil)

  arx_oidc_available? = Code.ensure_loaded?(Arx.Auth.OIDC)

  auth_provider =
    cond do
      # Explicit auth provider configuration takes priority
      explicit_auth_provider == "oidc" and arx_oidc_available? ->
        Arx.Auth.OIDC

      explicit_auth_provider == "simple_oauth" ->
        Sanctum.Auth.SimpleOAuth

      # Sanctum Arx: full OIDC with enterprise providers
      (license_configured? or oidc_configured?) and arx_oidc_available? ->
        Arx.Auth.OIDC

      # SimpleOAuth: GitHub or Google for single-user scenarios
      github_configured? or google_configured? ->
        Sanctum.Auth.SimpleOAuth

      # No auth configured - require configuration
      true ->
        raise """
        No authentication provider configured!

        Please configure at least one of the following:
        - CYFR_GITHUB_CLIENT_ID for GitHub OAuth (Device Flow)
        - CYFR_GOOGLE_CLIENT_ID for Google OAuth (Device Flow)
        - CYFR_OIDC_ISSUER for enterprise OIDC (requires Sanctum Arx)

        For GitHub, create an OAuth App at https://github.com/settings/developers
        and enable "Device Flow" in the app settings.
        For Google, create an OAuth 2.0 Client ID at https://console.cloud.google.com/.
        """
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

  providers =
    if oidc_configured? do
      [{:oidc, {Ueberauth.Strategy.OIDCC, []}} | providers]
    else
      providers
    end

  if providers != [] do
    config :ueberauth, Ueberauth, providers: providers
  end

  # Vault Configuration (optional)
  # When CYFR_VAULT_ADDR is set, a token is typically required for authentication.
  # Anonymous/AppRole authentication may work without a token depending on Vault configuration.
  if vault_addr = env!("CYFR_VAULT_ADDR", :string, nil) do
    vault_token = env!("CYFR_VAULT_TOKEN", :string, nil)

    if is_nil(vault_token) do
      IO.puts(
        :stderr,
        "[warning] CYFR_VAULT_ADDR is set but CYFR_VAULT_TOKEN is missing. " <>
          "Vault operations may fail without authentication."
      )
    end

    config :cyfr, :vault,
      address: vault_addr,
      token: vault_token
  end

  # (Removed: :cyfr_run_api_url. The REST host now lives under :registry_url
  # above — set via CYFR_REGISTRY_URL. The CyfrRun.Client reads that key to
  # build `https://<registry_url>` as its base URL.)

  # Sigstore Configuration
  if cosign_key = env!("CYFR_COSIGN_KEY", :string, nil) do
    config :cyfr, :sigstore,
      mode: :keyed,
      key_path: cosign_key,
      password: env!("CYFR_COSIGN_PASSWORD", :string, nil)
  else
    config :cyfr, :sigstore, mode: :keyless
  end

  if trusted_keys = env!("CYFR_TRUSTED_KEYS", :string, nil) do
    config :cyfr, :trusted_keys, paths: String.split(trusted_keys, ",")
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
