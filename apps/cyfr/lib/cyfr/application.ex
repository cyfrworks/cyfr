# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Application do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      Arca,
      Sanctum,
      Grimoire,
      Cyfr,
      Compendium,
      Aqua,
      Crucible,
      Emissary,
      Prism,
      PrismWeb,
      CyfrWeb,
      CyfrWeb.Endpoint
    ],
    exports: [],
    check: [aliases: true]

  require Logger

  use Application

  # config:compile-runtime-ok — the permission is compiled in on purpose: a
  # release is built without it, so no runtime setting can omit the gate.
  @bootstrap_skip_permitted Application.compile_env(:cyfr, :bootstrap_skip_permitted, false)

  @impl true
  def start(_type, _args) do
    # A stop in this VM may have marked the LiveView socket draining; a
    # start serves `/live` again.
    :ok = CyfrWeb.LiveSocket.undrain()

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

    # The platform settings, before the tree and so before the execution
    # slots' pool or any other consumer reads one, whether or not this
    # boot migrated: the roster's defaults installed into Arca's accessor,
    # this member's environment pins checked against the live members'
    # recorded ones (a disagreement refuses the boot naming both), and
    # each restart-scoped row and the log level's applied once. An
    # unreadable settings table refuses the boot.
    Cyfr.Platform.Settings.install!()
    Cyfr.Platform.Settings.check_pins!()
    Cyfr.Platform.Settings.apply()

    # The operation table and its resource index, built from the
    # configured providers and written once into Grimoire's term — after
    # the ports its audit and its providers read, before any process that
    # dispatches, derives a consent shape or serves `tools/list` exists.
    # A provider that cannot load, or a declaration the gates cannot
    # classify, refuses the boot here.
    Grimoire.Catalog.load!()

    # Every stream the table holds rides a topic the bus declares, one a
    # grant can scope: checked before any process that could open one
    # exists, and a stream naming anything else refuses the boot naming
    # its provider, the stream and the topic.
    check_stream_topics!()

    # Every socket the endpoint mounts is a path an intent enters by, so
    # each is on the admission roster (`Cyfr.Admission`) before the
    # endpoint starts: one that is not refuses the boot, naming it. The
    # host reads the roster; no listener asks it.
    check_endpoint_sockets!()

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

    warn_if_one_athanor_fills_the_slots()

    # Two tiers under a :rest_for_one root so each has its own restart budget:
    # a crash-looping endpoint exhausts only the web tier (infra keeps running,
    # then the root restarts just the web tier), while an infra collapse
    # restarts infra AND the web tier so endpoints rebind to fresh
    # PubSub and registries instead of holding dead references. The repo is
    # the `arca` application's and restarts under its own supervisor;
    # everything here reaches it by name. Shutdown is reverse start order:
    # endpoints drain before infra goes down, and every child that holds a
    # claim has stopped before this tree returns, so the `arca`
    # application, which this one depends on and which stops after it,
    # still has its pool open for every claim they release.
    children = Enum.map(layout(), &tier/1)

    opts = [strategy: :rest_for_one, name: Cyfr.Supervisor, max_restarts: 10, max_seconds: 60]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      # A listener is known by what it runs, so the tree's are read once
      # the tree has started them, the HostAPI's once `Crucible.Supervisor`
      # has: each is on the admission roster, or the tree is stopped and
      # the boot refused, naming it.
      refuse_unrostered_listeners!(pid)
      {:ok, pid}
    end
  end

  # How long a graceful stop waits for the endpoint to stop accepting
  # before it goes on without it: a suspension is a few supervisor calls,
  # and a server that cannot answer them in this long never holds the stop.
  @suspend_deadline_ms 5_000

  @impl true
  def prep_stop(state) do
    # A graceful stop refuses before it drains. Here, before the tree
    # stops, the LiveView socket starts refusing every connect, and then
    # the endpoint's listening ports close: a new connection is refused at
    # once, and every connection already open stays. The tree then stops:
    # the LiveView socket's drainer tells the tabs it holds to reconnect,
    # and each meets the closed port, or on a connection already open the
    # socket's refusal, and rejoins another member or the restarted
    # server, never this one, while the requests in flight finish within
    # the endpoint's drain (`shutdown_timeout`, `config/config.exs`). This
    # also runs when the tree has already died, where the endpoint serves
    # nothing and there is nothing to close.
    :ok = CyfrWeb.LiveSocket.drain()
    _ = suspend_endpoint(CyfrWeb.Endpoint)
    state
  end

  @doc """
  Stop `endpoint` accepting: each socket server it serves on
  (`endpoint_servers/1`) is suspended (`suspend_server/1`). With none,
  there is nothing to do and the answer is `:ok`.

  It never raises and never outlasts `deadline_ms`: the lookup and the
  suspensions run in a process of their own, and one that fails, crashes
  or is still running at the deadline, which kills it, is logged and
  answered `:error`.
  """
  @spec suspend_endpoint(module(), timeout()) :: :ok | :error
  def suspend_endpoint(endpoint, deadline_ms \\ @suspend_deadline_ms) do
    # Monitored and never linked: `prep_stop/1` runs in the application
    # master, which traps exits, so a link would leave an exit message in
    # its mailbox. The outcome is the process's exit reason, and the
    # monitor is flushed on the deadline, so nothing is left behind.
    {pid, ref} =
      spawn_monitor(fn ->
        suspended = Enum.map(endpoint_servers(endpoint), &suspend_server/1)
        if Enum.all?(suspended, &(&1 == :ok)), do: :ok, else: exit({:shutdown, :not_suspended})
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} ->
        :ok

      # `suspend_server/1` has logged each server it could not suspend.
      {:DOWN, ^ref, :process, ^pid, {:shutdown, :not_suspended}} ->
        :error

      {:DOWN, ^ref, :process, ^pid, reason} ->
        Logger.warning(
          "[Cyfr] graceful stop: #{inspect(endpoint)} could not stop accepting " <>
            "(#{inspect(reason)}); it drains while it still accepts"
        )

        :error
    after
      deadline_ms ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])

        Logger.warning(
          "[Cyfr] graceful stop: #{inspect(endpoint)} did not stop accepting within " <>
            "#{deadline_ms} ms; it drains while it still accepts"
        )

        :error
    end
  end

  @doc """
  The socket servers `endpoint` serves on, one for each scheme it listens
  on (`Bandit.PhoenixAdapter.bandit_pid/2`). Empty when it serves no
  listener, as under `server: false`, or is not running.
  """
  @spec endpoint_servers(module()) :: [pid()]
  def endpoint_servers(endpoint \\ CyfrWeb.Endpoint) do
    for scheme <- [:http, :https],
        {:ok, pid} when is_pid(pid) <- [Bandit.PhoenixAdapter.bandit_pid(endpoint, scheme)],
        do: pid
  catch
    :exit, _not_running -> []
  end

  @doc """
  Suspend the socket server `server` (`ThousandIsland.suspend/1`): its
  acceptors end and its listening port closes, so a new connection is
  refused at once, while every connection already open stays until the
  server itself stops. A server that cannot be suspended, or is gone, is
  logged and answered `:error`; this never raises.
  """
  @spec suspend_server(Supervisor.supervisor()) :: :ok | :error
  def suspend_server(server) do
    case safely_suspend(server) do
      :ok ->
        :ok

      failure ->
        Logger.warning(
          "[Cyfr] graceful stop: the socket server #{inspect(server)} could not stop " <>
            "accepting (#{inspect(failure)}); it drains while it still accepts"
        )

        :error
    end
  end

  defp safely_suspend(server) do
    ThousandIsland.suspend(server)
  catch
    kind, reason -> {kind, reason}
  end

  @doc """
  Refuse the boot when a socket the endpoint mounts (`sockets`, its
  `__sockets__/0`) is on no admission path (`Cyfr.Admission.socket_findings/1`).
  """
  @spec check_endpoint_sockets!([{String.t(), module(), keyword()}]) :: :ok
  def check_endpoint_sockets!(sockets \\ CyfrWeb.Endpoint.__sockets__()) do
    case Cyfr.Admission.socket_findings(sockets) do
      [] ->
        :ok

      findings ->
        raise "the endpoint mounts sockets the admission roster does not name; " <>
                "refusing to boot:\n" <> Enum.map_join(findings, "\n", &("  - " <> &1))
    end
  end

  @doc """
  Refuse the boot when a listener in `listeners` (`listeners/1` of the
  running tree) is on no admission path (`Cyfr.Admission.listener_findings/1`).
  """
  @spec check_listeners!([term()]) :: :ok
  def check_listeners!(listeners) do
    case Cyfr.Admission.listener_findings(listeners) do
      [] ->
        :ok

      findings ->
        raise "listeners run under the supervision tree that the admission roster " <>
                "does not name; refusing to boot:\n" <>
                Enum.map_join(findings, "\n", &("  - " <> &1))
    end
  end

  # The socket servers a listener runs: a Bandit server, or a bare
  # ThousandIsland one.
  @socket_servers [Bandit, ThousandIsland]

  @doc """
  The listeners running under `supervisor`: each supervisor in its tree
  that runs a socket server as a direct child, named by its own child id
  (`Crucible.HostListener`, `CyfrWeb.Endpoint`), or by `supervisor` itself
  for a socket server started directly under it. A server's own subtree is
  not read, and a child that is gone by the time it is asked is skipped:
  it listens on nothing.
  """
  @spec listeners(Supervisor.supervisor()) :: [term()]
  def listeners(supervisor), do: listeners(supervisor, supervisor)

  defp listeners(supervisor, id) do
    {servers, others} = supervisor |> children() |> Enum.split_with(&socket_server?/1)
    own = if servers == [], do: [], else: [id]

    own ++
      for {child_id, pid, :supervisor, _modules} <- others,
          is_pid(pid),
          listener <- listeners(pid, child_id),
          do: listener
  end

  defp children(supervisor) do
    Supervisor.which_children(supervisor)
  catch
    :exit, _gone -> []
  end

  defp socket_server?({_id, _pid, _type, modules}) when is_list(modules),
    do: Enum.any?(modules, &(&1 in @socket_servers))

  defp socket_server?(_child), do: false

  # Once the tree has started: a listener off the roster stops the tree
  # this start began, then refuses the boot.
  defp refuse_unrostered_listeners!(pid) do
    check_listeners!(listeners(Cyfr.Supervisor))
  rescue
    exception ->
      Supervisor.stop(pid)
      reraise exception, __STACKTRACE__
  end

  @typedoc """
  A supervisor as the census describes it: its id, its strategy, its
  restart intensity (`{max_restarts, max_seconds}`) and its children in
  start order, each a child spec or a supervisor described the same way.
  """
  @type census() ::
          {term(), Supervisor.strategy(), {non_neg_integer(), pos_integer()},
           [census() | Supervisor.child_spec()]}

  # The domains' subtrees: the census reads each one's children through
  # its own `init/1`, the definition its start runs.
  @owners [
    Grimoire.Supervisor,
    Compendium.Supervisor,
    Crucible.Supervisor,
    Aqua.Supervisor,
    Emissary.Supervisor
  ]

  @doc false
  # The two tiers in start order, each with its children in start order,
  # down through every subtree the tree names — the census
  # `Cyfr.StartupAdmissionBarrierTest` reads. It is read from the child
  # specs `start/2` starts, each supervisor's children through the same
  # `init/1` its start runs, so the test and the boot cannot describe
  # different trees.
  @spec tiers() :: [census()]
  def tiers, do: Enum.map(layout(), &(&1 |> tier() |> census()))

  # The tiers as the boot builds them: id, strategy, intensity and
  # children in start order.
  defp layout do
    [
      # Every child after the claim holds something before it: the cell's
      # generation, a subscription in `Cyfr.PubSub`, the gate's verdict. So
      # a restart takes down everything after the child and starts it again
      # in order, and the gate reruns before the first child that admits work.
      {Cyfr.InfraSupervisor, :rest_for_one, {10, 60},
       List.flatten([pre_gate(), gate(), post_gate(), seed_offer()])},
      {Cyfr.WebSupervisor, :one_for_one, {10, 60}, web()}
    ]
  end

  # Emissary's webhook task supervisor (an inbound webhook's delivery)
  # starts before the endpoint and so stops after it: the listener has
  # closed before the tree stops (`prep_stop/1`), and a delivery already in
  # flight is ended after the endpoint. The endpoint drains its open
  # connections for the `thousand_island_options` `shutdown_timeout` in
  # `config/config.exs`.
  defp web do
    [
      # 30 s: the longest webhook delivery it lets finish.
      Supervisor.child_spec({Task.Supervisor, name: Emissary.Web.TaskSupervisor},
        shutdown: 30_000
      ),
      CyfrWeb.Endpoint
    ]
  end

  # Before the gate: only what the security reconcile needs, what must
  # hear its announcements, and the settings every later child reads. None
  # of these runs tenant work, projects a credential, dispatches to a
  # provider, starts a backend or recovers anything; each only answers
  # once something else calls it, but for the settings process's own node
  # facts: this member's pinned values and the store revision it polls.
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
      # 5 s: its stop, which holds no work in flight.
      Supervisor.child_spec(
        {Arca.AuditHandler, events: Cyfr.Telemetry.Catalog.consumed_by(:audit)},
        shutdown: 5_000
      ),
      # The web tier's metrics and poller
      CyfrWeb.Telemetry,
      # The bus's server (`Cyfr.Bus`): nothing else names it.
      {Phoenix.PubSub, name: Cyfr.PubSub},
      # Drops this member's cached authorization decisions when any member
      # says one is no longer good. Right after PubSub, and before
      # anything that establishes a caller. 5 s: its stop, which holds no
      # work in flight.
      Supervisor.child_spec(Cyfr.StandingWatch, shutdown: 5_000),
      # The host's telemetry-to-bus bridge, attached before the reconcile
      # announces a revocation, so the announcement reaches mounted views.
      # 5 s: its stop, which holds no work in flight.
      Supervisor.child_spec(Cyfr.TelemetryBridge, shutdown: 5_000),
      # This member's settings process: after the claim, which recorded
      # the pins it writes to the store, and the bus it hears changes on;
      # before every consumer. It drops a cached setting on each committed
      # change and applies the log level in store-revision order. 5 s: its
      # stop, which holds no work in flight.
      Supervisor.child_spec(Cyfr.Platform.Settings, shutdown: 5_000)
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
      else: [Supervisor.child_spec(Cyfr.Bootstrap, restart: :transient)]
  end

  # After the gate: everything that admits work — fires a schedule,
  # recovers a turn, starts a backend, serves a host call, dispenses a
  # credential or publishes a result.
  defp post_gate do
    [
      # 5 s: its stop, which leaves a cycle's claim to lapse on its lease.
      Supervisor.child_spec(Cyfr.RetentionScheduler, shutdown: 5_000),
      # The SSE stream slots (`CyfrWeb.SSE.claim_slot/3`): one entry per open
      # stream, which dies with its conn process, so a vanished client frees
      # its slot without bookkeeping.
      CyfrWeb.SSE.Registry,
      # The domains' subtrees, in order: the gate's handlers, the
      # component athanor, execution, the assistant, then the MCP surface.
      Grimoire.Supervisor,
      Compendium.Supervisor,
      # The slots' caps and the host API's bind and port
      # (`CYFR_HOST_API_BIND`, `CYFR_HOST_API_PORT`) are read here and
      # handed down: a domain's subtree reads no configuration. The
      # listener's drain is the time an open host call has to finish once
      # it stops accepting.
      {Crucible.Supervisor,
       slot_caps: execution_slot_caps(),
       bind: Cyfr.RuntimeConfig.host_api_bind(),
       port: Cyfr.RuntimeConfig.host_api_port(),
       drain_ms: 5_000},
      # Off in the test env: suites drive runners directly.
      {Aqua.Supervisor, thread_recovery: Application.get_env(:cyfr, :thread_recovery, true)},
      Emissary.Supervisor,
      # Recurring component executions: the runs the scheduler fires are
      # tasks of their own, monitored by it. Last among the domains, so a
      # fire never reaches a tree that is not up, and the first to stop at
      # shutdown. 30 s: the longest run it lets finish.
      Supervisor.child_spec({Task.Supervisor, name: Crucible.Schedules.TaskSupervisor},
        shutdown: 30_000
      ),
      # 10 s: its terminate cancelling the timers of every schedule it
      # holds, before a fire can reach a stopping tree.
      Supervisor.child_spec(Crucible.Schedules.Scheduler, shutdown: 10_000),
      # The console's: the tincture registry, and the task supervisor its
      # pages start their asynchronous work on. 5 s: the registry's stop,
      # which holds no work in flight; 30 s: the longest page task it lets
      # finish.
      Supervisor.child_spec(Prism.TinctureRegistry, shutdown: 5_000),
      Supervisor.child_spec({Task.Supervisor, name: Prism.TaskSupervisor}, shutdown: 30_000)
    ]
  end

  # Last in the infra tier, and optional: offers new seed media to the
  # athanors that exist. Its failure is logged and never stops the boot; the
  # sandboxed test boot omits it with the gate's runtime switch.
  defp seed_offer do
    if boot_work_enabled?(),
      do: [
        Supervisor.child_spec({Cyfr.SeedOffer, sync: &Compendium.sync_seeds/0},
          restart: :temporary
        )
      ],
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

  # The execution slots (`Crucible.Slots`) boot on the caps the operator
  # configured (`CYFR_CRUCIBLE_MAX_CONCURRENT`,
  # `CYFR_CRUCIBLE_MAX_CONCURRENT_PER_TENANT`), else the shipped ones. The
  # ratio warning is said once here, at boot, where an operator can act
  # on it.
  defp warn_if_one_athanor_fills_the_slots do
    {max, key_max} = execution_slot_caps()

    case execution_slot_footprint(max, key_max) do
      :ok -> :ok
      {:warn, message} -> Logger.warning(message)
    end
  end

  @doc false
  # The caps the execution slots boot with: the total, and the roots one
  # athanor may hold. Restart-scoped settings, read once here from the
  # application environment, where the boot wrote a pinned value and
  # `Cyfr.Platform.Settings.apply/0` a stored one, and never through
  # `Arca.PlatformSettings.effective/1`: that answers the stored row,
  # which may be a value saved for the next boot and not the one running.
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

  defp tier({name, strategy, {max_restarts, max_seconds}, children}) do
    %{
      id: name,
      start:
        {Supervisor, :start_link,
         [
           children,
           [
             strategy: strategy,
             name: name,
             max_restarts: max_restarts,
             max_seconds: max_seconds
           ]
         ]},
      type: :supervisor
    }
  end

  # A child as the census describes it: a supervisor the tree builds
  # (a tier or a group, started through `Supervisor.start_link/2`) or a
  # domain's subtree is read through the `init/1` its start runs; any
  # other child is its spec.
  defp census(child) do
    case Supervisor.child_spec(child, []) do
      %{id: id, start: {Supervisor, :start_link, [children, opts]}} ->
        flags = Keyword.take(opts, [:strategy, :max_restarts, :max_seconds])
        described(id, Supervisor.init(children, flags))

      %{id: id, start: {owner, :start_link, [opts]}} when owner in @owners ->
        described(id, owner.init(opts))

      spec ->
        spec
    end
  end

  defp described(id, {:ok, {flags, children}}),
    do: {id, flags.strategy, {flags.intensity, flags.period}, Enum.map(children, &census/1)}

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CyfrWeb.Endpoint.config_change(changed, removed)
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
    # 5 s: its terminate releasing this member's slot row.
    if Application.get_env(:arca, :control_plane_claim_enabled, true),
      do: [Supervisor.child_spec(Cyfr.Cell, shutdown: 5_000)],
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

  @doc """
  Refuse the boot when a declared stream (`Grimoire.Catalog.stream_entries/0`,
  or `entries`) names a topic `Cyfr.Bus` does not roster, or one no grant
  can scope (`stream_topic_findings/1`).
  """
  @spec check_stream_topics!([{module(), Prima.Provider.Stream.t()}]) :: :ok
  def check_stream_topics!(entries \\ Grimoire.Catalog.stream_entries()) do
    case stream_topic_findings(entries) do
      [] ->
        :ok

      findings ->
        raise "declared streams name topics the bus cannot carry; refusing to boot:\n" <>
                Enum.map_join(findings, "\n", &("  - " <> &1))
    end
  end

  @doc """
  One sentence per declared stream whose topic is not on the `Cyfr.Bus`
  roster (`Cyfr.Bus.topic?/1`), or is on it but cannot carry the stream's
  grant (`Cyfr.Bus.grantable?/2`), naming the provider, the stream and the
  topic. Empty when every stream rides a topic a grant can scope.
  """
  @spec stream_topic_findings([{module(), Prima.Provider.Stream.t()}]) :: [String.t()]
  def stream_topic_findings(entries) when is_list(entries) do
    for {provider, %Prima.Provider.Stream{} = stream} <- entries,
        finding = stream_topic_finding(stream),
        do: "#{inspect(provider)} declares #{stream.name} on #{inspect(stream.topic)}: #{finding}"
  end

  defp stream_topic_finding(stream) do
    cond do
      not Cyfr.Bus.topic?(stream.topic) ->
        "the bus declares no such topic"

      not Cyfr.Bus.grantable?(stream.topic, not is_nil(stream.subject)) ->
        "the topic is not a tenant topic of the stream's subject shape"

      true ->
        nil
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
