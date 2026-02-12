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

# Session TTL in hours (default 24)
if session_ttl = env!("CYFR_SESSION_TTL_HOURS", :string, nil) do
  config :sanctum, :session_ttl_hours, String.to_integer(session_ttl)
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
    Application.get_env(:sanctum, :secret_key_base) ||
      raise """
      environment variable CYFR_SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = env!("CYFR_HOST", :string, "localhost")
  port = String.to_integer(env!("CYFR_PORT", :string, "4000"))

  config :emissary, EmissaryWeb.Endpoint,
    url: [host: host, port: port],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    server: true

  # Database configuration
  database_path = env!("CYFR_DATABASE_PATH", :string, "data/cyfr.db")

  config :arca, Arca.Repo,
    database: database_path,
    pool_size: String.to_integer(env!("CYFR_DB_POOL_SIZE", :string, "5"))
end

# OIDC Provider configuration (all environments)
if oidc_issuer = env!("CYFR_OIDC_ISSUER", :string, nil) do
  config :ueberauth, Ueberauth.Strategy.OIDCC,
    issuer: oidc_issuer

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
# Device Flow (CLI) only needs client ID - no secret required
# Server-side OAuth (web login) requires both client ID and secret
google_id = env!("CYFR_GOOGLE_CLIENT_ID", :string, nil)
google_secret = env!("CYFR_GOOGLE_CLIENT_SECRET", :string, nil)

if google_id && google_secret do
  config :ueberauth, Ueberauth.Strategy.Google.OAuth,
    client_id: google_id,
    client_secret: google_secret
end

# Registry Configuration
# Supports authenticated or anonymous registry access:
# - Both username and password set: authenticated access
# - Neither set: anonymous access (for public registries)
# - Only one set: warning, may fail at runtime
if registry_url = env!("CYFR_REGISTRY_URL", :string, nil) do
  username = env!("CYFR_REGISTRY_USERNAME", :string, nil)
  password = env!("CYFR_REGISTRY_PASSWORD", :string, nil)

  if (username && !password) || (!username && password) do
    IO.warn(
      "Registry credentials incomplete - provide both CYFR_REGISTRY_USERNAME and " <>
        "CYFR_REGISTRY_PASSWORD for authenticated access, or neither for anonymous access."
    )
  end

  config :compendium, :registry,
    url: registry_url,
    username: username,
    password: password
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

if google_id = env!("CYFR_GOOGLE_CLIENT_ID", :string, nil) do
  config :sanctum, :google_client_id, google_id
end

# Sanctum Edition Configuration
# CYFR_EDITION: "sanctum" (default) or "arx"
if edition = env!("CYFR_EDITION", :string, nil) do
  config :sanctum, :edition, String.to_atom(edition)
end

# License file path for Sanctum Arx
if license_path = env!("CYFR_LICENSE_PATH", :string, nil) do
  config :sanctum, :license_path, license_path
end

# Allowed users for SimpleOAuth (comma-separated emails)
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
google_configured? = env!("CYFR_GOOGLE_CLIENT_ID", :string, nil) != nil
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

    # SimpleOAuth: GitHub/Google for single-user scenarios
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
    IO.warn(
      "CYFR_VAULT_ADDR is set but CYFR_VAULT_TOKEN is missing. " <>
        "Vault operations may fail without authentication."
    )
  end

  config :sanctum, :vault,
    address: vault_addr,
    token: vault_token
end

# Sigstore Configuration
if cosign_key = env!("CYFR_COSIGN_KEY", :string, nil) do
  config :locus, :sigstore,
    mode: :keyed,
    key_path: cosign_key,
    password: env!("CYFR_COSIGN_PASSWORD", :string, nil)
else
  config :locus, :sigstore,
    mode: :keyless
end

if trusted_keys = env!("CYFR_TRUSTED_KEYS", :string, nil) do
  config :opus, :trusted_keys,
    paths: String.split(trusted_keys, ",")
end
