import Config

# Arx Edition Runtime Configuration
# This file is loaded by the cyfr_arx release

parse_integer = fn env_var, raw ->
  case Integer.parse(raw) do
    {n, ""} -> n
    _ -> raise "Invalid integer for #{env_var}: #{inspect(raw)}"
  end
end

# Force Arx edition for SanctumArx
config :cyfr, :edition, :arx

# Set OIDC as the auth provider for enterprise
config :cyfr, :auth_provider, SanctumArx.Auth.OIDC

# All standard runtime configuration from runtime.exs applies
# This file adds enterprise-specific defaults

# Required configuration for production
if config_env() == :prod do
  secret_key_base =
    System.get_env("CYFR_SECRET_KEY_BASE") ||
      raise """
      environment variable CYFR_SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("CYFR_HOST") || "localhost"
  port = parse_integer.("CYFR_PORT", System.get_env("CYFR_PORT") || "4000")

  config :cyfr, EmissaryWeb.Endpoint,
    url: [host: host, port: port],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    server: true

  # Derive signing salts from secret_key_base (or use explicit env overrides)
  emissary_salt = System.get_env("CYFR_EMISSARY_SESSION_SALT") ||
    (:crypto.hash(:sha256, "emissary_session" <> secret_key_base)
     |> Base.url_encode64(padding: false) |> binary_part(0, 16))

  prism_salt = System.get_env("CYFR_PRISM_SESSION_SALT") ||
    (:crypto.hash(:sha256, "prism_session" <> secret_key_base)
     |> Base.url_encode64(padding: false) |> binary_part(0, 16))

  prism_lv_salt = System.get_env("CYFR_PRISM_LV_SALT") ||
    (:crypto.hash(:sha256, "prism_live_view" <> secret_key_base)
     |> Base.url_encode64(padding: false) |> binary_part(0, 16))

  config :cyfr, :emissary_session_salt, emissary_salt
  config :cyfr, :prism_session_salt, prism_salt
  config :cyfr, PrismWeb.Endpoint, live_view: [signing_salt: prism_lv_salt]

  # Database configuration - Enterprise defaults to Postgres path support
  database_path = System.get_env("CYFR_DATABASE_PATH") || "data/cyfr.db"

  config :cyfr, Arca.Repo,
    database: database_path,
    pool_size: parse_integer.("CYFR_DB_POOL_SIZE", System.get_env("CYFR_DB_POOL_SIZE") || "10"),
    journal_mode: :wal,
    busy_timeout: 5_000

  components_path = (System.get_env("CYFR_COMPONENTS_PATH") || "components") |> Path.expand()
  config :cyfr, :components_path, components_path
end

# CORS allowed origins for Arx — comma-separated list
if cors_origins = System.get_env("CYFR_CORS_ORIGINS") do
  config :cyfr, :cors_allowed_origins,
    cors_origins |> String.split(",") |> Enum.map(&String.trim/1)
end

# License file path - default to /etc/cyfr/license.sig for enterprise
config :cyfr, :license_path,
  System.get_env("CYFR_LICENSE_PATH") || "/etc/cyfr/license.sig"

# Ueberauth provider configuration for enterprise
config :ueberauth, Ueberauth,
  providers: [
    github: {Ueberauth.Strategy.Github, [default_scope: "user:email"]},
    google: {Ueberauth.Strategy.Google, [default_scope: "email profile"]}
  ]

# OIDC Provider configuration
# In Arx mode with OIDC auth, the issuer URL is required at boot.
if oidc_issuer = System.get_env("CYFR_OIDC_ISSUER") do
  config :ueberauth, Ueberauth.Strategy.OIDCC,
    issuer: oidc_issuer

  if client_id = System.get_env("CYFR_OIDC_CLIENT_ID") do
    config :ueberauth, Ueberauth.Strategy.OIDCC,
      client_id: client_id,
      client_secret: System.get_env("CYFR_OIDC_CLIENT_SECRET")
  end
else
  # If auth_provider is OIDC but no issuer is configured, fail fast at boot
  if System.get_env("CYFR_AUTH_PROVIDER") == "oidc" do
    raise """
    [Arx] CYFR_AUTH_PROVIDER=oidc but CYFR_OIDC_ISSUER is not set.
    OIDC authentication requires an issuer URL.
    Set CYFR_OIDC_ISSUER to your identity provider's issuer URL.
    """
  end
end

# GitHub OAuth
if github_id = System.get_env("CYFR_GITHUB_CLIENT_ID") do
  config :ueberauth, Ueberauth.Strategy.Github.OAuth,
    client_id: github_id,
    client_secret: System.get_env("CYFR_GITHUB_CLIENT_SECRET")
end

# Google OAuth
if google_id = System.get_env("CYFR_GOOGLE_CLIENT_ID") do
  config :ueberauth, Ueberauth.Strategy.Google.OAuth,
    client_id: google_id,
    client_secret: System.get_env("CYFR_GOOGLE_CLIENT_SECRET")
end

# Registry Configuration (post-auth-refactor two-knob model).
#
# Arx deployments override the default cyfr.run apex by setting one or both of:
#   CYFR_REGISTRY_URL      — REST API host (e.g. "api.acme.com"); default "cyfr.run"
#   CYFR_OCI_REGISTRY_URL  — OCI Distribution host (e.g. "registry.acme.com");
#                            default "registry.#{registry_url}"
#
# Legacy CYFR_REGISTRY_USERNAME / CYFR_REGISTRY_PASSWORD env vars are NO LONGER
# read anywhere — auth is per-user push tokens issued via /v1/identity/probe,
# stored in CredentialStore. See auth_refactor.md §Config consolidation.
if registry_url = System.get_env("CYFR_REGISTRY_URL") do
  config :cyfr, :registry_url, registry_url
end

if oci_url = System.get_env("CYFR_OCI_REGISTRY_URL") do
  config :cyfr, :oci_registry_url, oci_url
end

# JWT Signing Key for Sanctum
# JWT auth won't work without this, but session-based auth is unaffected.
if jwt_key = System.get_env("CYFR_JWT_SIGNING_KEY") do
  config :cyfr, :jwt_signing_key, jwt_key
else
  if config_env() == :prod do
    IO.puts(
      :stderr,
      "[warning] CYFR_JWT_SIGNING_KEY is not set in Arx mode. " <>
        "JWT-based authentication will be unavailable. " <>
        "Session-based authentication will still work."
    )
  end
end

# Vault Configuration (Enterprise feature)
if vault_addr = System.get_env("CYFR_VAULT_ADDR") do
  config :cyfr, :vault,
    address: vault_addr,
    token: System.get_env("CYFR_VAULT_TOKEN"),
    enabled: true
end

# SIEM Forwarding Configuration (Enterprise feature)
if siem_endpoint = System.get_env("CYFR_SIEM_ENDPOINT") do
  config :cyfr, :siem,
    endpoint: siem_endpoint,
    api_key: System.get_env("CYFR_SIEM_API_KEY"),
    enabled: true
end

# Sigstore Configuration
if cosign_key = System.get_env("CYFR_COSIGN_KEY") do
  config :cyfr, :sigstore,
    mode: :keyed,
    key_path: cosign_key,
    password: System.get_env("CYFR_COSIGN_PASSWORD")
else
  config :cyfr, :sigstore,
    mode: :keyless
end

if trusted_keys = System.get_env("CYFR_TRUSTED_KEYS") do
  config :cyfr, :trusted_keys,
    paths: String.split(trusted_keys, ",")
end
