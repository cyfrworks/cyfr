import Config
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

# PBKDF2 iterations for key derivation (default 100,000)
if pbkdf2_iterations = env!("CYFR_PBKDF2_ITERATIONS", :string, nil) do
  config :sanctum, :pbkdf2_iterations, String.to_integer(pbkdf2_iterations)
end

# Maximum concurrent WASM executions (default: System.schedulers_online() * 2)
# Prevents dirty scheduler exhaustion from too many simultaneous WASM executions
if max_exec = env!("CYFR_MAX_CONCURRENT_EXECUTIONS", :string, nil) do
  config :opus, :max_concurrent_executions, String.to_integer(max_exec)
end

# Maximum poll calls per formula batch (default: 10,000)
# Catches infinite polling loops in formula components
if max_polls = env!("CYFR_MAX_POLL_CALLS", :string, nil) do
  config :opus, :max_poll_calls, String.to_integer(max_polls)
end

# Session TTL in hours (default 24, 0 = infinite / never expires, minimum 1)
if session_ttl = env!("CYFR_SESSION_TTL_HOURS", :string, nil) do
  ttl_hours = String.to_integer(session_ttl)

  if ttl_hours < 0 do
    raise "CYFR_SESSION_TTL_HOURS must be >= 0 (0 = infinite, minimum non-zero is 1)"
  end

  config :sanctum, :session_ttl_hours, ttl_hours
end

# JWT clock skew tolerance in seconds (default 60)
if clock_skew = env!("CYFR_JWT_CLOCK_SKEW_SECONDS", :string, nil) do
  config :sanctum, :jwt_clock_skew_seconds, String.to_integer(clock_skew)
end

# CYFR_SECRET_KEY_BASE env var overrides config-level secret_key_base (from dev.exs/test.exs).
# In production, this env var is required. In dev/test, the config file provides a static key.
env_key_base = env!("CYFR_SECRET_KEY_BASE", :string, nil)

if is_binary(env_key_base) and env_key_base != "" do
  config :sanctum, :secret_key_base, env_key_base
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
  port = String.to_integer(env!("CYFR_PORT", :string, "4000"))

  config :emissary, EmissaryWeb.Endpoint,
    url: [host: host, port: port],
    http: [ip: emissary_bind, port: port],
    secret_key_base: secret_key_base,
    server: true

  # Prism Dashboard Endpoint (production)
  prism_port = String.to_integer(env!("CYFR_PRISM_PORT", :string, "4001"))
  prism_host = env!("CYFR_PRISM_HOST", :string, host)

  config :prism, PrismWeb.Endpoint,
    url: [host: prism_host, port: prism_port],
    http: [ip: prism_bind, port: prism_port],
    check_origin: [
      "http://#{prism_host}",
      "http://#{prism_host}:#{prism_port}",
      "http://localhost",
      "http://localhost:#{prism_port}"
    ],
    secret_key_base: secret_key_base,
    server: true

  # Database configuration
  # Core edition uses a fixed path. CYFR_DATABASE_PATH is an Arx-only feature.
  database_path =
    if env!("CYFR_EDITION", :string, nil) == "arx" do
      env!("CYFR_DATABASE_PATH", :string, "data/cyfr.db")
    else
      if custom = env!("CYFR_DATABASE_PATH", :string, nil) do
        IO.puts(
          :stderr,
          "[warning] CYFR_DATABASE_PATH=#{custom} is ignored in Core edition. " <>
            "Custom database paths require Sanctum Arx. Using default: data/cyfr.db"
        )
      end

      "data/cyfr.db"
    end

  config :arca, Arca.Repo,
    database: database_path,
    pool_size: String.to_integer(env!("CYFR_DB_POOL_SIZE", :string, "5"))

  components_path = env!("CYFR_COMPONENTS_PATH", :string, "components")
  config :arca, :components_path, components_path
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

# Registry Configuration
# Provides authentication credentials for OCI registry access.
# The default registry is always registry.cyfr.run regardless of edition.
# Core edition: the MCP layer enforces registry.cyfr.run for all operations.
# Arx edition: users can specify alternate registries per-operation; this config
# provides credentials for whichever registry matches the configured URL.
# - Both username and password set: authenticated access
# - Neither set: anonymous access (for public registries)
# - Only one set: warning, may fail at runtime
if registry_url = env!("CYFR_REGISTRY_URL", :string, nil) do
  username = env!("CYFR_REGISTRY_USERNAME", :string, nil)
  password = env!("CYFR_REGISTRY_PASSWORD", :string, nil)

  if (username && !password) || (!username && password) do
    IO.puts(
      :stderr,
      "[warning] Registry credentials incomplete - provide both CYFR_REGISTRY_USERNAME and " <>
        "CYFR_REGISTRY_PASSWORD for authenticated access, or neither for anonymous access."
    )
  end

  config :compendium, :registry,
    url: registry_url,
    username: username,
    password: password
else
  # No registry URL set — if credentials are provided, auto-map to registry.cyfr.run
  username = env!("CYFR_REGISTRY_USERNAME", :string, nil)
  password = env!("CYFR_REGISTRY_PASSWORD", :string, nil)

  if username && password do
    config :compendium, :registry,
      url: "registry.cyfr.run",
      username: username,
      password: password
  end
end

# OCI Distribution Configuration
if oci_cache_dir = env!("CYFR_OCI_CACHE_DIR", :string, nil) do
  config :compendium, :oci_cache_dir, oci_cache_dir
end

# JWT Signing Key for Sanctum (required for JWT-based authentication)
if jwt_key = env!("CYFR_JWT_SIGNING_KEY", :string, nil) do
  config :sanctum, :jwt_signing_key, jwt_key
end

# Device Flow Client IDs for Sanctum authentication
# Device Flow only needs client ID, no secret required
if github_id = env!("CYFR_GITHUB_CLIENT_ID", :string, nil) do
  config :sanctum, :github_client_id, github_id
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

  config :sanctum, :edition, String.to_atom(normalized)
end

# License file path for Sanctum Arx
if license_path = env!("CYFR_LICENSE_PATH", :string, nil) do
  config :sanctum, :license_path, license_path
end

# Allowed users (comma-separated emails) — enforced for all auth paths
if allowed_users = env!("CYFR_ALLOWED_USER", :string, nil) do
  users =
    allowed_users
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  config :sanctum, :allowed_users, users
end

# Auto-configure auth provider based on environment
# Priority: explicit config > Sanctum Arx with license > SimpleOAuth with credentials
github_configured? = env!("CYFR_GITHUB_CLIENT_ID", :string, nil) != nil
license_configured? = env!("CYFR_LICENSE_PATH", :string, nil) != nil
oidc_configured? = env!("CYFR_OIDC_ISSUER", :string, nil) != nil
explicit_auth_provider = env!("CYFR_AUTH_PROVIDER", :string, nil)

auth_provider =
  cond do
    # Explicit auth provider configuration takes priority
    explicit_auth_provider == "oidc" ->
      SanctumArx.Auth.OIDC

    explicit_auth_provider == "simple_oauth" ->
      Sanctum.Auth.SimpleOAuth

    # Sanctum Arx: full OIDC with enterprise providers
    license_configured? or oidc_configured? ->
      SanctumArx.Auth.OIDC

    # SimpleOAuth: GitHub for single-user scenarios
    github_configured? ->
      Sanctum.Auth.SimpleOAuth

    # No auth configured - require configuration
    true ->
      raise """
      No authentication provider configured!

      Please configure at least one of the following:
      - CYFR_GITHUB_CLIENT_ID for GitHub OAuth (Device Flow)
      - CYFR_OIDC_ISSUER for enterprise OIDC (requires Sanctum Arx)

      For GitHub, create an OAuth App at https://github.com/settings/developers
      and enable "Device Flow" in the app settings.
      """
  end

config :sanctum, :auth_provider, auth_provider

# Build Ueberauth providers list dynamically
providers = []

providers =
  if github_configured? do
    [{:github, {Ueberauth.Strategy.Github, [default_scope: "user:email"]}} | providers]
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

  config :sanctum, :vault,
    address: vault_addr,
    token: vault_token
end

# cyfr.run REST API URL (search, discover, publisher profiles)
# Defaults to https://cyfr.run. Override for air-gapped deployments
# with an internal cyfr.run instance.
if cyfr_run_api_url = env!("CYFR_RUN_API_URL", :string, nil) do
  config :compendium, :cyfr_run_api_url, cyfr_run_api_url
end

# Sigstore Configuration
if cosign_key = env!("CYFR_COSIGN_KEY", :string, nil) do
  config :locus, :sigstore,
    mode: :keyed,
    key_path: cosign_key,
    password: env!("CYFR_COSIGN_PASSWORD", :string, nil)
else
  config :locus, :sigstore, mode: :keyless
end

if trusted_keys = env!("CYFR_TRUSTED_KEYS", :string, nil) do
  config :opus, :trusted_keys, paths: String.split(trusted_keys, ",")
end

# OpenTelemetry Configuration
# Set CYFR_OTEL_ENABLED=true to enable distributed tracing.
# Traces are exported via OTLP to the endpoint specified by OTEL_EXPORTER_OTLP_ENDPOINT
# (defaults to http://localhost:4318 for HTTP/protobuf).
if env!("CYFR_OTEL_ENABLED", :string, nil) == "true" do
  config :emissary, :opentelemetry_enabled, true

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
