# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Platform.Settings.Roster do
  @moduledoc """
  Every name the `cyfr` boot reads from its environment, declared once.

  Two planes. A **deployment variable** is read before the repo opens, or
  decides how the box is reachable, or is a security posture a stolen
  operator session must not change: `deployment/0` lists them, and they
  stay in the environment. Everything else is a **platform setting**:
  `entries/0` declares each one with its store key, its application, the
  configuration path of the few read from there, its variable, type, default,
  validator, group, scope, stale policy, apply function and, for the API
  rate-limit pair, the mark that an absent value inherits the MCP pair.

  Precedence is the environment when its variable is set (the boot records
  that presence as a pin, `pinned/0`), then the stored row, then the
  default. Arca stores the rows and answers them through
  `Arca.PlatformSettings.effective/1`; the host hands it `defaults/0`,
  plain values, and keeps every validator here, so no function crosses
  downward.

  Two more classes complete the inventory. `compose_only/0` is the names
  `docker-compose.yml` interpolates that no release reads. `foreign/0` is
  the `CYFR_*` names other programs own (the CLI, the installer, the test
  harness), which a shell may export beside a server. `unknown/2` is the
  refusal: a `CYFR_*` name in the boot's `.env` files that none of the
  first three classes declares, or one in its process environment that
  none of the four declares, refuses the boot naming it. That is how a
  retired name is refused without a list of retired names.

  Every declaration carries the sentence `configuration-guide.md` gives
  it, which `mix cyfr.gen.configuration_guide` renders from this module.

  `config/runtime.exs` reads this module only on the `cyfr` boot: an island
  release carries no host module, and `Opus.Settings` and `Locus.Config`
  declare their own prefixes.
  """

  defmodule Entry do
    @moduledoc """
    One platform setting.

      * `key` — the store key (`platform_settings.key`), a string.
      * `app` — the application whose reader reads it: `:sanctum` for the
        caps and Sanctum's windows, `:logger` for the log level, `:cyfr` for
        the rest.
      * `config` — the configuration path the value is written to for a
        reader that takes it from the application environment: `[key]` for
        a restart-scoped setting, which the boot and its apply write there
        and its reader reads once, and `[:level]` for the log level, which
        Logger holds. `nil` for every other setting, whose reader calls
        `Arca.PlatformSettings.effective/1` on each use.
      * `variable` — the `CYFR_*` name that pins it, or `nil`.
      * `type` — the value's shape: `:integer`, `:boolean`, `:string`,
        `:duration_s` (whole seconds), `:list`, `:keyword` or `:atom` (a
        name from a closed set, stored as its string).
      * `default` — the value when neither the environment nor a row sets it;
        `nil` is a value where the reader reads it as "none" (an unset cap,
        the hostname for the device label).
      * `validator` — `(term() -> {:ok, term()} | {:error, form})`: takes the
        environment's text or a typed value and answers the typed value, or
        the form it must take (`"must be …"`), for a message that names the
        variable. Run at boot and by every later write; never installed
        into Arca.
      * `group`, `scope` (`:live | :restart`), `stale` (`:refuse | :serve`).
      * `apply` — `{module, function, 1}` for a restart-scoped entry and the
        log level, `nil` for every other live entry.
      * `inherit` — `true` for the API rate-limit pair alone: absent, the
        pair takes the MCP pair's value.
      * `doc` — one sentence saying what the setting bounds or chooses, for
        `configuration-guide.md` (`mix cyfr.gen.configuration_guide`).
    """

    @enforce_keys [:key, :app, :variable, :type, :default, :validator, :group, :scope, :stale]
    defstruct [
      :key,
      :app,
      :config,
      :variable,
      :type,
      :default,
      :validator,
      :group,
      :scope,
      :stale,
      apply: nil,
      inherit: false,
      doc: nil
    ]

    @type t :: %__MODULE__{
            key: String.t(),
            app: :cyfr | :sanctum | :arca | :logger,
            config: [atom()] | nil,
            variable: String.t() | nil,
            type: :integer | :boolean | :string | :duration_s | :list | :keyword | :atom,
            default: term(),
            validator: (term() -> {:ok, term()} | {:error, String.t()}),
            group: atom(),
            scope: :live | :restart,
            stale: :refuse | :serve,
            apply: {module(), atom(), 1} | nil,
            inherit: boolean(),
            doc: String.t() | nil
          }
  end

  @type getenv :: (String.t() -> String.t() | nil)

  # The Logger levels, most to least severe: the log level's closed set.
  @levels ~w(emergency alert critical error warning notice info debug)

  # Whether this node serves a directory: not at all, as the one writer
  # of the identifiers it orders, or as a mirror of their history.
  @directory_serve %{"off" => :off, "writer" => :writer, "mirror" => :mirror}

  # The largest byte count a quota takes: 1 PiB.
  @max_bytes 1_125_899_906_842_624

  # The host step that applies a restart-scoped value, and the log level's
  # live apply, both run by the settings process.
  @apply_log_level {Cyfr.Platform.Settings, :apply_log_level, 1}
  @apply_execution_slots {Cyfr.Platform.Settings, :apply_execution_slots, 1}

  # Each deployment variable with the sentence `configuration-guide.md`
  # gives it, in name order.
  @deployment [
    {"CYFR_AUTH_PROVIDER",
     "The sign-in provider: unset for the built-in GitHub and Google device flows, `oidc` for the external issuer the three `CYFR_OIDC_*` variables name; `oidc` with any of them missing refuses the boot."},
    {"CYFR_AUTO_MIGRATE",
     "Whether the server migrates the schema on boot (default `true`); `false` when several members share one PostgreSQL database or an operator runs `bin/cyfr eval \"Cyfr.Release.migrate()\"` by hand."},
    {"CYFR_BEHIND_PROXY",
     "`true` when a reverse proxy fronts the server: forwarded headers are trusted, the plain-HTTP warning is silent, and `cyfr up` starts the stack's Caddy (`--profile tls`). `cyfr init`'s TLS answer writes it."},
    {"CYFR_BIND_ADDRESS",
     "The address the one endpoint binds (default `0.0.0.0`); `127.0.0.1` binds localhost only."},
    {"CYFR_CELL_COOKIE",
     "A cell's cookie: at least 32 characters (`openssl rand -hex 32`), the same on every member and the cookie each member's BEAM runs under (`RELEASE_COOKIE` or `-setcookie`)."},
    {"CYFR_CLUSTER",
     "Several members on one database as one cell (default off). A member boots only with PostgreSQL, S3 storage, TLS distribution, `CYFR_CELL_COOKIE`, a discovery topology, a shared `CYFR_OPUS_KEY` and its own `CYFR_HOST_API_URL`; each missing one is a named refusal."},
    {"CYFR_CLUSTER_DNS_QUERY",
     "A cell's discovery by DNS: the headless service whose addresses are the members, each named `<CYFR_CLUSTER_NODE_BASENAME>@<address>`."},
    {"CYFR_CLUSTER_NODE_BASENAME",
     "The node basename of the members `CYFR_CLUSTER_DNS_QUERY` finds."},
    {"CYFR_CLUSTER_NODES",
     "A cell's members by name, comma-separated (`cyfr@10.0.0.1,cyfr@10.0.0.2`)."},
    {"CYFR_CORS_ALLOWED_ORIGINS",
     "The browser CORS allowlist, comma-separated origins. A release with sign-in configured refuses to boot on the unassigned wildcard default; assigned empty, as `cyfr init` writes it, it admits no cross-origin caller, which the shipped stack never needs."},
    {"CYFR_COSIGN_IDENTITY",
     "Keyless OCI signature verification: the regular expression the signing certificate's identity must match, with `CYFR_COSIGN_ISSUER`; a missing keyless constraint refuses verification."},
    {"CYFR_COSIGN_ISSUER",
     "Keyless OCI signature verification: the regular expression the signing certificate's issuer must match, with `CYFR_COSIGN_IDENTITY`."},
    {"CYFR_COSIGN_KEY", "Key-based OCI signature verification: the cosign public key."},
    {"CYFR_COSIGN_PASSWORD", "The password of `CYFR_COSIGN_KEY`, when it has one."},
    {"CYFR_CRYPTO_KEYRING",
     "The keyring sealing secrets at rest (vault entries, webhook secrets, registry tokens, and each person's online keys and pending recovery material), as JSON `{\"primary\":\"label\",\"keys\":{\"label\":\"<base64, at least 32 bytes>\"}}`; unset, one key derived from `CYFR_SECRET_KEY_BASE`. To rotate, keep the old labels listed and re-seal with `Cyfr.Release.rotate_cipher_keys/1`. Losing it loses every person's online keys at this home: an enrolled person restores from a printed kit on an empty installation, and an unenrolled person's keys are gone."},
    {"CYFR_CRYPTO_KEYRING_FINGERPRINT_ACCEPT",
     "The primary-key fingerprint the boot's refusal reports, set for one boot to accept a deliberate key change; re-seal, then unset it. It recovers nothing sealed with a key that is gone."},
    {"CYFR_DATABASE",
     "The database adapter, `sqlite` (default) or `postgres`, fixed when the release is built; the published image is SQLite, and a runtime value that disagrees with the build refuses the boot."},
    {"CYFR_DATABASE_PATH", "The SQLite file (default `cyfr.db` under `CYFR_DATA_PATH`)."},
    {"CYFR_DATABASE_URL",
     "The PostgreSQL URL, which a PostgreSQL build requires (there is no localhost fallback)."},
    {"CYFR_DATA_PATH",
     "The one runtime storage root: every athanor's tree, the caches and the SQLite database (default `data`; the image sets its own)."},
    {"CYFR_DB_POOL_SIZE", "The database connection pool's size (default 20)."},
    {"CYFR_DB_SSL", "TLS to the PostgreSQL server (default off)."},
    {"CYFR_DIRECTORY_URL",
     "The identity directory this deployment enrolls its local people at, an `https` URL chosen explicitly: there is no hosted default, and choosing one is a choice about how long an identity lasts. Unset, local work and local pairing still work and enrollment is refused; a malformed value refuses the boot."},
    {"CYFR_GITHUB_CLIENT_ID",
     "The GitHub OAuth app's client ID for the device flow; `.env.example` ships a public one, which your own app's replaces."},
    {"CYFR_GOOGLE_CLIENT_ID",
     "The Google OAuth client ID for the device flow, used with `CYFR_GOOGLE_CLIENT_SECRET`; `.env.example` ships a public one."},
    {"CYFR_GOOGLE_CLIENT_SECRET",
     "The Google OAuth client secret, set in `.env` alone and never in a tracked file."},
    {"CYFR_HEADLESS",
     "A Codex-only node (default off): `/mcp`, `/api` and public tinctures are served and every browser page answers 404. It does not combine with `CYFR_AUTH_PROVIDER=oidc`."},
    {"CYFR_HOST",
     "The hostname clients reach the server at (default `localhost`); in TLS mode Caddy's certificate names it."},
    {"CYFR_HOST_API_BIND",
     "The address the host API binds for the workers' host calls and exit reports (default `127.0.0.1`; compose binds every interface of the worker network)."},
    {"CYFR_HOST_API_PORT", "The host API's port (default 4300)."},
    {"CYFR_HOST_API_URL",
     "The address a worker service reaches this member's host API at, carried by every assignment the member issues; unset, a worker uses its own `OPUS_HOST_URL`, and a cell refuses to boot without it."},
    {"CYFR_LIVE_SALT",
     "The LiveView socket's signing salt; unset, derived from `CYFR_SECRET_KEY_BASE`. Set it only to keep sessions across a key-base rotation."},
    {"CYFR_LOCUS_BACKENDS_KEY",
     "The backends service's key, 32 random bytes as 64 hexadecimal digits (`openssl rand -hex 32`), which `cyfr init` mints and compose hands the service as `LOCUS_BACKENDS_KEY`; without it, or without `CYFR_LOCUS_BACKENDS_URL`, stdio MCP servers are refused."},
    {"CYFR_LOCUS_BACKENDS_URL",
     "The backends service's base URL; compose sets `http://locus-backends:4101`. Set it for a service elsewhere, and name its host in `CYFR_PRIVATE_EGRESS_TARGETS`."},
    {"CYFR_LOCUS_BUILDS_KEY",
     "The key every build request is signed with, 64 hexadecimal digits, which `cyfr init` mints and compose hands the builder as `LOCUS_BUILDS_KEY`; set with `CYFR_LOCUS_BUILDS_URL` or not at all."},
    {"CYFR_LOCUS_BUILDS_URL",
     "The builds service's base URL. `http://locus-builds:4100`, which `cyfr init` writes, names the compose service, which `cyfr up` then starts; a URL naming another host starts no local builder. With it and `CYFR_LOCUS_BUILDS_KEY` both empty builds are off and every build is refused; one without the other refuses the boot."},
    {"CYFR_LOG_FORMAT", "`json` for structured logs; unset, plain text."},
    {"CYFR_MCP_ALLOWED_ORIGINS",
     "Extra origins, comma-separated, the MCP endpoint's Origin check accepts beside `https://CYFR_HOST` and the localhost defaults."},
    {"CYFR_METRICS_TOKEN",
     "The bearer token a `/metrics` scrape must present; unset, an enabled endpoint is unauthenticated, so bind it privately or allowlist it at the proxy."},
    {"CYFR_OCI_REGISTRY_URL",
     "The OCI registry host components are pulled from and pushed to (default `registry.<CYFR_REGISTRY_URL>`, and `none` when that is `none`)."},
    {"CYFR_OIDC_CLIENT_ID", "The client ID at the OIDC issuer, with `CYFR_AUTH_PROVIDER=oidc`."},
    {"CYFR_OIDC_CLIENT_SECRET",
     "The client secret at the OIDC issuer, with `CYFR_AUTH_PROVIDER=oidc`."},
    {"CYFR_OIDC_ISSUER",
     "The OIDC issuer's URL (Okta, Auth0, Keycloak, Azure AD and the like), with `CYFR_AUTH_PROVIDER=oidc`."},
    {"CYFR_OPUS_KEY",
     "The worker root, 32 random bytes as 64 hexadecimal digits, read by cyfr alone; every worker service's key derives from it. `cyfr init` mints it, every member of a cell holds the same one, and without it no component runs."},
    {"CYFR_OPUS_WORKERS",
     "The worker services runs are dispatched to, comma-separated `<service_id>=<url>` entries tried in order; compose sets `wrk_opus=http://opus:4200`, and outside compose the default is a worker on this machine."},
    {"CYFR_OTEL_ENABLED",
     "OpenTelemetry traces over OTLP to `OTEL_EXPORTER_OTLP_ENDPOINT` (default off)."},
    {"CYFR_PLATFORM_ADMIN_EMAILS",
     "The server's operators, comma-separated emails: each is always let in and holds the platform-admin capability, reconciled at every boot. Unset, no one can sign in."},
    {"CYFR_PORT", "The one endpoint's port (default 4000)."},
    {"CYFR_PRIVATE_EGRESS_TARGETS",
     "The private hosts, addresses or CIDRs the server's own outbound calls may reach (MCP servers, OAuth token endpoints, registry pulls), comma-separated; the stack names `locus-backends`. Link-local addresses are always refused, and a run's egress never uses this list."},
    {"CYFR_PROMETHEUS_METRICS",
     "Prometheus metrics at `/metrics` on the API port (default off)."},
    {"CYFR_PUBLIC_URL",
     "The address the server is reachable at from outside, which behind a proxy or tunnel only the operator knows; webhook URLs are absolute when it is set and bare paths when it is not."},
    {"CYFR_REGISTRY_URL",
     "The component registry host (default `cyfr.run`); `none` is an appliance without a registry, whose pulls and publishes refuse."},
    {"CYFR_REQUIRE_SIGNED_PULLS",
     "Refuse a component pull whose OCI signature cannot be verified (default off: the component is stored as unverified)."},
    {"CYFR_RESTORE_TOKEN",
     "The installation's restore capability, exactly 64 lowercase hexadecimal characters (`openssl rand -hex 32`), set in `.env` alone. Set, an empty installation's first person is reserved for a restore from a printed kit and ordinary first sign-in is refused; unset, restore is disabled. A malformed value refuses the boot, which never prints it."},
    {"CYFR_S3_ACCESS_KEY_ID", "The object store's access key ID, with `CYFR_STORAGE=s3`."},
    {"CYFR_S3_BUCKET", "The object store's bucket, with `CYFR_STORAGE=s3`."},
    {"CYFR_S3_ENDPOINT",
     "The endpoint of a non-AWS object store (MinIO and the like), usually with `CYFR_S3_PATH_STYLE=true`."},
    {"CYFR_S3_PATH_STYLE", "Path-style bucket addressing (default off)."},
    {"CYFR_S3_PREFIX", "A key prefix every object is stored under (default none)."},
    {"CYFR_S3_RECEIVE_TIMEOUT_MS",
     "The per-request timeout against the object store, in milliseconds (default 60000); a slower store reads as a storage outage."},
    {"CYFR_S3_REGION", "The object store's region, with `CYFR_STORAGE=s3`."},
    {"CYFR_S3_SECRET_ACCESS_KEY",
     "The object store's secret access key, with `CYFR_STORAGE=s3`."},
    {"CYFR_SECRET_KEY_BASE",
     "The key base that signs sessions and derives the at-rest key (`openssl rand -base64 48`), which `cyfr init` mints; a restored data directory needs the same value."},
    {"CYFR_SEED_PATH",
     "The seed tree read in place: the component bundle under `components/` and the AQUA template under `aqua/` (default `seed`; the image sets its own)."},
    {"CYFR_SESSION_SALT",
     "The session cookie's signing salt; unset, derived from `CYFR_SECRET_KEY_BASE`. Set it only to keep sessions across a key-base rotation."},
    {"CYFR_STORAGE",
     "`s3` for S3-compatible object storage, which needs the bucket, region and both keys; unset, the local filesystem under `CYFR_DATA_PATH`."},
    {"CYFR_TRUSTED_PROXY_CIDRS",
     "The reverse proxies in front of the server, comma-separated addresses or CIDRs, which take precedence over `CYFR_TRUSTED_PROXY_HOPS`; an entry that is neither refuses the boot."},
    {"CYFR_TRUSTED_PROXY_HOPS",
     "The reverse-proxy hops in front of the server when `CYFR_BEHIND_PROXY` is true (default 1, the stack's Caddy; 0 to 16). Too few resolves client addresses to a proxy, so API-key address allowlists fail closed."},
    {"OTEL_EXPORTER_OTLP_ENDPOINT",
     "The OTLP endpoint traces go to (default `http://localhost:4318`). Not under the prefix; listed so every name the boot reads has one home."}
  ]

  # The `${…}` names docker-compose.yml interpolates that no release reads:
  # each container's CPU and memory limit, and Caddy's ACME address, each
  # with the sentence `configuration-guide.md` gives it.
  @compose_only [
    {"CADDY_ACME_EMAIL",
     "The address Let's Encrypt registers Caddy's certificate under, in TLS mode with a real `CYFR_HOST`; `cyfr init` asks for it."},
    {"CYFR_CPU_LIMIT",
     "The cyfr container's CPU limit (default 4), which bounds the aggregate CPU of components that never yield."},
    {"LOCUS_BUILDS_CPU_LIMIT", "The locus-builds container's CPU limit (default 2)."},
    {"LOCUS_BUILDS_MEMORY_LIMIT",
     "The locus-builds container's memory limit (default 4G), at least `LOCUS_BUILDS_MAX_CONCURRENT` x (`LOCUS_BUILDS_MEMORY_BYTES` + 1 GiB), so each build reaches its own bound before the container reaches its limit."},
    {"OPUS_CPU_LIMIT", "The opus container's CPU limit (default 4)."},
    {"OPUS_MEMORY_LIMIT",
     "The opus container's memory limit (default 4G), at least 8 runner uids x `OPUS_RUNNER_MEMORY_BYTES` + 1 GiB, so each runner reaches its own bound before the container reaches its limit."}
  ]

  # Names under the prefix that other programs own. A trailing `*` is a
  # prefix. Only the process environment may carry them: a `.env` file is
  # the server's, and one of these in it is a mistake the boot names.
  @foreign [
    {"CYFR_TOKEN", "the Codex CLI: the session token its non-interactive path signs in with"},
    {"CYFR_NO_UPDATE_CHECK", "the Codex CLI: turns off its release check"},
    {"CYFR_INSECURE_SKIP_VERIFY", "the Codex CLI: skips TLS verification of the server it calls"},
    {"CYFR_INSTALL_DIR", "the installer (scripts/install.sh): where it puts the CLI"},
    {"CYFR_VERSION", "the installer: the release it installs"},
    {"CYFR_IMAGE", "the installer: the image the stack it writes runs"},
    {"CYFR_POSTGRES_TEST_URL", "the test harness: the PostgreSQL server the suite runs on"},
    {"CYFR_TEST_*", "the test harness: its partition, run root and object-store fixtures"},
    {"CYFR_CLUSTER_DATABASE_URL", "the test harness: the cluster suite's shared database"},
    {"CYFR_GOLDEN_RECORD", "the test harness: rewrites the consent bootstrap's golden file"}
  ]

  # Each setting's sentence, by key: every entry's `doc`.
  @setting_docs %{
    "max_athanors" =>
      "Active athanors on this server; an archived one frees its place. Unset, no cap.",
    "max_groups_per_person" =>
      "Groups one person may create (they may belong to more); 0 turns the cap off.",
    "max_pairs_per_person" =>
      "DMs one person may hold open; a DM is minted for two, so either person at the cap refuses it, and an ended DM frees its place. 0 turns the cap off.",
    "max_members_per_group" => "Seats in one group, invitations included. Unset, no cap.",
    "max_threads_per_athanor" =>
      "Threads one athanor may hold, each a row any member's client can mint; 0 turns the cap off.",
    "mint_per_hour" =>
      "Personal athanors minted per hour: how fast strangers can arrive through an open door. Unset, no cap.",
    "athanor_storage_bytes" =>
      "Bytes one athanor may hold, its whole tree including its copies of the shipped bundle. Unset, no cap.",
    "crucible_max_concurrent" =>
      "Concurrent WASM executions on each member, at least 32 so the chain children's reserve holds a chain of the full depth.",
    "crucible_max_concurrent_per_tenant" =>
      "Concurrent WASM executions one athanor may hold on each member.",
    "mcp_rate_limit_max" =>
      "Requests and stream opens per client address per window on the MCP endpoint; streams already open are unaffected.",
    "mcp_rate_limit_window_ms" => "The MCP rate limit's window, in milliseconds.",
    "api_rate_limit_max" =>
      "Requests per client address per window on the API bucket (execution-event stream reconnects); unset, the MCP pair's value, counted separately.",
    "api_rate_limit_window_ms" =>
      "The API bucket's window, in milliseconds; unset, the MCP pair's.",
    "webhook_per_ip_rate_limit_max" =>
      "Inbound webhook deliveries per client address per minute across every slug, checked before and so capping each webhook's own limit.",
    "mcp_subscription_max_concurrent" =>
      "Concurrent MCP subscription streams per caller (athanor and credential).",
    "mcp_subscription_max_ms" =>
      "How long one MCP subscription stream lives before the client reconnects, in milliseconds.",
    "crucible_events_max_concurrent" =>
      "Concurrent execution-event streams per caller (athanor and credential).",
    "crucible_events_max_ms" =>
      "How long one execution-event stream lives before the client reconnects, in milliseconds.",
    "frame_stream_max_concurrent" =>
      "Concurrent streams one tincture frame holds open (per frame credential).",
    "session_ttl_hours" => "Hours a session may sit idle before it ends; 0 never ends one.",
    "webhook_max_skew_seconds" =>
      "How far a delivery's timestamp may sit from now before it is refused as a replay: how long a captured delivery stays replayable.",
    "webhook_idempotency_ttl_seconds" =>
      "How long delivered idempotency keys are kept: the window in which a retried delivery is recognised as a duplicate.",
    "device_label" =>
      "The label recorded against the registry push tokens this server mints. Unset, the hostname.",
    "health_ready_cache_ms" =>
      "How long `/health/ready` reuses its last probe, in milliseconds; on S3 every uncached probe is a billable write.",
    "decision_retention_days" =>
      "Days the server keeps the admission decisions it made before any athanor was resolved; each athanor keeps its own under its retention settings.",
    "opus_watch_poll_ms" =>
      "How often cyfr asks each worker service for its status, in milliseconds.",
    "opus_watch_misses" =>
      "Status polls a worker service may miss in a row before cyfr ends the runs of the boot it last heard from.",
    "locus_backends_lease_ms" =>
      "How long the backends service runs a stdio server's backends without a renewal from cyfr, in milliseconds; cyfr renews every third of it.",
    "locus_backends_idle_ms" =>
      "How long a stdio backend runs without a tool call before it is stopped and its slot freed, in milliseconds; its next call starts it again.",
    "log_level" =>
      "The Logger level, `emergency` to `debug`; debug output may include unredacted dependency messages.",
    "asset_credential_window_s" =>
      "How long a private tincture's asset credential stays one credential, in seconds.",
    "frame_credential_deadline_s" =>
      "How long an unobserved frame's credential lives before it is refused, in seconds.",
    "frame_invocation_max" => "The invocations one tincture frame may make per window.",
    "frame_invocation_window_ms" => "The frame invocation limit's window, in milliseconds.",
    "directory_serve" =>
      "Whether this node serves an identity directory: `off`, `writer` (the one writer of the identifiers it orders) or `mirror` (their history, accepting no write).",
    "directory_max_identities" =>
      "Identifiers a directory this node serves registers; at capacity a new genesis is refused, while existing registrations and recovery stay available.",
    "directory_log_bytes" =>
      "Bytes a directory this node serves keeps across its logs; existing history is never deleted to meet a lowered quota.",
    "directory_recovery_reserve_bytes" =>
      "Bytes of `directory_log_bytes` kept for recovery entries and their recorded outcomes, which rotations cannot use; below `directory_log_bytes`.",
    "identity_freshness_seconds" =>
      "How long this home trusts a remote person's verified identity head before reading their directory again, in seconds: how long a retired key can still act here.",
    "device_cert_seconds" =>
      "How long a device certificate this home issues lives, in seconds; a paired device renews at half of it.",
    "clock_skew_seconds" =>
      "How far a certificate's not-before or a signed message's time may sit from this home's clock, in seconds; it never extends a certificate's expiry.",
    "confirmation_seconds" =>
      "How long a pending confirmation of a sensitive change stays open, in seconds.",
    "reauth_seconds" =>
      "How recent a local person's door sign-in must be to register their first passkey with no fresh method, in seconds."
  }

  @doc "Every platform setting, in the order the boot reads them."
  @spec entries() :: [Entry.t()]
  def entries do
    [
      # ——— tenancy caps: each gates a creation, so each refuses stale ———
      cap(:max_athanors, "CYFR_MAX_ATHANORS", nil, "athanors"),
      cap(:max_groups_per_person, "CYFR_MAX_GROUPS_PER_PERSON", 50, "groups"),
      cap(:max_pairs_per_person, "CYFR_MAX_PAIRS_PER_PERSON", 200, "pairs"),
      cap(:max_members_per_group, "CYFR_MAX_MEMBERS_PER_GROUP", nil, "members"),
      cap(:max_threads_per_athanor, "CYFR_MAX_THREADS_PER_ATHANOR", 1000, "threads"),
      cap(:mint_per_hour, "CYFR_MINT_PER_HOUR", nil, "athanors"),
      %Entry{
        key: "athanor_storage_bytes",
        app: :sanctum,
        variable: "CYFR_ATHANOR_STORAGE_BYTES",
        type: :integer,
        default: nil,
        validator: byte_count(0..@max_bytes),
        group: :tenancy,
        scope: :live,
        stale: :refuse
      },

      # ——— execution slots, applied once at boot ———
      %Entry{
        key: "crucible_max_concurrent",
        app: :cyfr,
        config: [:crucible_max_concurrent],
        variable: "CYFR_CRUCIBLE_MAX_CONCURRENT",
        type: :integer,
        default: Prima.Slots.default_max(),
        # A quarter of the slots is the chain children's reserve, which must
        # hold a chain of the full authority depth (8): below 32 a deep
        # chain could wait on itself.
        validator: whole(32..1_000_000, "executions"),
        group: :execution,
        scope: :restart,
        stale: :serve,
        apply: @apply_execution_slots
      },
      %Entry{
        key: "crucible_max_concurrent_per_tenant",
        app: :cyfr,
        config: [:crucible_max_concurrent_per_tenant],
        variable: "CYFR_CRUCIBLE_MAX_CONCURRENT_PER_TENANT",
        type: :integer,
        default: Prima.Slots.default_key_max(),
        validator: whole(1..1_000_000, "executions"),
        group: :execution,
        scope: :restart,
        stale: :serve,
        apply: @apply_execution_slots
      },

      # ——— rate limits: served stale, so a store hiccup refuses nobody ———
      limit(:mcp_rate_limit_max, "CYFR_MCP_RATE_LIMIT_MAX", 120, requests(), :rate_limits),
      limit(
        :mcp_rate_limit_window_ms,
        "CYFR_MCP_RATE_LIMIT_WINDOW_MS",
        60_000,
        window(),
        :rate_limits
      ),
      %{
        limit(:api_rate_limit_max, "CYFR_API_RATE_LIMIT_MAX", nil, requests(), :rate_limits)
        | inherit: true
      },
      %{
        limit(
          :api_rate_limit_window_ms,
          "CYFR_API_RATE_LIMIT_WINDOW_MS",
          nil,
          window(),
          :rate_limits
        )
        | inherit: true
      },
      limit(
        :webhook_per_ip_rate_limit_max,
        "CYFR_WEBHOOK_PER_IP_RATE_LIMIT_MAX",
        6_000,
        requests(),
        :rate_limits
      ),

      # ——— per-member stream limits ———
      limit(
        :mcp_subscription_max_concurrent,
        "CYFR_MCP_SUBSCRIPTION_MAX_CONCURRENT",
        8,
        whole(1..1_000_000, "streams"),
        :streams
      ),
      limit(
        :mcp_subscription_max_ms,
        "CYFR_MCP_SUBSCRIPTION_MAX_MS",
        1_800_000,
        window(),
        :streams
      ),
      limit(
        :crucible_events_max_concurrent,
        "CYFR_CRUCIBLE_EVENTS_MAX_CONCURRENT",
        8,
        whole(1..1_000_000, "streams"),
        :streams
      ),
      limit(
        :crucible_events_max_ms,
        "CYFR_CRUCIBLE_EVENTS_MAX_MS",
        1_800_000,
        window(),
        :streams
      ),
      limit(
        :frame_stream_max_concurrent,
        "CYFR_FRAME_STREAM_MAX_CONCURRENT",
        8,
        whole(1..1_000_000, "streams"),
        :streams
      ),

      # ——— sessions and webhooks: security windows, refused stale ———
      %Entry{
        key: "session_ttl_hours",
        app: :sanctum,
        variable: "CYFR_SESSION_TTL_HOURS",
        type: :integer,
        # 0 is a value: sessions that never idle out.
        default: 720,
        validator: whole(0..876_000, "hours"),
        group: :sessions,
        scope: :live,
        stale: :refuse
      },
      %Entry{
        key: "webhook_max_skew_seconds",
        app: :sanctum,
        variable: "CYFR_WEBHOOK_MAX_SKEW_SECONDS",
        type: :duration_s,
        default: 300,
        validator: whole(1..86_400, "seconds"),
        group: :webhooks,
        scope: :live,
        stale: :refuse
      },
      %Entry{
        key: "webhook_idempotency_ttl_seconds",
        app: :cyfr,
        variable: "CYFR_WEBHOOK_IDEMPOTENCY_TTL_SECONDS",
        type: :duration_s,
        default: 86_400,
        validator: whole(1..31_536_000, "seconds"),
        group: :webhooks,
        scope: :live,
        stale: :refuse
      },

      # ——— the rest of the host's knobs ———
      %Entry{
        key: "device_label",
        app: :cyfr,
        variable: "CYFR_DEVICE_LABEL",
        type: :string,
        # Unset is the hostname, which the reader asks for itself.
        default: nil,
        validator: &label/1,
        group: :registry,
        scope: :live,
        stale: :serve
      },
      limit(
        :health_ready_cache_ms,
        "CYFR_HEALTH_READY_CACHE_MS",
        5_000,
        whole(0..86_400_000, "milliseconds"),
        :health
      ),
      limit(
        :decision_retention_days,
        "CYFR_DECISION_RETENTION_DAYS",
        365,
        whole(1..36_500, "days"),
        :retention
      ),
      %Entry{
        key: "opus_watch_poll_ms",
        app: :cyfr,
        variable: "CYFR_OPUS_WATCH_POLL_MS",
        type: :integer,
        default: 5_000,
        validator: whole(1_000..60_000, "milliseconds"),
        group: :workers,
        scope: :live,
        stale: :serve
      },
      %Entry{
        key: "opus_watch_misses",
        app: :cyfr,
        variable: "CYFR_OPUS_WATCH_MISSES",
        type: :integer,
        default: 3,
        validator: whole(1..100, "misses"),
        group: :workers,
        scope: :live,
        stale: :serve
      },
      limit(
        :locus_backends_lease_ms,
        "CYFR_LOCUS_BACKENDS_LEASE_MS",
        30_000,
        whole(1_000..60_000, "milliseconds"),
        :backends
      ),
      limit(
        :locus_backends_idle_ms,
        "CYFR_LOCUS_BACKENDS_IDLE_MS",
        900_000,
        whole(1_000..86_400_000, "milliseconds"),
        :backends
      ),
      %Entry{
        key: "log_level",
        app: :logger,
        config: [:level],
        variable: "CYFR_LOG_LEVEL",
        type: :atom,
        default: :info,
        validator: &level/1,
        group: :logging,
        scope: :live,
        stale: :serve,
        apply: @apply_log_level
      },

      # ——— the tincture credentials (read by Sanctum.TinctureAuth) and the per-frame rate (read by the tincture data routes) ———
      tincture(
        "asset_credential_window_s",
        "CYFR_ASSET_CREDENTIAL_WINDOW_S",
        :duration_s,
        3_600,
        whole(1..86_400, "seconds")
      ),
      tincture(
        "frame_credential_deadline_s",
        "CYFR_FRAME_CREDENTIAL_DEADLINE_S",
        :duration_s,
        3_600,
        whole(1..86_400, "seconds")
      ),
      tincture("frame_invocation_max", "CYFR_FRAME_INVOCATION_MAX", :integer, 120, requests()),
      tincture(
        "frame_invocation_window_ms",
        "CYFR_FRAME_INVOCATION_WINDOW_MS",
        :integer,
        60_000,
        window()
      ),

      # ——— identity, devices and confirmation: Sanctum's, refused stale ———
      %Entry{
        key: "directory_serve",
        app: :sanctum,
        variable: "CYFR_DIRECTORY_SERVE",
        type: :atom,
        default: :off,
        validator: &directory_serve/1,
        group: :directory,
        scope: :live,
        stale: :refuse
      },
      identity(
        :directory_max_identities,
        :integer,
        100_000,
        whole(1..1_000_000_000, "identifiers"),
        :directory
      ),
      identity(
        :directory_log_bytes,
        :integer,
        1_073_741_824,
        byte_count(1..@max_bytes),
        :directory
      ),
      identity(
        :directory_recovery_reserve_bytes,
        :integer,
        10_485_760,
        byte_count(1..@max_bytes),
        :directory
      ),
      identity(
        :identity_freshness_seconds,
        :duration_s,
        300,
        whole(1..86_400, "seconds"),
        :identity
      ),
      identity(:device_cert_seconds, :duration_s, 3_600, whole(1..86_400, "seconds"), :devices),
      identity(:clock_skew_seconds, :duration_s, 60, whole(1..3_600, "seconds"), :devices),
      identity(
        :confirmation_seconds,
        :duration_s,
        300,
        whole(1..3_600, "seconds"),
        :confirmation
      ),
      identity(:reauth_seconds, :duration_s, 300, whole(1..3_600, "seconds"), :confirmation)
    ]
    |> Enum.map(&%{&1 | doc: Map.fetch!(@setting_docs, &1.key)})
  end

  defp cap(key, variable, default, unit) do
    %Entry{
      key: Atom.to_string(key),
      app: :sanctum,
      variable: variable,
      type: :integer,
      # 0 disables a defaulted cap, so it is a value, not "unset".
      default: default,
      validator: whole(0..1_000_000_000, unit),
      group: :tenancy,
      scope: :live,
      stale: :refuse
    }
  end

  defp limit(key, variable, default, validator, group) do
    %Entry{
      key: Atom.to_string(key),
      app: :cyfr,
      variable: variable,
      type: :integer,
      default: default,
      validator: validator,
      group: group,
      scope: :live,
      stale: :serve
    }
  end

  defp tincture(key, variable, type, default, validator) do
    %Entry{
      key: key,
      app: :cyfr,
      variable: variable,
      type: type,
      default: default,
      validator: validator,
      group: :tinctures,
      scope: :live,
      stale: :serve
    }
  end

  # A security window or a directory quota Sanctum reads through
  # `Arca.PlatformSettings.effective/1`. Each refuses a stale value, and
  # none is zero: a window of no time or a quota of nothing is a
  # misconfiguration, not a way to turn one off.
  defp identity(key, type, default, validator, group) do
    %Entry{
      key: Atom.to_string(key),
      app: :sanctum,
      variable: "CYFR_" <> String.upcase(Atom.to_string(key)),
      type: type,
      default: default,
      validator: validator,
      group: group,
      scope: :live,
      stale: :refuse
    }
  end

  defp requests, do: whole(1..1_000_000_000, "requests")
  defp window, do: whole(1..86_400_000, "milliseconds")

  # ---------------------------------------------------------------------------
  # Validators
  # ---------------------------------------------------------------------------

  # A whole number of `unit` in `range`, from the environment's text (read
  # by the strict reader the boot has always used, `Prima.EnvValue`) or as
  # an integer.
  defp whole(_first.._last//1 = range, unit) do
    bounded(range, unit, &Prima.EnvValue.whole_number(&1, "value", range, unit))
  end

  # A count of bytes, whose range reaches past what `whole/2` reads.
  defp byte_count(_first.._last//1 = range) do
    bounded(range, "bytes", &Prima.EnvValue.bytes(&1, "value", range))
  end

  defp bounded(first..last//1, unit, read) do
    form = "must be a whole number of #{unit} from #{first} to #{last}"

    fn
      value when is_integer(value) and value >= first and value <= last ->
        {:ok, value}

      text when is_binary(text) ->
        case read.(fn _name -> text end) do
          {:ok, value} when is_integer(value) -> {:ok, value}
          _blank_or_refused -> {:error, form}
        end

      _other ->
        {:error, form}
    end
  end

  defp level(value) when is_atom(value) and not is_nil(value), do: level(Atom.to_string(value))

  defp level(text) when is_binary(text) and text in @levels,
    do: {:ok, String.to_existing_atom(text)}

  defp level(_other), do: {:error, "must be a Logger level: #{Enum.join(@levels, ", ")}"}

  defp directory_serve(value) when is_atom(value) and not is_nil(value),
    do: directory_serve(Atom.to_string(value))

  defp directory_serve(text) when is_binary(text) and is_map_key(@directory_serve, text),
    do: {:ok, Map.fetch!(@directory_serve, text)}

  defp directory_serve(_other),
    do: {:error, "must be one of off, writer, mirror"}

  defp label(text) when is_binary(text) do
    trimmed = String.trim(text)

    if trimmed != "" and byte_size(trimmed) <= 255 and String.printable?(trimmed),
      do: {:ok, trimmed},
      else: {:error, "must be 1 to 255 bytes of printable text"}
  end

  defp label(_other), do: {:error, "must be 1 to 255 bytes of printable text"}

  # ---------------------------------------------------------------------------
  # The inventory
  # ---------------------------------------------------------------------------

  @doc "The entry stored under `key`."
  @spec fetch(String.t()) :: {:ok, Entry.t()} | :error
  def fetch(key) when is_binary(key) do
    case Enum.find(entries(), &(&1.key == key)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  @doc "Every rostered setting's variable."
  @spec variables() :: [String.t()]
  def variables, do: for(%Entry{variable: v} <- entries(), v != nil, do: v)

  @doc """
  The deployment variables: read before the repo opens, deciding how the
  box is reachable, or a security posture a stolen operator session must
  not change. `OTEL_EXPORTER_OTLP_ENDPOINT` is not under the prefix and is
  listed so every name the boot reads has one home.
  """
  @spec deployment() :: [String.t()]
  def deployment, do: Enum.map(@deployment, &elem(&1, 0))

  @doc "Each deployment variable with its one sentence, in name order."
  @spec deployment_docs() :: [{String.t(), String.t()}]
  def deployment_docs, do: @deployment

  @doc """
  The names `docker-compose.yml` interpolates that no release reads: the
  containers' CPU and memory limits and Caddy's ACME address.
  """
  @spec compose_only() :: [String.t()]
  def compose_only, do: Enum.map(@compose_only, &elem(&1, 0))

  @doc "Each compose-only name with its one sentence."
  @spec compose_only_docs() :: [{String.t(), String.t()}]
  def compose_only_docs, do: @compose_only

  @doc """
  The `CYFR_*` names other programs own, each with its owner; a name
  ending in `*` is a prefix. Tolerated in the process environment alone.
  """
  @spec foreign() :: [{String.t(), String.t()}]
  def foreign, do: @foreign

  @doc """
  The installed data Arca's accessor reads (`Arca.PlatformSettings.install_defaults!/1`):
  each key's default and stale policy, plain values.
  """
  @spec defaults() :: %{String.t() => %{default: term(), stale: :refuse | :serve}}
  def defaults, do: Map.new(entries(), &{&1.key, %{default: &1.default, stale: &1.stale}})

  # Settings whose values bound each other: the first key's value is
  # strictly below the second's.
  @below [{"directory_recovery_reserve_bytes", "directory_log_bytes"}]

  @doc """
  The settings whose values bound each other, as `{key, other}`: `key`'s
  value must be strictly below `other`'s. The recovery reserve is part of
  the log quota, so it is below it.
  """
  @spec below() :: [{String.t(), String.t()}]
  def below, do: @below

  @doc """
  `key`'s value in `values` (store key to value, each as it would take
  effect) held to every pair of `below/0` it is in: `:ok`, or
  `{:error, form}`, the form `key`'s value must take, naming the other
  setting and its value. A pair `values` does not hold both of is not
  checked.
  """
  @spec check_below(String.t(), %{String.t() => term()}) :: :ok | {:error, String.t()}
  def check_below(key, values) when is_binary(key) and is_map(values) do
    Enum.find_value(@below, :ok, fn {low, high} ->
      with true <- key in [low, high],
           {:ok, value} when is_integer(value) <- Map.fetch(values, low),
           {:ok, bound} when is_integer(bound) <- Map.fetch(values, high),
           true <- value >= bound do
        if key == low,
          do: {:error, "must be below #{high} (#{bound})"},
          else: {:error, "must be above #{low} (#{value})"}
      else
        _holds_or_absent -> nil
      end
    end)
  end

  @doc """
  The pairs of `below/0` that `values` (store key to value, each as it
  would take effect) holds out of bound. A pair `values` does not hold
  both keys of is not checked.
  """
  @spec out_of_bound(%{String.t() => term()}) :: [{String.t(), String.t()}]
  def out_of_bound(values) when is_map(values) do
    for {low, _high} = pair <- @below, check_below(low, values) != :ok, do: pair
  end

  @doc """
  The environment's pins, `pinned` (store key to value), and `others`
  held to every pair of `below/0`. Each key of a pair reads as `pinned`
  sets it, else as `others` holds it: the stored value or the default, as
  it takes effect; a pair that does not hold both keys is not checked.
  Answers `:ok`, or `{:error, sentence}` naming the variable at fault,
  which is the pinned side of the pair. When both sides are pinned it
  names the lower one's variable and the other's; when neither is, it
  names both settings and the variables that can restore the bound.
  """
  @spec check_pinned(%{String.t() => term()}, %{String.t() => term()}) ::
          :ok | {:error, String.t()}
  def check_pinned(pinned, others) when is_map(pinned) and is_map(others) do
    Enum.find_value(@below, :ok, fn {low, high} ->
      values = Map.merge(Map.take(others, [low, high]), Map.take(pinned, [low, high]))

      case {Map.has_key?(pinned, low), Map.has_key?(pinned, high)} do
        {false, false} -> unpinned_refusal(low, high, values)
        {true, false} -> pinned_refusal(low, values, nil)
        {false, true} -> pinned_refusal(high, values, nil)
        {true, true} -> pinned_refusal(low, values, high)
      end
    end)
  end

  defp unpinned_refusal(low, high, values) do
    case check_below(low, values) do
      :ok ->
        nil

      {:error, form} ->
        {:error,
         "#{low} (#{Map.fetch!(values, low)}) #{form}; pin #{variable!(low)} or " <>
           "#{variable!(high)} to restore the bound"}
    end
  end

  defp pinned_refusal(key, values, also) do
    case check_below(key, values) do
      :ok -> nil
      {:error, form} when is_nil(also) -> {:error, "#{variable!(key)} #{form}"}
      {:error, form} -> {:error, "#{variable!(key)} #{form}, which #{variable!(also)} pins"}
    end
  end

  defp variable!(key) do
    {:ok, %Entry{variable: variable}} = fetch(key)
    variable
  end

  @doc """
  The `{application, key}` pairs the entries are written under: the head
  of each configuration path, the restart-scoped settings' and the log
  level's. `Cyfr.Boundaries` classes these keys `:setting`.
  """
  @spec config_keys() :: [{atom(), atom()}]
  def config_keys do
    for %Entry{app: app, config: [key | _]} <- entries(), uniq: true, do: {app, key}
  end

  @doc """
  The settings this boot's environment pinned, as `config/runtime.exs`
  recorded them: `{key, value}`, sorted by key.
  """
  @spec pinned() :: [{String.t(), term()}]
  def pinned, do: Application.get_env(:cyfr, :deployment_pinned, [])

  # ---------------------------------------------------------------------------
  # The boot
  # ---------------------------------------------------------------------------

  @doc """
  `entry`'s value as `getenv` spells its variable: `{:ok, nil}` when unset
  or blank, the validated value when set, or the refusal naming the
  variable and the form it must take.
  """
  @spec read(Entry.t(), getenv()) :: {:ok, term()} | {:error, String.t()}
  def read(%Entry{variable: nil}, _getenv), do: {:ok, nil}

  def read(%Entry{variable: variable, validator: validator}, getenv)
      when is_function(getenv, 1) do
    case Prima.EnvValue.text(getenv, variable) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, text} ->
        case validator.(text) do
          {:ok, value} -> {:ok, value}
          {:error, form} -> {:error, "#{variable}=#{inspect(text)} #{form}."}
        end
    end
  end

  @doc """
  The `CYFR_*` names the boot must refuse: those in `file_names` (every
  name the `.env` files it sources assign) that no entry, deployment
  variable or compose-only name declares, and those in `process_names`
  (its process environment) that none of those nor `foreign/0` declares.
  Sorted, each once.
  """
  @spec unknown([String.t()], [String.t()]) :: [String.t()]
  def unknown(file_names, process_names) when is_list(file_names) and is_list(process_names) do
    declared = MapSet.new(variables() ++ deployment() ++ compose_only())

    from_files = Enum.filter(file_names, &undeclared?(&1, declared))

    from_process =
      Enum.filter(process_names, &(undeclared?(&1, declared) and not foreign?(&1)))

    Enum.sort(Enum.uniq(from_files ++ from_process))
  end

  @doc "The refusal the boot raises for `names`, as `unknown/2` answers them."
  @spec refusal([String.t(), ...]) :: String.t()
  def refusal([_ | _] = names) do
    "#{Enum.join(names, ", ")} #{if match?([_], names), do: "is", else: "are"} not a " <>
      "variable this server reads: no platform setting, deployment variable or " <>
      "compose-only name declares it. Remove it, or use the name `.env.example` gives."
  end

  defp undeclared?(name, declared),
    do: String.starts_with?(name, "CYFR_") and not MapSet.member?(declared, name)

  defp foreign?(name) do
    Enum.any?(@foreign, fn {declared, _owner} ->
      case String.split_at(declared, -1) do
        {prefix, "*"} -> String.starts_with?(name, prefix)
        _exact -> name == declared
      end
    end)
  end
end
