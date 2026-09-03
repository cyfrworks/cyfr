# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Application do
  @moduledoc false

  require Logger
  require Arca.Repo.Errors

  use Application

  @impl true
  def start(_type, _args) do
    # One redaction vocabulary: Phoenix's inbound request-param filter is
    # fed from its owner (config/config.exs deliberately does not spell a
    # list — config files run before this module exists).
    Application.put_env(:phoenix, :filter_parameters, Sanctum.Sanitizer.filter_parameters())

    # Arca storage setup
    ensure_db_directory!()
    # Overlay wiring fails loud here — before Bootstrap or the tincture
    # registry scan the union — not on the first touch of whichever
    # overlaid root was left without a locator.
    Arca.Storage.install_locators!()
    maybe_migrate_before_pool()
    # The invoke-budget counters, owned by the application master so they
    # outlive every request that charges them. The Arca.Cache table is
    # deliberately NOT owned here: it is a disposable read-through cache,
    # created and re-created by its one supervised owner
    # (`Arca.Cache.Sweeper`) — a sweeper crash flushes it, harmlessly.
    Sanctum.Authority.Budget.ensure_table()

    # Emissary: Initialize OpenTelemetry instrumentation for Phoenix/Bandit
    if Application.get_env(:cyfr, :opentelemetry_enabled, false) do
      OpentelemetryBandit.setup()
      OpentelemetryPhoenix.setup(adapter: :bandit)
    end

    # Emissary: RunningTasks GenServer is now in the supervision tree

    # Resolve the at-rest cipher keyring before any worker can encrypt or
    # decrypt. Explicit `CYFR_CRYPTO_KEYRING` (JSON) wins; otherwise derive a
    # single-key keyring from `:secret_key_base` so single-user deployments
    # work zero-config. Rotating `:secret_key_base` invalidates every blob
    # encrypted under the derived key — platform deployments should set an
    # explicit keyring to avoid that coupling.
    resolve_crypto_keyring!()

    # CORS hardening once authentication is configured (and thus users other
    # than the operator can make credentialed cross-origin requests).
    enforce_cors_not_wildcard_with_auth()

    # OIDC issuer reserved-host check — only when OIDC is the configured
    # auth provider. A misconfigured generic-OIDC issuer would otherwise
    # only surface as a 500 at the user's login callback.
    validate_oidc_issuer_config!()

    # Warn (don't block) if auth is configured but no platform admin is
    # declared — no user could access the system until one is seeded.
    warn_if_no_platform_admin()

    # Attach OTEL tenant handler if OpenTelemetry is enabled
    if Application.get_env(:cyfr, :opentelemetry_enabled, false) do
      Cyfr.OtelTenantHandler.attach()
    end

    # Webhook verify-failed → log at :warning. Operators can disable by
    # detaching `"webhook-verify-failed-log"` if they prefer an alternative
    # sink (e.g. forwarding to SIEM via a Telemetry Metrics consumer).
    attach_webhook_verify_failed_logger()
    Cyfr.ScheduleNotes.attach()

    infra_children = [
      # Arca storage layer
      Arca.Repo,
      # The cache table's one owner, grouped :rest_for_one with the two
      # registries that write catalogues into it: when the sweeper dies the
      # table dies with it, and the writers restart and repopulate instead
      # of answering "Unknown tool" until a 23-hour refresh (this retires
      # their hand-rolled :rebuild_cache recovery). Before anything that
      # might read through the cache.
      group(Arca.Cache.TreeSupervisor, [
        Arca.Cache.Sweeper,
        Emissary.MCP.ToolRegistry,
        Emissary.MCP.ResourceRegistry
      ]),
      # Orders whole-unit replacement so two commits to one unit cannot
      # interleave their clear-then-write (Arca.Overlay.UnitLock).
      Arca.Overlay.UnitLock,
      # The write-behind for bookkeeping rows (allowed policy lines, MCP log
      # completions, vault last-used); right after the repo so it drains
      # before the repo goes down.
      Cyfr.RecordSink,
      Cyfr.RetentionScheduler,
      Arca.AuditHandler,
      # Releases a charged invoke-budget slot when its holder dies without
      # running its `after` (the brutal-kill cancel/timeout paths).
      Sanctum.Authority.BudgetGuard,
      # Request rate-limit counters — own table, isolated from Arca.Cache so an
      # attacker-cardinality flood cannot evict sessions or OAuth state.
      Cyfr.RateLimiter,
      # Emissary web layer
      EmissaryWeb.Telemetry,
      {Phoenix.PubSub, name: Emissary.PubSub},
      # subscriptions/listen stream slots — duplicate keys, one entry per open
      # stream, keyed by {athanor_id, user_id}. An entry dies with its conn
      # process, so a vanished client frees its slot without bookkeeping.
      {Registry, keys: :duplicate, name: Emissary.MCP.SubscriptionRegistry},
      # External MCP servers: the name registry, the server processes
      # registered in it, and the reconciler that restarts them when a
      # vault mutation must bite (§4.6) — one :rest_for_one group, so a
      # dead registry never leaves live servers unfindable.
      group(Emissary.MCP.ExternalServerTree, [
        {Registry, keys: :unique, name: Emissary.MCP.ExternalServerRegistry},
        {DynamicSupervisor, name: Emissary.MCP.ExternalServerSupervisor, strategy: :one_for_one},
        Emissary.MCP.ExternalServerReconciler
      ]),
      Emissary.MCP.Progress,
      {Task.Supervisor, name: Emissary.TaskSupervisor},
      Emissary.MCP.RunningTasks,
      # Sanctum auth sliver — its own Finch pool for IdP OAuth Device-Flow
      # HTTP calls (GitHub / Google). Compendium's registry and OCI traffic
      # goes through `Cyfr.Network.pinned_request/5`, which owns its own
      # connections; this pool keeps OAuth userinfo HTTP off that path and
      # reinforces the sliver boundary at the supervision level.
      {Finch, name: Sanctum.Auth.Finch},
      # OAuth refresh single-flight (see Sanctum.OAuth.RefreshLock): the
      # registry and the task pool whose leaders register in it restart
      # together.
      group(Sanctum.OAuth.RefreshTree, [
        {Registry, keys: :unique, name: Sanctum.OAuth.RefreshRegistry},
        {Task.Supervisor, name: Sanctum.OAuth.RefreshTaskSupervisor}
      ]),
      # Provisioning retries that must not ride a sign-in (registry pulls).
      {Task.Supervisor, name: Sanctum.ProvisioningSupervisor},
      # Single-use consent authorizations. The shipped store is the DB
      # (config.exs pins Proof.DB); the in-memory GenServer starts only
      # when a deployment explicitly configures it, so production does not
      # carry a live, never-called singleton.
      maybe_proof_memory(),
      # Prism dashboard
      Prism.TelemetryBridge,
      Prism.TinctureRegistry,
      {Task.Supervisor, name: Aqua.TaskSupervisor},
      # Conversation runners: one process per conversation with a live
      # turn, started on demand; the recovery task re-follows the turns
      # that were running when the server last stopped. Registry and the
      # supervisor whose children register in it restart together.
      group(Aqua.ConversationTree, [
        {Registry, keys: :unique, name: Aqua.ConversationRegistry},
        {DynamicSupervisor, name: Aqua.ConversationSupervisor, strategy: :one_for_one},
        maybe_conversation_recovery()
      ]),
      # Last, and synchronous: mints Home's rows from the seed union on first
      # boot (the overlay serves the bundle in place — no bytes are copied)
      # and reconciles the platform-admin roster against the env. Needs the
      # repo, the tincture registry (the scan reloads it) and nothing else.
      #
      # It runs its work in `init/1` and answers `:ignore`, so this child
      # finishing is what gates the web tier below — the endpoint must not
      # answer requests while Home is half-seeded or while a de-listed
      # operator's sessions are still live.
      Supervisor.child_spec(Cyfr.Bootstrap, restart: :temporary)
    ]

    infra_children = List.flatten(infra_children)

    web_children = [EmissaryWeb.Endpoint]

    # Two tiers under a :rest_for_one root so each has its own restart budget:
    # a crash-looping endpoint exhausts only the web tier (infra keeps running,
    # then the root restarts just the web tier), while an infra collapse
    # restarts infra AND the web tier so endpoints rebind to fresh
    # Repo/PubSub/registries instead of holding dead references. Shutdown is
    # reverse start order: endpoints drain before infra goes down.
    children = [
      tier(Cyfr.InfraSupervisor, infra_children),
      tier(Cyfr.WebSupervisor, web_children)
    ]

    opts = [strategy: :rest_for_one, name: Cyfr.Supervisor, max_restarts: 10, max_seconds: 60]
    Supervisor.start_link(children, opts)
  end

  # Off in the test env: suites drive runners directly.
  defp maybe_conversation_recovery do
    if Application.get_env(:cyfr, :conversation_recovery, true) do
      [
        Supervisor.child_spec(
          {Task, &Aqua.ConversationRunner.recover_all/0},
          id: Aqua.ConversationRecovery,
          restart: :temporary
        )
      ]
    else
      []
    end
  end

  defp maybe_proof_memory do
    case Cyfr.RuntimeConfig.consent_proof_store() do
      Sanctum.Consent.Proof.Memory -> [Sanctum.Consent.Proof.Memory]
      _ -> []
    end
  end

  # A registry and the processes that hold references into it restart
  # together: :rest_for_one from the registry (or table owner) down, so a
  # restart never leaves dependents holding a name that resolves to
  # nothing — and the dependents' own hand-rolled recovery loops retire.
  defp group(name, children) do
    %{
      id: name,
      start:
        {Supervisor, :start_link,
         [
           List.flatten(children),
           [strategy: :rest_for_one, name: name, max_restarts: 10, max_seconds: 60]
         ]},
      type: :supervisor
    }
  end

  defp tier(name, children) do
    %{
      id: name,
      start:
        {Supervisor, :start_link,
         [children, [strategy: :one_for_one, name: name, max_restarts: 10, max_seconds: 60]]},
      type: :supervisor
    }
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EmissaryWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp ensure_db_directory! do
    config = Application.get_env(:cyfr, Arca.Repo, [])

    if db_path = config[:database] do
      # arca:bypass-ok=B — pre-Arca bootstrap; runs before Arca.Repo starts.
      # SQLite-only path; Postgres builds skip this branch (db_path is nil).
      db_path |> Path.dirname() |> File.mkdir_p!()
    end
  end

  # Run migrations before the connection pool starts to avoid
  # "database is locked" errors from pool connections racing with
  # migration DDL statements on first startup. `CYFR_AUTO_MIGRATE=false`
  # leaves the step to the operator (`Cyfr.Release.migrate/0`).
  #
  # A database created before the baseline has older versions in
  # `schema_migrations` but not this file's version, so Ecto would try to
  # apply the baseline on top of the old schema. Baseline.up refuses that.
  # There is no upgrade path: drop the database (or the volume) and let it
  # be created fresh.
  defp maybe_migrate_before_pool do
    if Application.get_env(:cyfr, :auto_migrate, true) do
      config = Application.get_env(:cyfr, Arca.Repo, [])
      verify_db_writable!(config[:database])
      # Start a temporary repo with pool_size=1 just for migrations
      {:ok, repo_pid} = Arca.Repo.start_link(Keyword.put(config, :pool_size, 1))
      Ecto.Migrator.run(Arca.Repo, migrations_path(), :up, all: true)
      configure_database()
      # Right after the migrations, while the repo that ran them is still
      # up and the schema is definitive: every table carrying `athanor_id`
      # must be one `Sanctum.Tenancy.Athanors.destroy/1` deletes. A new
      # athanor-scoped table that nobody added to the roster would
      # otherwise survive an erasure that reported success — which is
      # precisely how the original gap went unnoticed. Raises: a boot that
      # fails is recoverable, a backup full of data somebody was told was
      # deleted is not.
      Arca.TenantTables.verify_roster!()
      # Stop the temporary repo so the supervisor can start the real one
      Supervisor.stop(repo_pid)
    end
  end

  defp verify_db_writable!(nil), do: :ok

  defp verify_db_writable!(path) do
    dir = Path.dirname(path)
    test_file = Path.join(dir, ".cyfr_write_test")

    # arca:bypass-ok=B — pre-Arca bootstrap probe used to surface friendly
    # Docker UID errors before the Repo pool tries to open the DB.
    case File.touch(test_file) do
      :ok ->
        File.rm(test_file)

      {:error, reason} ->
        {uid, 0} = System.cmd("id", ["-u"])
        uid = String.trim(uid)

        raise """
        [Arca] Cannot write to database directory: #{dir} (#{reason})

        If running in Docker with bind mounts (e.g. ./data:/app/data),
        the host directory must be writable by the container user (UID #{uid}).

        Fix: on the host, run:
          sudo chown -R #{uid} #{dir}
        """
    end
  end

  defp configure_database do
    case Cyfr.RuntimeConfig.repo_adapter() do
      Ecto.Adapters.SQLite3 ->
        Arca.Repo.query!("PRAGMA journal_mode=WAL")
        Arca.Repo.query!("PRAGMA busy_timeout=#{Cyfr.RuntimeConfig.sqlite_busy_timeout_ms()}")

      _ ->
        :ok
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.warning("[Arca] Database configuration failed: #{Exception.message(e)}")
      :ok
  end

  defp migrations_path do
    Application.app_dir(:cyfr, "priv/repo/migrations")
  end

  defp attach_webhook_verify_failed_logger do
    handler_id = "cyfr-webhook-verify-failed-log"

    # Detaching first makes the call idempotent across application restarts
    # in iex `:application.stop/start` cycles. Errors from detach when no
    # handler is attached are explicitly safe per :telemetry docs.
    _ = :telemetry.detach(handler_id)

    :telemetry.attach(
      handler_id,
      [:cyfr, :emissary, :webhook, :verify_failed],
      &__MODULE__.log_webhook_verify_failed/4,
      nil
    )
  end

  @doc false
  def log_webhook_verify_failed(_event, _measurements, metadata, _config) do
    Logger.warning(
      "[Webhook] verify_failed slug=#{inspect(metadata[:slug])} reason=#{metadata[:reason]}"
    )
  end

  # A wildcard CORS origin is a CSRF/credential-leak risk once authentication
  # is configured (users beyond the operator can make credentialed cross-origin
  # requests) — it must then be an explicit allowlist. Fail closed at boot in a
  # real release (gated on RELEASE_ROOT, so dev/test are never blocked); warn
  # loudly otherwise. A no-auth deployment keeps the wildcard default.
  defp enforce_cors_not_wildcard_with_auth do
    decision =
      cors_enforcement(
        Sanctum.auth_configured?(),
        Cyfr.RuntimeConfig.cors_allowed_origins(),
        Cyfr.RuntimeConfig.release?()
      )

    case decision do
      :ok -> :ok
      {:raise, message} -> raise message
      {:warn, message} -> Logger.warning(message)
    end

    warn_if_origin_allowlists_diverge()
    warn_if_public_origin_missing()
  end

  # `CYFR_PUBLIC_URL` is the address this instance is reachable at from
  # outside, and it is the only place a SCHEME is configured — the endpoint's
  # `:url` carries a host and a port and nothing sets `scheme`. Unset, an
  # OAuth `redirect_uri` and a webhook URL are built as `http://<host>:<port>`,
  # which behind the shipped TLS profile is neither what the provider has
  # registered nor where a sender can reach us. It fails at the exchange, far
  # from the cause, so say it at boot.
  defp warn_if_public_origin_missing do
    if is_nil(Cyfr.RuntimeConfig.public_url()) and
         not is_nil(Application.get_env(:cyfr, :auth_provider)) do
      Logger.warning(
        "[Cyfr] CYFR_PUBLIC_URL is not set. OAuth redirect URIs and webhook URLs " <>
          "will be built from CYFR_HOST/CYFR_PORT as http://…, which a TLS " <>
          "deployment's provider will reject. Set it to this server's external " <>
          "origin, scheme included (e.g. https://cyfr.example.com)."
      )
    end

    :ok
  end

  # Two knobs answer "which origins may talk to this server": CORS (browser
  # cross-origin, default "*", guarded above) and MCP Origin (DNS-rebinding
  # guard, default localhost-only). An operator who opens one but not the
  # other gets a half-closed deployment that fails confusingly at request
  # time — say so at boot instead.
  defp warn_if_origin_allowlists_diverge do
    cors = Cyfr.RuntimeConfig.cors_allowed_origins()

    # "Customized" asks whether the operator SET the key, not what it
    # resolves to — so the MCP side reads key presence. Asking that as a
    # presence check rather than a second default keeps
    # `Cyfr.RuntimeConfig.mcp_allowed_origins/0` the only place the localhost
    # default is spelled, and stops an explicit empty list reading as unset.
    cors_customized? = "*" not in cors

    mcp_customized? =
      Application.get_env(:cyfr, :mcp_allowed_origins) != nil or
        Application.get_env(:cyfr, :mcp_extra_origins, []) != []

    if cors_customized? and not mcp_customized? do
      Logger.warning(
        "[Cyfr] CYFR_CORS_ALLOWED_ORIGINS is set but CYFR_MCP_ALLOWED_ORIGINS is not — " <>
          "browser MCP requests from #{inspect(cors)} will pass CORS and then be " <>
          "refused by the MCP Origin check (localhost-only default). Set " <>
          "CYFR_MCP_ALLOWED_ORIGINS to match."
      )
    end

    :ok
  end

  @doc false
  # Pure decision seam (testable without booting). A wildcard CORS origin in a
  # deployment that has authentication configured lets ANY origin make
  # credentialed cross-origin requests — it must be an explicit allowlist. Fail
  # closed at boot in a real release (gated on RELEASE_ROOT, so dev/test are
  # never blocked); warn loudly otherwise.
  @spec cors_enforcement(boolean(), term(), boolean()) ::
          :ok | {:raise, String.t()} | {:warn, String.t()}
  def cors_enforcement(auth_configured?, origins, real_release?) do
    if auth_configured? and "*" in List.wrap(origins) do
      message =
        "[Cyfr] FATAL: CORS wildcard \"*\" is configured in a deployment with " <>
          "authentication enabled. This allows ANY origin to make credentialed " <>
          "cross-origin requests. Set CYFR_CORS_ALLOWED_ORIGINS (comma-separated " <>
          "origins) — or :cyfr, :cors_allowed_origins in config — to an " <>
          "explicit origin allowlist."

      if real_release? do
        {:raise, message}
      else
        {:warn, message <> " (boot-raise suppressed outside a release)"}
      end
    else
      :ok
    end
  end

  # When auth is configured but no platform admin is declared, no user can be
  # admitted until a membership row is seeded (authentication succeeds but the
  # tenant gate yields no_athanor). Warn at boot — both under `mix phx.server` and in
  # releases — so the operator knows to set CYFR_PLATFORM_ADMIN_EMAILS. Stays
  # quiet in test, where no auth provider is configured.
  defp warn_if_no_platform_admin do
    auth_configured? = Sanctum.auth_configured?()
    no_admins? = Sanctum.Door.platform_admin_emails() == []

    if auth_configured? and no_admins? do
      Logger.warning(
        "[Cyfr] WARNING: :auth_provider is configured but CYFR_PLATFORM_ADMIN_EMAILS " <>
          "is empty — no user can access the system. Set CYFR_PLATFORM_ADMIN_EMAILS=" <>
          "<your_email> or seed a membership row manually."
      )
    end
  end

  # OIDC issuer reserved-host check. A generic-OIDC issuer pointed at a
  # reserved direct-provider host (github.com, accounts.google.com) would
  # produce cross-deployment colliding user ids and silently break login.
  # Surface it at boot so a deploy fails loudly instead of every login.
  defp validate_oidc_issuer_config! do
    if Cyfr.RuntimeConfig.auth_provider() == Sanctum.Auth.OIDC do
      case check_oidc_issuer(Cyfr.RuntimeConfig.oidc_issuer()) do
        :ok -> :ok
        {:error, message} -> raise "[Cyfr] FATAL: #{message}"
      end
    end
  end

  @doc false
  # Pure validation seam (testable without booting). Mirrors the runtime
  # assertion in Sanctum.Auth.OIDC.resolve_issuer/2.
  @spec check_oidc_issuer(term()) :: :ok | {:error, String.t()}
  def check_oidc_issuer(issuer) when is_binary(issuer) and issuer != "" do
    if Sanctum.Auth.Identity.reserved_issuer?(issuer) do
      {:error,
       "CYFR_OIDC_ISSUER (#{issuer}) is a reserved direct-provider host. " <>
         "ueberauth_oidcc against github.com/accounts.google.com produces " <>
         "cross-deployment colliding user ids; use GitHub/Google OAuth directly " <>
         "(CYFR_GITHUB_CLIENT_ID / CYFR_GOOGLE_CLIENT_ID)."}
    else
      :ok
    end
  end

  def check_oidc_issuer(_),
    do:
      {:error,
       "CYFR_AUTH_PROVIDER=oidc is selected but :cyfr, :oidc_issuer is absent or blank. " <>
         "Set CYFR_OIDC_ISSUER to your identity provider's issuer URL."}

  # Resolve and pin `:cyfr, :crypto_keyring`. Idempotent — re-runs on app
  # restart simply re-derive (or re-parse) the same keyring.
  #
  # KNOWN GAP, deliberately not fixed here: nothing records WHICH material
  # a deployment booted with. `nil` and `""` both fall through to
  # derivation, and the derived key is also labelled "default" — so an
  # explicit keyring that goes missing is replaced by a different key under
  # the same label, and the athanor forks into two key generations with no
  # boundary event. Rows sealed before fail `:aad_or_key_mismatch` while new
  # writes succeed, which reads as corruption rather than as configuration.
  #
  # The fix is a persisted fingerprint and a boot refuse. It is staged rather
  # than written here because a boot refuse can brick a volume restore:
  # record the fingerprint first, warn on mismatch for one release to find
  # the deployments already forked, and only then refuse. The fingerprint
  # belongs in the database, not a per-volume file — two nodes sharing one
  # database would disagree the moment they each kept their own — and the
  # obvious `..._MIGRATE=1` escape hatch would be a lie while
  # `Sanctum.Cipher` has no bulk re-seal: it would promise a migration it
  # cannot perform.
  defp resolve_crypto_keyring! do
    case Application.get_env(:cyfr, :crypto_keyring) do
      %{primary: _, keys: _} = keyring when map_size(keyring.keys) > 0 ->
        :ok

      _ ->
        # runtime.exs reads CYFR_CRYPTO_KEYRING through Dotenvy (OS env and
        # .env files alike) into :crypto_keyring_json — reading the OS env
        # directly here ignored a .env-configured keyring.
        keyring =
          case Application.get_env(:cyfr, :crypto_keyring_json) do
            nil ->
              derive_keyring_from_secret_key_base!()

            "" ->
              derive_keyring_from_secret_key_base!()

            json ->
              parse_keyring_env!(json)
          end

        Application.put_env(:cyfr, :crypto_keyring, keyring)
    end
  end

  defp derive_keyring_from_secret_key_base! do
    case Application.get_env(:cyfr, :secret_key_base) do
      key when is_binary(key) and byte_size(key) >= 32 ->
        # A supported zero-config posture — but in a release the operator
        # should know their ciphertexts are keyed to the Phoenix secret:
        # rotating CYFR_SECRET_KEY_BASE orphans every sealed blob. The
        # neighbouring boot checks warn; so does this one.
        if Cyfr.RuntimeConfig.release?() do
          Logger.warning(
            "[Cyfr] No CYFR_CRYPTO_KEYRING set — deriving the crypto keyring from " <>
              "CYFR_SECRET_KEY_BASE. Rotating that secret will orphan everything " <>
              "sealed under it; set an explicit CYFR_CRYPTO_KEYRING to decouple them."
          )
        end

        master = :crypto.hash(:sha256, "cyfr-cipher-keyring|" <> key)
        %{primary: "default", keys: %{"default" => master}}

      _ ->
        raise """
        [Cyfr] FATAL: cannot derive :crypto_keyring — :secret_key_base is
        missing or shorter than 32 bytes. Set CYFR_SECRET_KEY_BASE (>= 32
        bytes) or provide CYFR_CRYPTO_KEYRING as JSON
        `{"primary": "label", "keys": {"label": "<base64-32-bytes>"}}`.
        """
    end
  end

  @doc false
  # Public for the same reason `cors_enforcement/3` is: boot policy that
  # refuses a deployment should be testable without booting one.
  @spec parse_keyring_env!(String.t()) :: %{primary: String.t(), keys: map()}
  def parse_keyring_env!(json) do
    case Jason.decode(json) do
      {:ok, %{"primary" => primary, "keys" => keys}}
      when is_binary(primary) and primary != "" and is_map(keys) and map_size(keys) > 0 ->
        decoded =
          Map.new(keys, fn {label, b64} ->
            validate_key_label!(label)

            case Base.decode64(b64) do
              {:ok, bin} when byte_size(bin) >= 32 ->
                {label, bin}

              _ ->
                raise "[Cyfr] FATAL: CYFR_CRYPTO_KEYRING key #{inspect(label)} is not >= 32 bytes of base64"
            end
          end)

        unless Map.has_key?(decoded, primary) do
          raise "[Cyfr] FATAL: CYFR_CRYPTO_KEYRING primary #{inspect(primary)} is not in :keys"
        end

        refuse_duplicate_key_material!(decoded)

        %{primary: primary, keys: decoded}

      _ ->
        raise "[Cyfr] FATAL: CYFR_CRYPTO_KEYRING must be JSON of the form " <>
                ~s({"primary": "label", "keys": {"label": "<base64-32-bytes>"}})
    end
  end

  # The envelope stores the label as `byte_size(label)::8`, so a label of 256
  # bytes or more writes a length byte that does not describe it and produces
  # ciphertext nothing can ever parse back. An empty label is refused for the
  # matching reason at the other end: `Sanctum.Cipher.envelope/1` requires
  # `llen > 0`, so a zero-length label decrypts fine but reads as `unknown` to
  # the rotation audit and aborts a rotation run.
  defp validate_key_label!(label) when is_binary(label) do
    cond do
      label == "" ->
        raise "[Cyfr] FATAL: CYFR_CRYPTO_KEYRING contains an empty key label"

      byte_size(label) > 255 ->
        raise "[Cyfr] FATAL: CYFR_CRYPTO_KEYRING key label #{inspect(binary_part(label, 0, 32))}… " <>
                "is #{byte_size(label)} bytes; the envelope stores the length in one byte, so " <>
                "labels must be 1..255 bytes"

      true ->
        :ok
    end
  end

  defp validate_key_label!(label) do
    raise "[Cyfr] FATAL: CYFR_CRYPTO_KEYRING key label #{inspect(label)} is not a string"
  end

  # Two labels over the same bytes are not two keys. The derived key is a
  # function of the master material and the purpose — not the label (the label
  # is bound in the AAD, which is what stops a row from being read under
  # another label, but it does not change the key). So "rotating" by adding a
  # new label over the same material re-encrypts every row under the key it
  # already had, while `Sanctum.Cipher.Rotation.audit/0` — which reports label
  # distribution — calls the run a success. Refuse the shape at boot rather
  # than let an operator believe they rotated.
  defp refuse_duplicate_key_material!(decoded) do
    duplicates =
      decoded
      |> Enum.group_by(fn {_label, material} -> material end, fn {label, _} -> label end)
      |> Enum.filter(fn {_material, labels} -> length(labels) > 1 end)
      |> Enum.map(fn {_material, labels} -> Enum.sort(labels) end)
      |> Enum.sort()

    if duplicates != [] do
      raise """
      [Cyfr] FATAL: CYFR_CRYPTO_KEYRING reuses the same key material under \
      more than one label: #{inspect(duplicates)}.

      The derived key depends on the material and the purpose, not on the \
      label, so these labels are one key wearing several names. Re-encrypting \
      onto one of them would report a completed rotation while leaving every \
      row under the key it already had. Give the new label fresh material \
      (32+ random bytes), or drop it.
      """
    end

    :ok
  end
end
