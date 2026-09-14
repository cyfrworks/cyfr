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

  # Treat empty values as unset and apply defaults. Preserve explicit false
  # for booleans and zero for integers.
  env_str = fn key, default -> env!(key, :string?, nil) || default end
  env_int = fn key, default -> env!(key, :integer?, nil) || default end

  # Comma-separated lists: origins, CIDRs, egress targets, operator emails.
  # The split-trim-reject-empty was written out five times; a list that reads
  # one way in four places and another in the fifth is the shape of a
  # security default that only mostly holds.
  env_list = fn key ->
    (env_str.(key, nil) || "")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Reader handed to `Cyfr.RuntimeConfig` so the pure resolvers (auth provider,
  # storage, repo) read the same Dotenvy-merged environment this file does.
  getenv = fn key -> env_str.(key, nil) end

  # A switch is `on`/`off` (or true/false, yes/no, 1/0); an unrecognised
  # spelling refuses the boot rather than reading as the default.
  env_bool = fn key, default ->
    case Cyfr.RuntimeConfig.switch(getenv, key, default) do
      {:ok, value} -> value
      {:error, message} -> raise "[Cyfr] FATAL: #{message}"
    end
  end

  # Evaluate only builder settings in the builder release; application secrets are not required there.
  release_name = env_str.("RELEASE_NAME", nil)

  # Default to info logging in production and debug in development; invalid levels use the default.
  log_level =
    case env_str.("CYFR_LOG_LEVEL", if(config_env() == :prod, do: "info", else: "debug")) do
      level when level in ~w(emergency alert critical error warning notice info debug) ->
        String.to_existing_atom(level)

      other ->
        IO.warn("CYFR_LOG_LEVEL=#{inspect(other)} is not a Logger level — using :info")
        :info
    end

  config :logger, level: log_level

  # JSON log format for structured logging (Datadog, Splunk, ELK, Loki)
  if env_str.("CYFR_LOG_FORMAT", nil) == "json" do
    # Only the format changes. `Config` deep-merges keyword values, so the
    # `metadata:` roster set in config.exs carries through — repeating it
    # here is a second copy that would go stale the first time one moved.
    config :logger, :default_formatter, format: {Cyfr.JsonFormatter, :format}
  end

  if release_name != "builder" do
    # Load the explicit JSON keyring; unset derives a key from CYFR_SECRET_KEY_BASE.
    config :cyfr, :crypto_keyring_json, env_str.("CYFR_CRYPTO_KEYRING", nil)

    # Accept a keyring whose primary differs from the one this database was
    # sealed with, by naming its fingerprint — one boot, on purpose. See
    # `Cyfr.KeyringFingerprint`: accepting records the change, it does not
    # restore decryptability.
    config :cyfr,
           :crypto_keyring_fingerprint_accept,
           env_str.("CYFR_CRYPTO_KEYRING_FINGERPRINT_ACCEPT", nil)

    # Several control planes share this database by design (a cell of
    # nodes). Off, a second live claimant refuses to boot
    # (`Cyfr.ControlPlane`).
    config :cyfr, :cluster, env_bool.("CYFR_CLUSTER", false)

    # Device label attached to registry credentials (unset = hostname).
    config :cyfr, :device_label, env_str.("CYFR_DEVICE_LABEL", nil)

    # Whether the server migrates the database on boot (default: true). Several
    # nodes on one Postgres, or an operator who runs the schema step by hand
    # (`bin/cyfr eval "Cyfr.Release.migrate()"`), turn it off.
    config :cyfr, :auto_migrate, env_bool.("CYFR_AUTO_MIGRATE", true)

    # Whether a pull refuses a component whose OCI signature cannot be
    # verified (default: false — the component is stored as unverified and
    # the recorded attestation is checked again at execution time).
    config :cyfr, :require_signed_pulls, env_bool.("CYFR_REQUIRE_SIGNED_PULLS", false)
  end

  # Concurrent toolchain builds (cargo/npm — a CPU core and hundreds of MB
  # each for minutes). The per-tenant cap keeps one athanor from holding
  # every slot. Shared with the builder release: its service-side limiter
  # reads the same knobs.
  if max_builds = env_int.("CYFR_MAX_CONCURRENT_BUILDS", nil) do
    if max_builds < 1, do: raise("CYFR_MAX_CONCURRENT_BUILDS must be >= 1")
    config :cyfr, :max_concurrent_builds, max_builds
  end

  if tenant_builds = env_int.("CYFR_MAX_CONCURRENT_BUILDS_PER_TENANT", nil) do
    if tenant_builds < 1, do: raise("CYFR_MAX_CONCURRENT_BUILDS_PER_TENANT must be >= 1")
    config :cyfr, :max_concurrent_builds_per_tenant, tenant_builds
  end

  # Build isolation: with CYFR_BUILDER_URL set, `build.compile` POSTs the
  # source map to the builder container instead of running toolchains in
  # this image; CYFR_BUILDER_TOKEN authenticates both ends. The `builder`
  # release sets CYFR_BUILDER_LISTEN=true to serve that endpoint.
  config :cyfr, :builder_url, env_str.("CYFR_BUILDER_URL", nil)
  config :cyfr, :builder_token, env_str.("CYFR_BUILDER_TOKEN", nil)
  config :cyfr, :builder_listen, env_bool.("CYFR_BUILDER_LISTEN", false)
  config :cyfr, :builder_port, env_int.("CYFR_BUILDER_PORT", 4100)
  # The address the builder listens on. The compose builder container is
  # attached to the builder network alone, so every interface there is
  # that network; a builder run outside compose binds one address here.
  config :cyfr, :builder_bind, env_str.("CYFR_BUILDER_BIND", "0.0.0.0")
  # A Cargo home whose registry cache every Rust build starts from, copied
  # into the build's own Cargo home. The builder image sets it to the
  # crates the scaffold depends on; unset, a build fetches every crate.
  config :cyfr, :build_cargo_seed, env_str.("CYFR_BUILD_CARGO_SEED", nil)

  # Whether this server builds components at all — `build.compile` on every
  # surface. An appliance that only runs what it pulled turns it off, and
  # then needs no builder container to boot with authentication on.
  config :cyfr, :builds_enabled, env_bool.("CYFR_BUILDS", true)

  # A hosted server builds in the builder container: with an auth provider
  # configured, builds on and no CYFR_BUILDER_URL, boot refuses unless the
  # operator explicitly accepts cargo/npm running as this service user.
  config :cyfr, :allow_in_process_builds, env_bool.("CYFR_ALLOW_IN_PROCESS_BUILDS", false)

  if release_name != "builder" do
    # A headless node (default: false) serves the API, MCP and public tinctures
    # and no browser surface: every route on the browser pipeline answers 404.
    # Codex signs in through the session tool on /mcp, so it does not notice.
    headless? = env_bool.("CYFR_HEADLESS", false)
    config :cyfr, :headless, headless?

    # Maximum concurrent WASM executions (default: 128)
    # Prevents dirty scheduler exhaustion from too many simultaneous WASM executions.
    # A quarter of the slots is reserved for chain children (a formula's hops);
    # that reserve must hold a chain of the full authority depth (8), so the
    # floor is 32 — below it a deep chain could wait on itself.
    if max_exec = env_int.("CYFR_MAX_CONCURRENT_EXECUTIONS", nil) do
      if max_exec < 32 do
        raise ArgumentError,
              "CYFR_MAX_CONCURRENT_EXECUTIONS must be at least 32 (a quarter of the slots " <>
                "is the child reserve, which must fit a chain of depth 8), got #{max_exec}"
      end

      config :cyfr, :max_concurrent_executions, max_exec
    end

    # Maximum concurrent WASM executions per tenant (default: 16)
    # Bounds the blast radius of one athanor queueing many long-running executions
    if max_tenant_exec = env_int.("CYFR_MAX_CONCURRENT_EXECUTIONS_PER_TENANT", nil) do
      config :cyfr, :max_concurrent_executions_per_tenant, max_tenant_exec
    end

    # MCP transport rate limit, per client IP (default: 120 requests / 60s window).
    # Counts requests and SSE connection opens, not stream duration.
    if mcp_rl_max = env_int.("CYFR_MCP_RATE_LIMIT_MAX", nil) do
      config :cyfr, :mcp_rate_limit_max, mcp_rl_max
    end

    if mcp_rl_window = env_int.("CYFR_MCP_RATE_LIMIT_WINDOW_MS", nil) do
      config :cyfr, :mcp_rate_limit_window_ms, mcp_rl_window
    end

    # Inbound webhooks, per client IP, across every slug (default: 6000/60s).
    # Checked BEFORE the per-slug bucket, so it clamps any `rate_limit` set
    # on a webhooks row above it — raise it when one real sender, egressing
    # from one address, legitimately needs more than this in a minute.
    if hook_ip_max = env_int.("CYFR_WEBHOOK_PER_IP_RATE_LIMIT_MAX", nil) do
      config :cyfr, :webhook_per_ip_rate_limit_max, hook_ip_max
    end

    # The :api bucket's own budget (GET /api/executions/:id/events — SSE
    # reconnects). Unset, it shares the MCP values above; the counters were
    # always separate, the budgets silently were not.
    if v = env_int.("CYFR_API_RATE_LIMIT_MAX", nil) do
      config :cyfr, :api_rate_limit_max, v
    end

    if v = env_int.("CYFR_API_RATE_LIMIT_WINDOW_MS", nil) do
      config :cyfr, :api_rate_limit_window_ms, v
    end

    # Per-caller SSE limits: concurrent streams and lifetime. Defaults are 8 streams and 30 minutes.
    if v = env_int.("CYFR_MCP_SUBSCRIPTION_MAX_CONCURRENT", nil) do
      config :cyfr, :mcp_subscription_max_concurrent, v
    end

    if v = env_int.("CYFR_MCP_SUBSCRIPTION_MAX_MS", nil) do
      config :cyfr, :mcp_subscription_max_ms, v
    end

    if v = env_int.("CYFR_EXECUTION_EVENTS_MAX_CONCURRENT", nil) do
      config :cyfr, :execution_events_max_concurrent, v
    end

    if v = env_int.("CYFR_EXECUTION_EVENTS_MAX_MS", nil) do
      config :cyfr, :execution_events_max_ms, v
    end

    # Webhook replay window (default 300s). A delivery whose `timestamp_header`
    # is further than this from now is refused. Senders differ in how well they
    # keep a clock; the value was a constant nothing could set, so operators
    # facing a drifting sender had no answer short of turning the header off.
    if skew = env_int.("CYFR_WEBHOOK_MAX_SKEW_SECONDS", nil) do
      if skew <= 0, do: raise("CYFR_WEBHOOK_MAX_SKEW_SECONDS must be > 0")
      config :cyfr, :webhook_max_skew_seconds, skew
    end

    # How long delivered webhook idempotency keys are kept (default 86_400s).
    # This is the window a retried delivery is recognised as a duplicate in, so
    # it trades table size against how late a sender may retry.
    if ttl = env_int.("CYFR_WEBHOOK_IDEMPOTENCY_TTL_SECONDS", nil) do
      if ttl <= 0, do: raise("CYFR_WEBHOOK_IDEMPOTENCY_TTL_SECONDS must be > 0")
      config :cyfr, :webhook_idempotency_ttl_seconds, ttl
    end

    # How long `/health/ready` reuses its last probe (default 5000ms). On an
    # object store the write probe is a billable PUT per uncached hit, so a
    # frequent prober is a line item; the code documented this as settable
    # while nothing could set it.
    if ready_ms = env_int.("CYFR_HEALTH_READY_CACHE_MS", nil) do
      if ready_ms < 0, do: raise("CYFR_HEALTH_READY_CACHE_MS must be >= 0")
      config :cyfr, :health_ready_cache_ms, ready_ms
    end

    # Session idle timeout in hours (default 720 / 30 days, 0 = infinite / never expires, minimum 1).
    # Sessions slide forward on activity, so this is an idle timeout rather than a hard cap.
    if ttl_hours = env_int.("CYFR_SESSION_TTL_HOURS", nil) do
      if ttl_hours < 0 do
        raise "CYFR_SESSION_TTL_HOURS must be >= 0 (0 = infinite, minimum non-zero is 1)"
      end

      config :cyfr, :session_ttl_hours, ttl_hours
    end

    # CYFR_SECRET_KEY_BASE overrides the configured key. Required and nonblank
    # in production; dev/test may use the key from their config files.
    env_key_base = env_str.("CYFR_SECRET_KEY_BASE", nil)

    if env_key_base do
      config :cyfr, :secret_key_base, env_key_base
    end

    # Apply origin and proxy settings in every environment. Extra MCP origins
    # extend the configured allowlist, including development localhost defaults.
    config :cyfr, :mcp_extra_origins, env_list.("CYFR_MCP_ALLOWED_ORIGINS")

    behind_proxy? = env_bool.("CYFR_BEHIND_PROXY", false)

    if behind_proxy? do
      # The client IP is taken right-to-left from the XFF chain, stripping the
      # trusted proxies (Sanctum.ClientIp). With one proxy layer (the shipped
      # Caddy) the default of 1 hop is correct; stacking more layers requires
      # raising CYFR_TRUSTED_PROXY_HOPS to match, or listing the proxies in
      # CYFR_TRUSTED_PROXY_CIDRS (comma-separated IPs/CIDRs, takes precedence).
      config :cyfr, :trust_x_forwarded_for, true

      config :cyfr, :trusted_proxy_hops, env_int.("CYFR_TRUSTED_PROXY_HOPS", 1)

      case env_list.("CYFR_TRUSTED_PROXY_CIDRS") do
        [] -> :ok
        cidrs -> config :cyfr, :trusted_proxy_cidrs, cidrs
      end
    end

    if config_env() == :prod do
      secret_key_base =
        env_key_base ||
          raise """
          environment variable CYFR_SECRET_KEY_BASE is missing.
          You can generate one by calling: mix phx.gen.secret
          """

      # Reject invalid bind addresses at boot.
      parse_ip = fn var, ip_string ->
        case :inet.parse_address(String.to_charlist(ip_string)) do
          {:ok, ip_tuple} ->
            ip_tuple

          {:error, _} ->
            raise "environment variable #{var} is not a valid IP address: #{inspect(ip_string)}"
        end
      end

      emissary_bind = parse_ip.("CYFR_BIND_ADDRESS", env_str.("CYFR_BIND_ADDRESS", "0.0.0.0"))

      host = env_str.("CYFR_HOST", "localhost")
      port = env_int.("CYFR_PORT", 4000)

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

      # Allow loopback origins only on this server's configured port.
      localhost_origins = [
        "http://localhost:#{port}",
        "https://localhost:#{port}",
        "http://127.0.0.1:#{port}",
        "https://127.0.0.1:#{port}",
        "http://[::1]:#{port}",
        "https://[::1]:#{port}"
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
      # check_origin above; the CYFR_MCP_ALLOWED_ORIGINS extras are appended
      # by Cyfr.RuntimeConfig in every env (hoisted above the prod block).
      config :cyfr, :mcp_allowed_origins, host_origins ++ localhost_origins

      # Derive signing salts from secret_key_base (or use explicit env overrides)
      emissary_salt =
        env_str.("CYFR_EMISSARY_SESSION_SALT", nil) ||
          :crypto.hash(:sha256, "emissary_session" <> secret_key_base)
          |> Base.url_encode64(padding: false)
          |> binary_part(0, 16)

      lv_salt =
        env_str.("CYFR_LV_SALT", nil) ||
          :crypto.hash(:sha256, "live_view" <> secret_key_base)
          |> Base.url_encode64(padding: false)
          |> binary_part(0, 16)

      config :cyfr, :emissary_session_salt, emissary_salt
      config :cyfr, EmissaryWeb.Endpoint, live_view: [signing_salt: lv_salt]

      # Session cookies must be secure in production (HTTPS-only).
      # Dev/test leave this false so http://localhost works.
      config :cyfr, :cookie_secure, true

      # Proxy trust is parsed above for every environment. Emit this
      # configuration warning only in production.
      unless behind_proxy? do
        IO.puts(
          :stderr,
          "[warning] CYFR is running plain HTTP in production. " <>
            "Set CYFR_BEHIND_PROXY=true if behind a TLS-terminating reverse proxy, " <>
            "and set CYFR_BIND_ADDRESS=127.0.0.1 to bind only to localhost."
        )
      end
    end

    # Resolve runtime and seed paths in dev and prod. Defaults are relative
    # to the working directory; start development from the umbrella root.
    # Tests keep their temporary storage roots.
    paths =
      case Cyfr.RuntimeConfig.resolve_paths(getenv) do
        {:ok, paths} -> paths
        {:error, message} -> raise message
      end

    config :cyfr, :base_path, paths.base_path
    config :cyfr, :seed_path, paths.seed_path

    # Reject .env adapter settings that disagree with the compile-time CYFR_DATABASE choice.
    built_adapter = Cyfr.RuntimeConfig.repo_adapter()

    requested_database = getenv.("CYFR_DATABASE")

    requested_adapter =
      case requested_database && String.downcase(requested_database) do
        nil ->
          built_adapter

        "" ->
          built_adapter

        "sqlite" ->
          Ecto.Adapters.SQLite3

        "postgres" ->
          Ecto.Adapters.Postgres

        other ->
          raise ~s([Cyfr] FATAL: unknown CYFR_DATABASE=#{other}; expected "sqlite" or "postgres")
      end

    if requested_adapter != built_adapter do
      raise """
      [Cyfr] FATAL: CYFR_DATABASE asks for #{inspect(requested_adapter)} but this \
      release was built for #{inspect(built_adapter)}.

      The database adapter is chosen when the release is COMPILED, not when it \
      boots, so it is the one setting `.env` cannot change. Set CYFR_DATABASE in \
      the build environment and rebuild, or remove it from `.env`/the environment \
      so the built adapter stands.
      """
    end

    # Database connection config. The adapter is selected at compile time in
    # config.exs from CYFR_DATABASE; here we supply connection parameters for
    # whichever adapter was built — gated so SQLite-only keys (journal_mode,
    # busy_timeout) never bleed into a Postgres build and vice versa.
    case built_adapter do
      Ecto.Adapters.SQLite3 ->
        pool_size =
          case Cyfr.RuntimeConfig.resolve_pool_size(getenv) do
            {:ok, pool_size} -> pool_size
            {:error, message} -> raise message
          end

        config :cyfr, Arca.Repo,
          database: paths.database_path,
          pool_size: pool_size,
          journal_mode: :wal,
          busy_timeout: Cyfr.RuntimeConfig.sqlite_busy_timeout_ms()

      Ecto.Adapters.Postgres ->
        # A Postgres build carries no connection config from config.exs, so a
        # CYFR_DATABASE_URL is required — its absence is a hard boot error
        # rather than a silent attempt against a default localhost. (The
        # builder release skips this whole block: it starts no Repo and must
        # not be handed database credentials at all.)
        case Cyfr.RuntimeConfig.resolve_postgres(getenv) do
          {:ok, repo_opts} -> config :cyfr, Arca.Repo, repo_opts
          {:error, message} -> raise message
        end
    end

    # Browser CORS allowlist. Authenticated releases require an explicit value.
    # Empty denies cross-origin requests; unset retains the wildcard default.
    if env_str.("CYFR_CORS_ALLOWED_ORIGINS", nil) do
      config :cyfr, :cors_allowed_origins, env_list.("CYFR_CORS_ALLOWED_ORIGINS")
    end

    # Private egress: the hostnames, IPs or CIDRs on the private network that
    # the *server's own* outbound requests may reach — an MCP server on the
    # compose network, an internal registry or IdP, a vault OAuth token
    # endpoint. Empty refuses every private target; the link-local metadata
    # range is refused regardless.
    #
    # It does not reach components. A guest's HTTP calls are checked against
    # its consent's `egress.private_ips` (`Opus.EdgeGuard.allows_private_ip?/2`)
    # and nothing else, so a LAN device is reachable from a chain only as an
    # MCP server on this list, never as a URL the bundled http catalyst fetches.
    config :cyfr, :private_egress_targets, env_list.("CYFR_PRIVATE_EGRESS_TARGETS")

    # GitHub and Google sign in by device flow (CLI and Prism). GitHub needs
    # only a client ID; Google needs a client ID and secret.
    github_id = env_str.("CYFR_GITHUB_CLIENT_ID", nil)
    google_id = env_str.("CYFR_GOOGLE_CLIENT_ID", nil)
    google_secret = env_str.("CYFR_GOOGLE_CLIENT_SECRET", nil)

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
    # `none` means no registry: an appliance that runs only what it ships.
    # Sign-in never needs one (`Sanctum.SignIn`); pulls and publishing refuse
    # with a typed error (`Compendium.RegistryHost`).
    registry_url_config = env_str.("CYFR_REGISTRY_URL", "cyfr.run")
    config :cyfr, :registry_url, registry_url_config

    # The address this instance is reachable at from outside — needed to hand a
    # webhook sender an absolute URL, which behind a proxy or a tunnel is
    # neither the bind address nor any request's Host. Unset means the console
    # and the CLI show the path and say to set this.
    config :cyfr, :public_url, env_str.("CYFR_PUBLIC_URL", nil)

    oci_registry_url_config =
      env_str.(
        "CYFR_OCI_REGISTRY_URL",
        if(registry_url_config == "none", do: "none", else: "registry.#{registry_url_config}")
      )

    config :cyfr, :oci_registry_url, oci_registry_url_config

    # GitHub device flow needs only its client ID (read above).
    if github_id do
      config :cyfr, :github_client_id, github_id
    end

    # Platform-admin email allowlist. Addresses are normalized to lowercase before matching.
    platform_admins = "CYFR_PLATFORM_ADMIN_EMAILS" |> env_list.() |> Enum.map(&String.downcase/1)

    config :cyfr, :platform_admin_emails, platform_admins

    # Account caps: unset disables limits except pairs (200) and threads (1000); 0 disables those defaults.
    config :cyfr, :caps,
      max_athanors: env_int.("CYFR_MAX_ATHANORS", nil),
      max_groups_per_person: env_int.("CYFR_MAX_GROUPS_PER_PERSON", nil),
      max_pairs_per_person: env_int.("CYFR_MAX_PAIRS_PER_PERSON", 200),
      max_members_per_group: env_int.("CYFR_MAX_MEMBERS_PER_GROUP", nil),
      max_threads_per_athanor: env_int.("CYFR_MAX_THREADS_PER_ATHANOR", 1000),
      mint_per_hour: env_int.("CYFR_MINT_PER_HOUR", nil),
      athanor_storage_bytes: env_int.("CYFR_ATHANOR_STORAGE_BYTES", nil)

    # Select the auth provider from explicit configuration, then OAuth
    # credentials. Reject unsatisfied explicit settings. Without a provider,
    # requests are anonymous and tenant-scoped routes are denied.
    auth_provider =
      case Cyfr.RuntimeConfig.resolve_auth_provider(getenv) do
        {:ok, provider} -> provider
        {:error, message} -> raise message
      end

    config :cyfr, :auth_provider, auth_provider

    # A headless node has no browser page, and an external OIDC provider signs
    # people in through one (the CLI's device flow is the built-in provider's):
    # together they leave no way in. Refuse the pair rather than boot a box
    # nobody can log in to.
    if headless? and auth_provider == Sanctum.Auth.OIDC do
      raise "CYFR_HEADLESS=true cannot be combined with CYFR_AUTH_PROVIDER=oidc: " <>
              "an OIDC provider signs in through the browser page a headless node refuses"
    end

    # Generic OIDC, the one browser-callback sign-in. When selected, register
    # the issuer for ueberauth_oidcc and its strategy. CYFR_OIDC_ISSUER is also
    # pinned at `:cyfr, :oidc_issuer` — the single source both the boot
    # reserved-host check (`Cyfr.Application.validate_oidc_issuer_config!/0`) and
    # the login id builder (`Sanctum.Auth.OIDC.resolve_issuer/0`) read.
    if auth_provider == Sanctum.Auth.OIDC do
      {:ok, oidc} = Cyfr.RuntimeConfig.oidc_config(getenv)

      config :cyfr, :oidc_issuer, oidc.issuer
      config :ueberauth_oidcc, :issuers, [%{name: :cyfr_oidc, issuer: oidc.issuer}]

      # Provider key `:oidcc` (not `:oidc`) so `auth.provider` matches the
      # generic-OIDC email-verification lane (`Sanctum.Auth.EmailVerification`)
      # and the canonical `oidcc|<iss>|<sub>` id form.
      config :ueberauth, Ueberauth,
        providers: [
          oidcc:
            {Ueberauth.Strategy.Oidcc,
             issuer: :cyfr_oidc, client_id: oidc.client_id, client_secret: oidc.client_secret}
        ]
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

    # Sigstore Configuration. Keyless verification checks the signing
    # certificate against a named identity and issuer (regexps); without both,
    # `Compendium.Cosign` refuses rather than accepting any signer at all.
    if cosign_key = env_str.("CYFR_COSIGN_KEY", nil) do
      config :cyfr, :sigstore,
        verification: :keyed,
        key_path: cosign_key,
        password: env_str.("CYFR_COSIGN_PASSWORD", nil)
    else
      config :cyfr, :sigstore,
        verification: :keyless,
        identity: env_str.("CYFR_COSIGN_IDENTITY", nil),
        issuer: env_str.("CYFR_COSIGN_ISSUER", nil)
    end

    # Prometheus metrics — the /metrics endpoint is unauthenticated, so it is
    # opt-in. Bind to a private interface or proxy-allowlist it when enabled.
    if env_bool.("CYFR_PROMETHEUS_METRICS", false) do
      config :cyfr, :prometheus_metrics_enabled, true
    end

    # Bearer token for the /metrics scrape. Unset means the operator chose
    # network-level protection (private bind / proxy allowlist) — the
    # endpoint's original posture.
    if metrics_token = env_str.("CYFR_METRICS_TOKEN", nil) do
      config :cyfr, :metrics_token, metrics_token
    end

    # OpenTelemetry Configuration
    # Set CYFR_OTEL_ENABLED=on to enable distributed tracing.
    # Traces are exported via OTLP to the endpoint specified by OTEL_EXPORTER_OTLP_ENDPOINT
    # (defaults to http://localhost:4318 for HTTP/protobuf).
    if env_bool.("CYFR_OTEL_ENABLED", false) do
      config :cyfr, :opentelemetry_enabled, true

      config :opentelemetry,
        resource: %{service: %{name: "cyfr"}},
        span_processor: :batch,
        traces_exporter: :otlp

      config :opentelemetry_exporter,
        otlp_protocol: :http_protobuf,
        otlp_endpoint: env_str.("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")
    else
      config :opentelemetry,
        traces_exporter: :none
    end
  end
end
