# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
import Config

if config_env() != :test do
  import Dotenvy

  # The one .env file: at RELEASE_ROOT for a release, else at the project
  # root.
  env_dir = System.get_env("RELEASE_ROOT") || File.cwd!()
  env_files = [Path.join(env_dir, ".env")]

  # The names and values the .env file alone assigns, read without the
  # side effect the merged read below keeps, or nil when there is no .env
  # file to read, as in the compose container, whose .env arrives through
  # `env_file` as its process environment. The unknown-name refusal holds
  # a file to a stricter roster than the process environment a shell
  # exports, and the access settings' source rules hold the file to the environment
  # that overrides it (below). Both reads keep every value literal and run
  # no `$(…)` (`Cyfr.EnvFiles`).
  file_env =
    if Enum.any?(env_files, &File.regular?/1),
      do: Cyfr.EnvFiles.source!(env_files, side_effect: false)

  sourced = Cyfr.EnvFiles.source!(env_files ++ [System.get_env()])

  # Runtime configuration for CYFR
  # This file is executed at runtime, not compile time

  # Treat empty values as unset and apply defaults.
  env_str = fn key, default -> env!(key, :string?, nil) || default end

  # Comma-separated lists: origins, CIDRs, egress targets, operator emails,
  # each split, trimmed and stripped of empty entries by this one reader.
  env_list = fn key ->
    (env_str.(key, nil) || "")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Reader handed to `Cyfr.RuntimeConfig` so the pure resolvers (auth provider,
  # storage, repo) read the same Dotenvy-merged environment this file does.
  getenv = fn key -> env_str.(key, nil) end

  # A switch is `on` or `off`; any other spelling refuses the boot rather
  # than reading as the default (`Prima.EnvValue.switch/3`).
  env_bool = fn key, default ->
    case Prima.EnvValue.switch(getenv, key, default) do
      {:ok, value} -> value
      {:error, message} -> raise "[Cyfr] FATAL: #{message}"
    end
  end

  # The log format: `json` for structured logging (Datadog, Splunk, ELK,
  # Loki), unset for plain text; any other value refuses the boot.
  case env_str.("CYFR_LOG_FORMAT", nil) do
    nil ->
      :ok

    "json" ->
      # Only the format changes. `Config` deep-merges keyword values, so the
      # `metadata:` roster set in config.exs carries through.
      config :logger, :default_formatter, format: {Prima.JsonFormatter, :format}

    other ->
      raise "[Cyfr] FATAL: CYFR_LOG_FORMAT=#{inspect(other)} is not a log format; " <>
              "use json, or leave it unset for plain text."
  end

  # The pinned wasm-tools every component is validated with
  # (`Prima.ComponentFeatures`), by absolute path; the application checks
  # it as it starts, and a path naming no executable refuses the boot.
  if wasm_tools = env_str.("CYFR_WASM_TOOLS", nil) do
    config :prima, :wasm_tools, wasm_tools
  end

  # The root the runtime's keys derive from (`Prima.WorkerAuth`): 32
  # random bytes as 64 hexadecimal digits (`openssl rand -hex 32`), the one
  # secret `mix cyfr.locus.runtime_key <service_id>` derives a worker
  # service's key from. A malformed root refuses the boot. Unset, no worker
  # service can authenticate to this server, so no component runs, and the
  # boot says so. A `mix` boot is no exception: it runs CYFR alone, and its
  # runtime is a container holding a key derived from this root
  # (CONTRIBUTING.md, "Running from source"). This file never evaluates
  # for the `locus` release, which `config/locus_runtime.exs` configures.
  worker_root =
    case env_str.("CYFR_LOCUS_RUNTIME_ROOT", nil) do
      nil ->
        IO.puts(
          :stderr,
          "[warning] CYFR_LOCUS_RUNTIME_ROOT is not set: no worker service can authenticate to " <>
            "this server, so no component runs. Generate one with `openssl rand -hex 32` " <>
            "and give each worker service the key `mix cyfr.locus.runtime_key` derives from it."
        )

        nil

      text ->
        case Prima.MacEnvelope.decode_root(text) do
          {:ok, root} ->
            root

          :error ->
            raise "[Cyfr] FATAL: CYFR_LOCUS_RUNTIME_ROOT must be exactly 64 hexadecimal " <>
                    "digits (32 bytes); generate one with `openssl rand -hex 32`"
        end
    end

  # Where CYFR's host API listener binds (`Opus.HostListener`):
  # the address and port the worker services post their host calls and
  # exit reports to, and CYFR_HOST_API_URL, the address a worker reaches
  # this member at, which every assignment it issues carries. Default
  # loopback, port 4300 and no address; a set value that is not an
  # address, not a port or not a base URL refuses the boot.
  host_api =
    case Cyfr.RuntimeConfig.resolve_host_api(getenv) do
      {:ok, host_api} -> host_api
      {:error, message} -> raise "[Cyfr] FATAL: #{message}"
    end

  # Every name this boot reads is declared once (`Cyfr.Platform.Settings.Roster`):
  # a platform setting, a deployment variable, or a name compose reads and
  # no release does. A `CYFR_*` name the .env files assign that none of
  # them declares refuses the boot naming it, and so does one in the
  # process environment unless another program owns it (the CLI, the
  # installer, the test harness).
  roster = Cyfr.Platform.Settings.Roster

  case roster.unknown(Map.keys(file_env || %{}), Map.keys(System.get_env())) do
    [] -> :ok
    names -> raise "[Cyfr] FATAL: " <> roster.refusal(names)
  end

  # How this home is reached (`Cyfr.RuntimeConfig.resolve_access/1`):
  # CYFR_ACCESS in .env, and every setting it implies, read from the names
  # the .env files assign and the merged environment. A release without a
  # mode, a setting the mode contradicts, the compose file's assertion
  # assigned in .env, or a loopback listener bound off the loopback
  # without it refuses the boot with the sentence that names its fix
  # (`Prima.Refusal`). A development or test boot without a mode is
  # `local`: the dev default, which a release never takes.
  access =
    case Cyfr.RuntimeConfig.resolve_access(%{
           file: file_env,
           process: sourced,
           release?: Cyfr.RuntimeConfig.release?()
         }) do
      {:ok, access} ->
        access

      {:error, %{code: code, payload: payload}} ->
        raise "[Cyfr] FATAL: " <> Prima.Refusal.message({code, payload})
    end

  # Every platform setting whose variable is set: read by the strict
  # reader, validated by the roster's validator (a set value that does
  # not pass refuses the boot naming it), and recorded as this member's
  # environment pin. An unset variable pins nothing: the stored row or the
  # default stands.
  settings =
    for entry <- roster.entries() do
      case roster.read(entry, getenv) do
        {:ok, value} -> {entry, value}
        {:error, message} -> raise "[Cyfr] FATAL: #{message}"
      end
    end

  config :cyfr,
         :deployment_pinned,
         Enum.sort(for({entry, value} <- settings, value != nil, do: {entry.key, value}))

  # Settings that bound each other (the recovery reserve below the log
  # quota) hold together where this environment pins both, and a refusal
  # names the variables. A pin is held to a side it leaves unpinned only
  # when the settings process settles the pins against the store, which
  # this file cannot read: a stored value, not the default, may stand
  # there (`Cyfr.Platform.Settings`). A stored value is held to the bound
  # where it is written (`Cyfr.Platform.Settings.set/4`).
  pinned = for {entry, value} <- settings, value != nil, into: %{}, do: {entry.key, value}

  case roster.check_pinned(pinned, %{}) do
    :ok -> :ok
    {:error, sentence} -> raise "[Cyfr] FATAL: #{sentence}."
  end

  # A restart-scoped setting (the execution slots) is read once at boot
  # from the application environment, so a set value is written there
  # too; unset, the stored row the boot applies or the roster's default
  # stands. Every other setting is read through
  # `Arca.PlatformSettings.effective/1`, which answers the pin once this
  # member's settings process has stored it.
  for {%{config: [key], app: app}, value} <- settings, app != :logger, value != nil do
    config(app, key, value)
  end

  # The log level: the set value, else info in production and debug in
  # development. The development default is this file's, not the
  # roster's, and pins nothing.
  {_entry, log_level} = Enum.find(settings, fn {entry, _value} -> entry.key == "log_level" end)
  config :logger, level: log_level || if(config_env() == :prod, do: :info, else: :debug)

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
  # members). Off, a member that finds a live peer refuses to boot
  # (`Cyfr.Cell`); on, it boots only when every condition in
  # `Cyfr.Cell.refusals/1` holds — Postgres, shared object storage, TLS
  # distribution, a cell-only cookie, a discovery topology and a shared
  # worker root.
  config :cyfr, :cluster, env_bool.("CYFR_CLUSTER", false)

  # The cookie that bounds this cell, and the topology its members find
  # each other through. Both are resolved whatever the flag says, so a
  # half-configured cell is refused where it is written rather than at
  # the first member that cannot find a peer.
  case Cyfr.RuntimeConfig.resolve_cell_cookie(getenv) do
    {:ok, cell_cookie} -> config :cyfr, :cell_cookie, cell_cookie
    {:error, message} -> raise "[Cyfr] FATAL: " <> message
  end

  case Cyfr.RuntimeConfig.resolve_cluster_topology(getenv) do
    {:ok, topologies} -> config :libcluster, :topologies, topologies
    {:error, message} -> raise "[Cyfr] FATAL: " <> message
  end

  # The Locus backends service that runs stdio MCP servers
  # (`Emissary.External.Backends`): CYFR_LOCUS_BACKENDS_URL, the base URL
  # of its listener (compose: http://locus-backends:4101), and
  # CYFR_LOCUS_BACKENDS_KEY, the service key as 64 hexadecimal digits, the
  # value the service holds as LOCUS_BACKENDS_KEY (`cyfr init` generates
  # it). With either unset, no stdio server can be created or started; a
  # malformed value refuses the boot naming the variable and never the key.
  locus_backends_setting = fn read ->
    case read do
      {:ok, value} -> value
      {:error, message} -> raise "[Cyfr] FATAL: #{message}"
    end
  end

  config :cyfr,
         :locus_backends_url,
         locus_backends_setting.(Prima.EnvValue.url(getenv, "CYFR_LOCUS_BACKENDS_URL"))

  config :cyfr,
         :locus_backends_key,
         locus_backends_setting.(Prima.EnvValue.hex_key(getenv, "CYFR_LOCUS_BACKENDS_KEY"))

  # The runtime root every key CYFR issues derives from, resolved above.
  config :cyfr, :locus_runtime_root, worker_root

  # The worker services runs are dispatched to (`Opus.Dispatch`):
  # `CYFR_LOCUS_RUNTIME_WORKERS`, comma-separated `<service_id>=<url>` entries, each the
  # configured id of a worker service and the base URL of its listener,
  # tried in order. Default `wrk_local` at http://127.0.0.1:4200; the
  # source development stack names its own (scripts/dev-stack.sh). A
  # malformed entry or a repeated id refuses the boot.
  case Cyfr.RuntimeConfig.resolve_workers(getenv) do
    {:ok, workers} -> config :cyfr, :locus_runtime_workers, workers
    {:error, message} -> raise "[Cyfr] FATAL: #{message}"
  end

  # Where the host API listener binds and how a worker reaches it,
  # resolved above.
  config :cyfr, :host_api_bind, host_api.bind
  config :cyfr, :host_api_port, host_api.port
  config :cyfr, :host_api_url, host_api.url

  # Whether the server migrates the database on boot (default: true). Several
  # nodes on one Postgres, or an operator who runs the schema step by hand
  # (`bin/cyfr eval "Cyfr.Release.migrate()"`), turn it off.
  config :arca, :auto_migrate, env_bool.("CYFR_AUTO_MIGRATE", true)

  # Whether a pull refuses a component whose OCI signature cannot be
  # verified (default: false — the component is stored as unverified and
  # the recorded attestation is checked again at execution time).
  config :cyfr, :require_signed_pulls, env_bool.("CYFR_REQUIRE_SIGNED_PULLS", false)

  # The Locus builds service every build is sent to
  # (`Compendium.Builds.Client`): CYFR_LOCUS_BUILDS_URL, the base URL of
  # its listener (compose: http://locus-builds:4100), and
  # CYFR_LOCUS_BUILDS_KEY, the builds key as 64 hexadecimal digits, the
  # value the service holds as LOCUS_BUILDS_KEY. Both set, this server
  # builds there; neither, it builds nothing and runs no toolchain of its
  # own. One without the other, or a malformed value, refuses the boot
  # naming the variable and never the key.
  locus_builds =
    case Cyfr.RuntimeConfig.resolve_locus_builds(getenv) do
      {:ok, locus_builds} -> locus_builds
      {:error, message} -> raise "[Cyfr] FATAL: #{message}"
    end

  config :cyfr, :locus_builds_url, locus_builds && locus_builds.url
  config :cyfr, :locus_builds_key, locus_builds && locus_builds.key

  # A headless node (default: false) serves the API, MCP and public tinctures
  # and no browser surface: every route on the browser pipeline answers 404.
  # Codex signs in through the session tool on /mcp, so it does not notice.
  headless? = env_bool.("CYFR_HEADLESS", false)
  config :cyfr, :headless, headless?

  # CYFR_SECRET_KEY_BASE overrides the configured key. Required in
  # production; dev may use the key from its config file. Empty is unset,
  # as for every other setting here. A set value that is blank after
  # trimming, or shorter than 64 bytes, refuses the boot in development as
  # in production (`Cyfr.RuntimeConfig.check_secret_key_base/1`), so a
  # short key fails here and not at the first session.
  # This is the one read: the at-rest keyring, the endpoint and the
  # derived salts all take the key base it accepts, byte for byte.
  env_key_base = env_str.("CYFR_SECRET_KEY_BASE", nil)

  if env_key_base do
    case Cyfr.RuntimeConfig.check_secret_key_base(env_key_base) do
      :ok ->
        config :sanctum, :secret_key_base, env_key_base
        config :cyfr, CyfrWeb.Endpoint, secret_key_base: env_key_base

      {:error, message} ->
        raise "[Cyfr] FATAL: #{message}"
    end
  end

  # The access settings' listeners, address, origins, proxy trust and HSTS, in every
  # environment this file configures.
  #
  # The endpoint serves on its loopback listener in every mode, and in a
  # tailnet or public home on the proxy listener too, the one its proxy
  # forwards to (`CyfrWeb.Ingress`): each at the address and port the
  # access settings name. Its URL is the home's: `http://localhost:<CYFR_PORT>` in
  # a local home, `https://<CYFR_HOST>` on 443 otherwise.
  listener = fn {address, port} ->
    {:ok, ip} = :inet.parse_strict_address(String.to_charlist(address))
    [ip: ip, port: port]
  end

  {_address, loopback_port} = access.listeners.loopback

  config :cyfr, CyfrWeb.Endpoint,
    url:
      if(access.mode == :local,
        do: [scheme: "http", host: "localhost", port: loopback_port],
        else: [scheme: "https", host: access.head["host"], port: 443]
      ),
    # HTTP/1.1 alone comes from config/config.exs's `http:`, which this
    # deep-merges over (endpoint_http2_test.exs holds the release to it).
    http:
      listener.(access.listeners.loopback) ++
        [thousand_island_options: [read_timeout: 60_000]],
    check_origin: access.check_origins

  case access.listeners.proxy do
    :none -> :ok
    proxy -> config :cyfr, CyfrWeb.Endpoint, proxy: listener.(proxy)
  end

  # The MCP Origin allowlist (CyfrWeb.Plugs.MCPOrigin) is the endpoint's
  # `check_origin`, and the CYFR_MCP_ALLOWED_ORIGINS extras extend it
  # (`Cyfr.RuntimeConfig.mcp_allowed_origins/0`).
  config :cyfr, :mcp_allowed_origins, access.check_origins
  config :cyfr, :mcp_extra_origins, env_list.("CYFR_MCP_ALLOWED_ORIGINS")

  # The proxies whose forwarded headers the proxy listener trusts, and only
  # it (`Sanctum.ClientIp`): CYFR_TRUSTED_PROXY_CIDRS when set, else
  # CYFR_TRUSTED_PROXY_HOPS hops (default 1); nothing in a local home.
  config :sanctum, :proxy_trust, access.trust

  # The endpoint's HSTS on the proxy listener in a tailnet home; Caddy's in
  # a public one, and none in a local one
  # (`CyfrWeb.Plugs.ApiSecurityHeaders.maybe_hsts/1`).
  config :cyfr, :hsts, access.hsts

  # The home's address (`Sanctum.origin/0`): its public URL in a tailnet or
  # public home, `https://<CYFR_HOST>`, and in a local home, which has
  # none, `http://localhost:<CYFR_PORT>`. Every self-reference reads it: a
  # tincture's frame-ancestors and connect-src, an OAuth `redirect_uri`,
  # a copied URL. A webhook URL is absolute only where the public URL is
  # set (`Sanctum.public_url/0`), a path in a local home.
  config :sanctum, :public_url, access.head["public_url"]
  config :sanctum, :fallback_origin, access.origin

  if config_env() == :prod do
    secret_key_base =
      env_key_base ||
        raise """
        environment variable CYFR_SECRET_KEY_BASE is missing.
        You can generate one by calling: mix phx.gen.secret
        """

    config :cyfr, CyfrWeb.Endpoint, secret_key_base: secret_key_base, server: true

    # The session cookie's and the LiveView socket's signing salts,
    # CYFR_SESSION_SALT and CYFR_LIVE_SALT, each derived from
    # secret_key_base under its own label when unset.
    session_salt =
      env_str.("CYFR_SESSION_SALT", nil) ||
        :crypto.hash(:sha256, "session_salt" <> secret_key_base)
        |> Base.url_encode64(padding: false)
        |> binary_part(0, 16)

    live_salt =
      env_str.("CYFR_LIVE_SALT", nil) ||
        :crypto.hash(:sha256, "live_salt" <> secret_key_base)
        |> Base.url_encode64(padding: false)
        |> binary_part(0, 16)

    config :cyfr, :session_salt, session_salt
    config :cyfr, CyfrWeb.Endpoint, live_view: [signing_salt: live_salt]

    # Session cookies must be secure in production (HTTPS-only).
    # Dev/test leave this false so http://localhost works.
    config :cyfr, :cookie_secure, true
  end

  # Resolve runtime and seed paths in dev and prod. Defaults are relative
  # to the working directory; start development from the umbrella root.
  # Tests keep their temporary storage roots.
  paths =
    case Cyfr.RuntimeConfig.resolve_paths(getenv) do
      {:ok, paths} -> paths
      {:error, message} -> raise message
    end

  config :arca, :base_path, paths.base_path
  config :arca, :seed_path, paths.seed_path

  # The adapter is the build's: `config/database_choice.exs` parses
  # CYFR_DATABASE once, when the release is compiled. A value the boot reads
  # is held to the built one (`Arca.adapter_facts/0`), and any other value,
  # an unknown one among them, refuses.
  built_database = Atom.to_string(Arca.adapter_facts().adapter)
  requested_database = getenv.("CYFR_DATABASE")

  if requested_database && String.downcase(requested_database) != built_database do
    raise """
    [Cyfr] FATAL: CYFR_DATABASE=#{requested_database} but this release was built \
    for #{built_database}.

    The database adapter is chosen when the release is COMPILED, not when it \
    boots, so it is the one setting `.env` cannot change. Set CYFR_DATABASE in \
    the build environment and rebuild, or remove it from `.env`/the environment \
    so the built adapter stands.
    """
  end

  # Database connection config. The adapter is selected at compile time in
  # config.exs from CYFR_DATABASE; here we supply connection parameters for
  # whichever adapter was built — gated so SQLite-only keys (journal_mode)
  # never bleed into a Postgres build and vice versa. SQLite's busy timeout
  # is config.exs's: it is the pool's lock-wait deadline
  # (`Arca.Repo.busy_timeout_ms/0`), not a deployment setting.
  case Arca.adapter_facts().adapter do
    :sqlite ->
      pool_size =
        case Cyfr.RuntimeConfig.resolve_pool_size(getenv) do
          {:ok, pool_size} -> pool_size
          {:error, message} -> raise message
        end

      config :arca, Arca.Repo,
        database: paths.database_path,
        pool_size: pool_size,
        journal_mode: :wal

    :postgres ->
      # A Postgres build carries no connection config from config.exs, so a
      # CYFR_DATABASE_URL is required — its absence is a hard boot error
      # rather than a silent attempt against a default localhost. (The
      # `locus` release never reads this file: it starts no Repo and must
      # not be handed database credentials at all.)
      case Cyfr.RuntimeConfig.resolve_postgres(getenv) do
        {:ok, repo_opts} -> config :arca, Arca.Repo, repo_opts
        {:error, message} -> raise message
      end
  end

  # The storage reserve (`Cyfr.StorageReserve`): its size, and the
  # directory holding its file, the database's under SQLite unless set.
  # The boot checks the directory on the host it runs on.
  case Cyfr.RuntimeConfig.resolve_storage_reserve(
         getenv,
         Arca.adapter_facts().adapter,
         paths.database_path
       ) do
    {:ok, reserve} ->
      config :cyfr, :storage_reserve_bytes, reserve.bytes
      config :cyfr, :storage_reserve_path, reserve.path

    {:error, message} ->
      raise "[Cyfr] FATAL: #{message}"
  end

  # Browser CORS allowlist (`CyfrWeb.Plugs.CORS`): the origins it spells;
  # unset or empty, no cross-origin caller at all, which a same-origin
  # deployment needs. A wildcard is refused for a release that has
  # authentication configured (`Cyfr.Application.cors_enforcement/3`).
  config :cyfr, :cors_allowed_origins, env_list.("CYFR_CORS_ALLOWED_ORIGINS")

  # Private egress: the hostnames, IPs or CIDRs on the private network that
  # the *server's own* outbound requests may reach — an MCP server on the
  # compose network, an internal registry or IdP, a vault OAuth token
  # endpoint. Empty refuses every private target; the link-local metadata
  # range is refused regardless.
  #
  # It does not reach components. A guest's outbound target is pinned by
  # the control plane under the attempt's admitted authority
  # (`Opus.Host.Egress`), whose `egress.private_ips` is the only
  # private-address grant it reads, so a LAN device is reachable from a
  # chain only as an MCP server on this list, never as a URL the bundled
  # http catalyst fetches.
  config :sanctum, :private_egress_targets, env_list.("CYFR_PRIVATE_EGRESS_TARGETS")

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
    config :sanctum, :google_client_id, google_id
  end

  if google_secret do
    config :sanctum, :google_client_secret, google_secret
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

  # The directory this deployment enrolls its local people at: an https
  # directory URL, with no default, so an unset one leaves local operation
  # and local pairing working and enrollment refused. Nothing reads a
  # directory from a request. An enrollment's confirmation preview names
  # the directory, so it is no longer than a preview's text.
  {:ok, directory_url} = Prima.EnvValue.text(getenv, "CYFR_DIRECTORY_URL")

  unless is_nil(directory_url) or Sanctum.enrollment_directory?(directory_url) do
    raise "[Cyfr] FATAL: CYFR_DIRECTORY_URL must be an https directory URL: an origin " <>
            "and an optional path, with no user, query or fragment, at most " <>
            "#{Prima.Confirmation.Preview.max_text()} bytes long."
  end

  config :sanctum, :directory_url, directory_url

  # The installation's restore capability: exactly 64 lowercase hexadecimal
  # characters (32 random bytes), optional. Set, it reserves this
  # installation's first person for the restore path, and `Sanctum`
  # installs that mode before any ingress opens. A malformed value refuses
  # the boot naming the variable, never the value, which is a secret.
  {:ok, restore_token} = Prima.EnvValue.text(getenv, "CYFR_RESTORE_TOKEN")

  unless is_nil(restore_token) or Sanctum.restore_token?(restore_token) do
    raise "[Cyfr] FATAL: CYFR_RESTORE_TOKEN must be exactly 64 lowercase hexadecimal " <>
            "characters (32 random bytes)."
  end

  config :sanctum, :restore_token, restore_token

  oci_registry_url_config =
    env_str.(
      "CYFR_OCI_REGISTRY_URL",
      if(registry_url_config == "none", do: "none", else: "registry.#{registry_url_config}")
    )

  config :cyfr, :oci_registry_url, oci_registry_url_config

  # GitHub device flow needs only its client ID (read above).
  if github_id do
    config :sanctum, :github_client_id, github_id
  end

  # Platform-admin email allowlist. Addresses are normalized to lowercase before matching.
  platform_admins =
    "CYFR_PLATFORM_ADMIN_EMAILS" |> env_list.() |> Enum.map(&String.downcase/1)

  config :sanctum, :platform_admin_emails, platform_admins

  # Select the auth provider from explicit configuration, then OAuth
  # credentials. Reject unsatisfied explicit settings. Without a provider,
  # requests are anonymous and tenant-scoped routes are denied.
  auth_provider =
    case Cyfr.RuntimeConfig.resolve_auth_provider(getenv) do
      {:ok, provider} -> provider
      {:error, message} -> raise message
    end

  config :sanctum, :auth_provider, auth_provider

  # A headless node has no browser page, and an external OIDC provider signs
  # people in through one (the CLI's device flow is the built-in provider's):
  # together they leave no way in. Refuse the pair rather than boot a box
  # nobody can log in to.
  if headless? and auth_provider == Sanctum.Auth.OIDC do
    raise "CYFR_HEADLESS=on cannot be combined with CYFR_AUTH_PROVIDER=oidc: " <>
            "an OIDC provider signs in through the browser page a headless node refuses"
  end

  # Generic OIDC, the one browser-callback sign-in. When selected, register
  # the issuer for ueberauth_oidcc and its strategy. CYFR_OIDC_ISSUER is also
  # pinned at `:sanctum, :oidc_issuer` — the single source both the boot
  # reserved-host check (`Cyfr.Application.validate_oidc_issuer_config!/0`) and
  # the login id builder (`Sanctum.Auth.OIDC.resolve_issuer/0`) read.
  if auth_provider == Sanctum.Auth.OIDC do
    {:ok, oidc} = Cyfr.RuntimeConfig.oidc_config(getenv)

    config :sanctum, :oidc_issuer, oidc.issuer
    config :ueberauth_oidcc, :issuers, [%{name: :cyfr_oidc, issuer: oidc.issuer}]

    # Provider key `:oidcc` (not `:oidc`) so `auth.provider` matches the
    # generic-OIDC email-verification lane (`Sanctum.Auth.EmailVerification`)
    # and the canonical `oidcc|<iss>|<sub>` id form. The callback is the
    # home's own address (`Sanctum.origin/0`), named here so no request
    # header chooses it: unnamed, Ueberauth builds it from the request's
    # X-Forwarded-Proto and X-Forwarded-Host, which any client can send.
    config :ueberauth, Ueberauth,
      providers: [
        oidcc:
          {Ueberauth.Strategy.Oidcc,
           issuer: :cyfr_oidc,
           client_id: oidc.client_id,
           client_secret: oidc.client_secret,
           callback_url: access.origin <> "/auth/oidcc/callback"}
      ]
  end

  # Storage backend. Unset/`local` keeps the filesystem default from config.exs;
  # `s3` flips the adapter and requires the S3 credentials (fail loud if partial).
  case Cyfr.RuntimeConfig.resolve_storage(getenv) do
    {:ok, :local} ->
      :ok

    {:ok, {:s3, s3_opts}} ->
      config :arca, :storage_adapter, Arca.Adapters.S3
      config :arca, :s3, s3_opts

    {:error, message} ->
      raise message
  end

  # Sigstore Configuration. Keyless verification checks the signing
  # certificate against a named identity and issuer (regexps); without both,
  # `Compendium.Cosign` refuses rather than accepting any signer at all.
  if cosign_key = env_str.("CYFR_COSIGN_KEY", nil) do
    config :cyfr, :sigstore,
      verification: :keyed,
      key_path: cosign_key
  else
    config :cyfr, :sigstore,
      verification: :keyless,
      identity: env_str.("CYFR_COSIGN_IDENTITY", nil),
      issuer: env_str.("CYFR_COSIGN_ISSUER", nil)
  end

  # Prometheus metrics: the /metrics endpoint is unauthenticated, so it is
  # off unless enabled (on in a dev build, `config/dev.exs`). Set, the
  # switch decides either way; bind to a private interface or
  # proxy-allowlist the endpoint when it is on.
  if getenv.("CYFR_PROMETHEUS_METRICS") do
    config :cyfr, :prometheus_metrics_enabled, env_bool.("CYFR_PROMETHEUS_METRICS", false)
  end

  # Bearer token for the /metrics scrape. Unset means the operator chose
  # network-level protection (a private bind or a proxy allowlist).
  if metrics_token = env_str.("CYFR_METRICS_TOKEN", nil) do
    config :cyfr, :metrics_token, metrics_token
  end

  # OpenTelemetry Configuration
  # Set CYFR_OTEL_ENABLED=on to enable distributed tracing.
  # Traces are exported via OTLP to the endpoint specified by OTEL_EXPORTER_OTLP_ENDPOINT
  # (defaults to http://localhost:4318 for HTTP/protobuf). Every span leaves
  # through the credential scrub, which wraps the OTLP exporter
  # (`CyfrWeb.ScrubSpanCredentials`); `Cyfr.Application` refuses a boot whose
  # environment replaces it.
  if env_bool.("CYFR_OTEL_ENABLED", false) do
    config :cyfr, :opentelemetry_enabled, true

    config :opentelemetry,
      resource: %{service: %{name: "cyfr"}},
      span_processor: :batch,
      traces_exporter: {CyfrWeb.ScrubSpanCredentials, {:opentelemetry_exporter, %{}}}

    config :opentelemetry_exporter,
      otlp_protocol: :http_protobuf,
      otlp_endpoint: env_str.("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")
  else
    config :opentelemetry,
      traces_exporter: :none
  end
end
