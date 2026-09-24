# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Application do
  @moduledoc false

  require Logger

  use Application

  # config:compile-runtime-ok — the permission is compiled in on purpose: a
  # release is built without it, so no runtime setting can omit the gate.
  @bootstrap_skip_permitted Application.compile_env(:cyfr, :bootstrap_skip_permitted, false)

  @impl true
  def start(_type, _args) do
    # The five ports' one write each, before every domain this
    # application starts: each declaring module reads its implementation
    # from the term written here, and an uninstalled port raises where it
    # is asked rather than answering as though nothing were there. The
    # storage and counted caps, asked on the first tenant byte; consent's
    # view of the operation table; the component facts a consent rests on;
    # the proxied `server:tool` tools the table resolves on a miss; and
    # the overlaid roots' unit locators, asserted against the layout here
    # before Bootstrap or the tincture registry scans the union.
    Prima.Caps.install!(Sanctum.Tenancy.Caps)
    Sanctum.Grimoire.install!(Grimoire.Catalog)
    Sanctum.Consent.Components.install!(Compendium.ConsentFacts)
    Grimoire.Proxy.install!(Emissary.External.Proxy)

    Arca.Storage.UnitLocator.install!(%{
      "aqua" => Compendium.AquaPath,
      "components" => Compendium.ComponentPath
    })

    # The operation table and its resource index, built from the
    # configured providers and written once into Grimoire's term — after
    # the ports its audit and its providers read, before any process that
    # dispatches, derives a consent shape or serves `tools/list` exists.
    # A provider that cannot load, or a declaration the gates cannot
    # classify, refuses the boot here.
    Grimoire.Catalog.load!()

    # One redaction vocabulary: Phoenix's inbound request-param filter is
    # fed from its owner (config/config.exs deliberately does not spell a
    # list — config files run before this module exists).
    Application.put_env(:phoenix, :filter_parameters, Prima.Sanitizer.filter_parameters())

    # This boot's name, before any row can carry it, and the worker root
    # every assignment, worker and attempt key this boot issues derives
    # from.
    Prima.Boot.mint()
    Crucible.Keys.mint()

    # Resolve the at-rest cipher keyring before anything seals a row. The
    # `arca` application has already opened the database and run the
    # migrations by now — neither seals anything — and
    # `Cyfr.KeyringFingerprint.Check` below still compares this keyring
    # with the one the database was sealed under before any work runs.
    # Explicit `CYFR_CRYPTO_KEYRING` (JSON) wins; otherwise derive a
    # single-key keyring from `:sanctum, :secret_key_base` so single-user
    # deployments work zero-config. Rotating that secret invalidates every
    # blob encrypted under the derived key — platform deployments should
    # set an explicit keyring.
    resolve_crypto_keyring!()

    # Emissary: Initialize OpenTelemetry instrumentation for Phoenix/Bandit
    if Application.get_env(:cyfr, :opentelemetry_enabled, false) do
      OpentelemetryBandit.setup()
      OpentelemetryPhoenix.setup(adapter: :bandit)
    end

    # Grimoire: RunningTasks GenServer is now in the supervision tree

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

    # Two tiers under a :rest_for_one root so each has its own restart budget:
    # a crash-looping endpoint exhausts only the web tier (infra keeps running,
    # then the root restarts just the web tier), while an infra collapse
    # restarts infra AND the web tier so endpoints rebind to fresh
    # PubSub and registries instead of holding dead references. The repo is
    # the `arca` application's and restarts under its own supervisor;
    # everything here reaches it by name. Shutdown is reverse start order:
    # endpoints drain before infra goes down.
    children = for {name, tier_children} <- tiers(), do: tier(name, tier_children)

    opts = [strategy: :rest_for_one, name: Cyfr.Supervisor, max_restarts: 10, max_seconds: 60]
    Supervisor.start_link(children, opts)
  end

  @doc false
  # The two tiers in start order, each with its children in start order —
  # the census `Cyfr.StartupAdmissionBarrierTest` reads, so the test and
  # the boot cannot describe different trees.
  @spec tiers() :: [{module(), [Supervisor.child_spec() | module() | {module(), term()}]}]
  def tiers do
    [
      {Cyfr.InfraSupervisor, List.flatten([pre_gate(), gate(), post_gate(), seed_offer()])},
      {Cyfr.WebSupervisor, [EmissaryWeb.Endpoint]}
    ]
  end

  # Before the gate: only what the security reconcile needs and what must
  # hear its announcements. None of these runs tenant work, projects a
  # credential, dispatches to a provider, starts a backend or recovers
  # anything; each only answers once something else calls it.
  defp pre_gate do
    [
      # The database is the one this release's schema built, its tenant
      # roster covers the schema, and its keyring is the one this boot
      # resolved — before any worker reads a row or seals one under a
      # different key wearing the same label. The `arca` application
      # opened the pool and migrated before this one started; these read
      # through it and run whether or not this boot migrated.
      database_checks(),
      # The cell forms before its members claim their slots: a member that
      # believes it is alone because nothing connected it is precisely the
      # failure `Cyfr.Cell`'s refusals exist to stop.
      cluster_supervisor(),
      # This member's slot in the cell — claimed before anything that
      # assumes it is the only one holding this database, and the slot the
      # security reconcile runs under.
      cell_claim(),
      # The audit roster is the catalog's, read here and handed down: an
      # event is audited exactly when `Cyfr.Telemetry.Catalog` names
      # `:audit` among its consumers. The storage layer holds the handler
      # and the sinks; naming the catalog is the host's part.
      {Arca.AuditHandler, events: Cyfr.Telemetry.Catalog.consumed_by(:audit)},
      # Emissary web layer
      EmissaryWeb.Telemetry,
      # The bus's server (`Cyfr.Bus`): nothing else names it.
      {Phoenix.PubSub, name: Cyfr.PubSub},
      # Drops this member's cached authorization decisions when any member
      # says one is no longer good. Right after PubSub, and before
      # anything that establishes a caller.
      Cyfr.StandingWatch,
      # The host's telemetry-to-bus bridge, attached before the reconcile
      # announces a revocation, so the announcement reaches mounted views.
      Cyfr.TelemetryBridge
    ]
  end

  # The gate: synchronous, and a checked success or no boot. Its `init/1`
  # returns only after the reconcile committed, its claim was released
  # and this member's slot re-verified; a refusal stops the supervisor's
  # start, so nothing after it ever starts. Only the sandboxed test boot
  # omits it, where no process may write before a test checks out the
  # sandbox — see `bootstrap_skipped?/2`.
  defp gate do
    if bootstrap_skipped?(@bootstrap_skip_permitted, boot_work_enabled?()),
      do: [],
      else: [Supervisor.child_spec(Cyfr.Bootstrap, restart: :temporary)]
  end

  # After the gate: everything that admits work — fires a schedule,
  # recovers a turn, starts a backend, serves a host call, dispenses a
  # credential or publishes a result.
  defp post_gate do
    [
      Cyfr.RetentionScheduler,
      # Keeps a completed schedule's outcome as a note when the schedule
      # asked for it: subscribed to the committed completions before the
      # scheduler can fire, and acting only on its own member's.
      Aqua.ScheduleNotes,
      # Recurring component executions: the runs the scheduler fires are
      # tasks of their own, monitored by it.
      Supervisor.child_spec({Task.Supervisor, name: Crucible.Schedules.TaskSupervisor},
        shutdown: 30_000
      ),
      Crucible.Schedules.Scheduler,
      # Execution admission: the slots a member's own work holds. The
      # consented rate has no child here — its window is a row every
      # member of the cell claims in (`Arca.RateWindows`), so there is
      # nothing in this boot to start, own or lose.
      execution_slots(),
      # Execution bookkeeping, after PubSub (the buffers broadcast on it):
      # the execution_id → driving-process registry, the per-execution
      # event-buffer registry, the emit counter, the buffers, and the open
      # attempts' registry and supervisor. The counter comes before the
      # buffers, so a restart of this group rebuilds the numbering source
      # first and then the buffers that read it; the attempts, which push
      # onto the buffers, come last; a dead registry restarts what
      # registers in it.
      group(Crucible.Tree, [
        {Registry, keys: :unique, name: Crucible.Registry},
        {Registry, keys: :unique, name: Crucible.Events.Registry},
        Crucible.Events.Sequence,
        {DynamicSupervisor, name: Crucible.Events.Supervisor, strategy: :one_for_one},
        {Registry, keys: :unique, name: Crucible.Attempt.Registry},
        {DynamicSupervisor, name: Crucible.Attempt.Supervisor, strategy: :one_for_one}
      ]),
      # Roots run in the background (`execution.run_stream`), after the
      # registry each one registers in; shutdown waits up to 30 s for them.
      Supervisor.child_spec({Task.Supervisor, name: Crucible.TaskSupervisor},
        shutdown: 30_000
      ),
      # Stops an archived athanor's running work. The archive announces and
      # this reacts: what is still running is the execution domain's, and
      # the identity domain must not name it.
      Crucible.ArchiveWatch,
      # Periodic sweep that fails running executions whose lease lapsed;
      # started only when `:execution_sweeper_enabled`.
      Crucible.Sweeper,
      # Hears from each configured worker service every poll interval and
      # lapses what a boot it stopped hearing from, or saw replaced, was
      # running; started only when `:worker_watch_enabled`, which follows
      # `:execution_sweeper_enabled`.
      Crucible.WorkerWatch,
      # The host API: where the worker services' runners post their host
      # calls and the services their exit reports (`CYFR_HOST_API_BIND`,
      # `CYFR_HOST_API_PORT`). After the attempt tree it serves, so a
      # shutdown stops taking calls before the attempts they reach go.
      {Crucible.HostListener,
       bind: Cyfr.RuntimeConfig.host_api_bind(), port: Cyfr.RuntimeConfig.host_api_port()},
      # subscriptions/listen stream slots — duplicate keys, one entry per open
      # stream, keyed by {athanor_id, user_id}. An entry dies with its conn
      # process, so a vanished client frees its slot without bookkeeping.
      {Registry, keys: :duplicate, name: Emissary.MCP.SubscriptionRegistry},
      # Use :rest_for_one for the external-server registry, the MCP bridge
      # controller, servers and reconciler. A failure restarts its
      # dependents. The controller starts before the servers and stops after
      # them, because a stopping stdio server releases its owner through it.
      group(Emissary.External.ServerTree, [
        {Registry, keys: :unique, name: Emissary.External.ServerRegistry},
        Emissary.External.Backends,
        {DynamicSupervisor, name: Emissary.External.ServerSupervisor, strategy: :one_for_one},
        Emissary.External.Reconciler
      ]),
      {Task.Supervisor, name: Emissary.TaskSupervisor},
      # Builds (`Compendium.Builds`): a started build, the process watching
      # it, each request to the Locus builds service and the registration
      # after it. After the catalog, the bus and the bookkeeping they write
      # through, so a shutdown ends the builds before them; a build it ends
      # publishes nothing.
      {Task.Supervisor, name: Compendium.Builds.TaskSupervisor},
      Grimoire.RunningTasks,
      # Filling an athanor's component estate: the background fills the
      # first-need hook and a sign-in ask for, and the registry pulls each
      # attempt runs under its own deadline.
      {Task.Supervisor, name: Compendium.ProvisioningSupervisor},
      # The estate filler itself — it reacts to the identity domain's
      # announcement that an athanor needs filling.
      Compendium.Provisioning,
      # The registry and the agent index follow the seeded roots' changes:
      # it reconciles the estate a change names, and recovers every estate
      # a root is behind in once started and on every tick this member
      # holds its slot. Every read passes its own barrier, so nothing
      # waits on this child to be right.
      Compendium.ProjectionReconciler,
      # Prism dashboard
      Prism.TinctureRegistry,
      group(Aqua.WorkerTree, [
        Aqua.Loop.Worker,
        {Task.Supervisor, name: Aqua.TaskSupervisor}
      ]),
      # Thread runners: one process per thread with open
      # turns, started on demand; the recovery task starts one for every
      # thread holding an open turn when the server last stopped. The
      # registry names each runner by its thread and each loop by the root
      # turn it holds (`Aqua.Loop.holder/1`). Registry and the supervisor
      # whose children register in it restart together; a runner's loop
      # dies with the runner.
      group(Aqua.RunnerTree, [
        {Registry, keys: :unique, name: Aqua.RunnerRegistry},
        {DynamicSupervisor, name: Aqua.RunnerSupervisor, strategy: :one_for_one},
        maybe_thread_recovery()
      ])
    ]
  end

  # Last in the infra tier, and optional: offers new seed media to the
  # estates that exist. Its failure is logged and never stops the boot; the
  # sandboxed test boot omits it with the gate's runtime switch.
  defp seed_offer do
    if boot_work_enabled?(),
      do: [Supervisor.child_spec(Cyfr.SeedOffer, restart: :temporary)],
      else: []
  end

  @doc false
  # Pure decision seam: the gate is omitted only when the build was
  # compiled with the test permission (`config/test.exs` alone sets it)
  # AND the runtime switch turns boot work off. Either alone keeps it.
  @spec bootstrap_skipped?(boolean(), boolean()) :: boolean()
  def bootstrap_skipped?(skip_permitted?, boot_work_enabled?),
    do: skip_permitted? == true and boot_work_enabled? == false

  defp boot_work_enabled?, do: Application.get_env(:cyfr, :provisioning_boot_enabled, true)

  # The execution slots: one `Prima.Slots` instance, keyed by athanor, on
  # the caps the operator configured (`CYFR_CRUCIBLE_MAX_CONCURRENT`,
  # `CYFR_CRUCIBLE_MAX_CONCURRENT_PER_TENANT`), else the shipped ones.
  # The ratio warning is said once here, at boot, where an operator can
  # act on it.
  defp execution_slots do
    {max, key_max} = execution_slot_caps()

    case execution_slot_footprint(max, key_max) do
      :ok -> :ok
      {:warn, message} -> Logger.warning(message)
    end

    {Prima.Slots, name: Crucible.Slots, max: max, key_max: key_max}
  end

  @doc false
  # The caps the execution slots boot with: the total, and the roots one
  # athanor may hold.
  @spec execution_slot_caps() :: {pos_integer(), pos_integer()}
  def execution_slot_caps do
    {Application.get_env(:cyfr, :crucible_max_concurrent, Prima.Slots.default_max()),
     Application.get_env(
       :cyfr,
       :crucible_max_concurrent_per_tenant,
       Prima.Slots.default_key_max()
     )}
  end

  @doc false
  # Pure decision seam (testable without booting). One athanor's roots each
  # carry a chain down to the authority depth cap, and children are exempt
  # from the per-athanor cap by design (a chain that cannot get a child
  # slot waits while holding its root slot, which is a deadlock, not a
  # limit), so the cap bounds an athanor's roots and not its footprint.
  # Capping children is not the fix; the lever is the ratio.
  @spec execution_slot_footprint(pos_integer(), pos_integer()) :: :ok | {:warn, String.t()}
  def execution_slot_footprint(max, key_max) do
    footprint = Prima.Slots.max_key_footprint(key_max)

    if footprint >= max do
      {:warn,
       "[Crucible.Slots] one athanor can hold every slot on this node: " <>
         "#{key_max} roots x depth #{Prima.Authority.depth_cap()} = #{footprint} >= " <>
         "#{max} slots. Children are exempt from the per-athanor cap by design (a chain " <>
         "must be able to finish), so the cap bounds roots, not footprint. Lower " <>
         "CYFR_CRUCIBLE_MAX_CONCURRENT_PER_TENANT or raise " <>
         "CYFR_CRUCIBLE_MAX_CONCURRENT to keep one athanor off the whole pool."}
    else
      :ok
    end
  end

  # Off in the test env: suites drive runners directly.
  defp maybe_thread_recovery do
    if Application.get_env(:cyfr, :thread_recovery, true) do
      [
        Supervisor.child_spec(
          {Task, &Aqua.Runner.recover_all/0},
          id: Aqua.RunnerRecovery,
          restart: :temporary
        )
      ]
    else
      []
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

  # One-shot checks that read the repo at boot, outside any test's
  # sandbox; the suite turns them off and exercises `Arca.SchemaFingerprint`
  # and `Cyfr.KeyringFingerprint` directly.
  defp database_checks do
    if Application.get_env(:cyfr, :database_checks_enabled, true),
      do: [Arca.SchemaFingerprint.Check, Cyfr.KeyringFingerprint.Check],
      else: []
  end

  # The claimant is a permanent GenServer with a DB lease; the test
  # suite's sandbox cannot lend it a connection, so the suite turns it off
  # and exercises `Arca.ControlPlane`'s writes and `Cyfr.Cell` directly.
  defp cell_claim do
    if Application.get_env(:arca, :control_plane_claim_enabled, true),
      do: [Cyfr.Cell],
      else: []
  end

  # Discovery, when a topology is configured. `config/runtime.exs` writes
  # one only under `CYFR_CLUSTER=1`, and `Cyfr.Cell` refuses that flag
  # without one, so this is empty on every single-member deployment.
  defp cluster_supervisor do
    case Application.get_env(:libcluster, :topologies, []) do
      [] -> []
      topologies -> [{Cluster.Supervisor, [topologies, [name: Cyfr.ClusterSupervisor]]}]
    end
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
         not is_nil(Cyfr.RuntimeConfig.auth_provider()) do
      Logger.warning(
        "[Cyfr] CYFR_PUBLIC_URL is not set. OAuth redirect URIs and webhook URLs " <>
          "will be built from CYFR_HOST/CYFR_PORT as http://…, which a TLS " <>
          "deployment's provider will reject. Set it to this server's external " <>
          "origin, scheme included (e.g. https://cyfr.example.com)."
      )
    end

    :ok
  end

  defp warn_if_origin_allowlists_diverge do
    decision =
      origin_allowlist_divergence(
        Cyfr.RuntimeConfig.cors_allowed_origins(),
        Application.get_env(:cyfr, :mcp_allowed_origins),
        Application.get_env(:cyfr, :mcp_extra_origins, [])
      )

    case decision do
      :ok -> :ok
      {:warn, message} -> Logger.warning(message)
    end

    :ok
  end

  @doc false
  # Pure decision seam (testable without booting). Two knobs answer "which
  # origins may talk to this server": CORS (browser cross-origin, default
  # "*", guarded above) and MCP Origin (DNS-rebinding guard, default
  # localhost-only). An operator who opens one but not the other gets a
  # half-closed deployment that fails confusingly at request time — say so
  # at boot instead.
  #
  # The warning names cross-origin callers CORS admits and the MCP Origin
  # check then refuses, so it reads what the CORS allowlist admits, not
  # whether its key was set. An empty allowlist admits no cross-origin
  # caller at all, and it is what the shipped stack assigns (`cyfr init`,
  # whose cyfr serves Prism, the API, /mcp and the tinctures from one
  # origin), so a boot of that stack has no divergence and nothing to act
  # on. The wildcard is the other non-case: it is the default, and
  # `cors_enforcement/3` above owns it.
  #
  # The MCP side stays a presence check rather than a second default, which
  # keeps `Cyfr.RuntimeConfig.mcp_allowed_origins/0` the only place the
  # localhost default is spelled.
  @spec origin_allowlist_divergence(term(), term(), term()) :: :ok | {:warn, String.t()}
  def origin_allowlist_divergence(cors_origins, mcp_allowed, mcp_extra) do
    cors = List.wrap(cors_origins)
    cors_admits_origins? = cors != [] and "*" not in cors
    mcp_customized? = mcp_allowed != nil or List.wrap(mcp_extra) != []

    if cors_admits_origins? and not mcp_customized? do
      {:warn,
       "[Cyfr] CYFR_CORS_ALLOWED_ORIGINS is set but CYFR_MCP_ALLOWED_ORIGINS is not — " <>
         "browser MCP requests from #{inspect(cors)} will pass CORS and then be " <>
         "refused by the MCP Origin check (localhost-only default). Set " <>
         "CYFR_MCP_ALLOWED_ORIGINS to match."}
    else
      :ok
    end
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
       "CYFR_AUTH_PROVIDER=oidc is selected but :sanctum, :oidc_issuer is absent or blank. " <>
         "Set CYFR_OIDC_ISSUER to your identity provider's issuer URL."}

  # Resolve and pin :sanctum, :crypto_keyring — the key the identity
  # domain seals rows with, resolved here from the deployment's own
  # environment. Nil or empty configuration derives a key labelled
  # "default" from :secret_key_base; explicit JSON is parsed.
  # KeyringFingerprint checks the result against the database before writes.
  defp resolve_crypto_keyring! do
    case Application.get_env(:sanctum, :crypto_keyring) do
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

        Application.put_env(:sanctum, :crypto_keyring, keyring)
    end
  end

  defp derive_keyring_from_secret_key_base! do
    case Application.get_env(:sanctum, :secret_key_base) do
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
