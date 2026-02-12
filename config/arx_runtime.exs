import Config

# Arx Edition Runtime Configuration
# This file is loaded by the cyfr_arx release

# Force Arx edition for SanctumArx
config :sanctum_arx, :edition, :arx

# Set OIDC as the auth provider for enterprise
config :sanctum, :auth_provider, SanctumArx.Auth.OIDC

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
  port = String.to_integer(System.get_env("CYFR_PORT") || "4000")

  config :emissary, EmissaryWeb.Endpoint,
    url: [host: host, port: port],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    server: true

  # Database configuration - Enterprise defaults to Postgres path support
  database_path = System.get_env("CYFR_DATABASE_PATH") || "priv/cyfr.db"

  config :arca, Arca.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("CYFR_DB_POOL_SIZE") || "10")
end

# License file path - default to /etc/cyfr/license.sig for enterprise
config :sanctum_arx, :license_path,
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
  config :compendium, :registry,
    url: registry_url,
    username: System.get_env("CYFR_REGISTRY_USERNAME"),
    password: System.get_env("CYFR_REGISTRY_PASSWORD")
end

# JWT Signing Key for Sanctum
if jwt_key = System.get_env("CYFR_JWT_SIGNING_KEY") do
  config :sanctum, :jwt_signing_key, jwt_key
end

# Vault Configuration (Enterprise feature)
if vault_addr = System.get_env("CYFR_VAULT_ADDR") do
  config :sanctum_arx, :vault,
    address: vault_addr,
    token: System.get_env("CYFR_VAULT_TOKEN"),
    enabled: true
end

# SIEM Forwarding Configuration (Enterprise feature)
if siem_endpoint = System.get_env("CYFR_SIEM_ENDPOINT") do
  config :sanctum_arx, :siem,
    endpoint: siem_endpoint,
    api_key: System.get_env("CYFR_SIEM_API_KEY"),
    enabled: true
end

# Sigstore Configuration
if cosign_key = System.get_env("CYFR_COSIGN_KEY") do
  config :locus, :sigstore,
    mode: :keyed,
    key_path: cosign_key,
    password: System.get_env("CYFR_COSIGN_PASSWORD")
else
  config :locus, :sigstore,
    mode: :keyless
end

if trusted_keys = System.get_env("CYFR_TRUSTED_KEYS") do
  config :opus, :trusted_keys,
    paths: String.split(trusted_keys, ",")
end
