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
if oidc_issuer = System.get_env("CYFR_OIDC_ISSUER") do
  config :ueberauth, Ueberauth.Strategy.OIDCC,
    issuer: oidc_issuer

  if client_id = System.get_env("CYFR_OIDC_CLIENT_ID") do
    config :ueberauth, Ueberauth.Strategy.OIDCC,
      client_id: client_id,
      client_secret: System.get_env("CYFR_OIDC_CLIENT_SECRET")
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

# Registry Configuration
if registry_url = System.get_env("CYFR_REGISTRY_URL") do
  config :cyfr, :registry,
    url: registry_url,
    username: System.get_env("CYFR_REGISTRY_USERNAME"),
    password: System.get_env("CYFR_REGISTRY_PASSWORD")
end

# JWT Signing Key for Sanctum
if jwt_key = System.get_env("CYFR_JWT_SIGNING_KEY") do
  config :cyfr, :jwt_signing_key, jwt_key
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
