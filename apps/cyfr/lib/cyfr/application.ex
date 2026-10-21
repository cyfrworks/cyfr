# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Application do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      Arca,
      Sanctum,
      Cyfr,
      Compendium,
      Aqua,
      Opus,
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

    # The four ports' one write each, before every domain this
    # application starts: each declaring module reads its implementation
    # from the term written here, and an uninstalled port raises where it
    # is asked rather than answering as though nothing were there. The
    # storage and counted caps, asked on the first tenant byte; the
    # component facts a consent rests on; the proxied `server:tool` tools
    # the table resolves on a miss and a grant names; and the overlaid
    # roots' unit locators, asserted against the layout here before
    # Bootstrap or the tincture registry scans the union.
    Prima.Caps.install!(Sanctum.Tenancy.Caps)
    Sanctum.Consent.Components.install!(Compendium.ConsentFacts)
    Sanctum.Proxy.install!(Emissary.External.Proxy)

    Arca.Storage.UnitLocator.install!(%{
      "aqua" => Compendium.AquaPath,
      "components" => Compendium.ComponentPath
    })

    # The validator every component passes before it is stored as
    # runnable: checked here, so a member that cannot validate does not
    # start.
    :ok = Prima.ComponentFeatures.install!()

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
    # configured providers and written once into the gate's term — after
    # the ports its audit and its providers read, before any process that
    # dispatches, derives a consent shape or serves `tools/list` exists.
    # A provider that cannot load, or a declaration the gates cannot
    # classify, refuses the boot here.
    Sanctum.Catalog.load!()

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
    Opus.Keys.mint()

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

    # OpenTelemetry instrumentation for Phoenix and Bandit, once the SDK is
    # known to export through the configured exporter.
    if Application.get_env(:cyfr, :opentelemetry_enabled, false) do
      ensure_configured_traces_exporter!()
      OpentelemetryBandit.setup()
      OpentelemetryPhoenix.setup(adapter: :bandit)
    end

    # A deployment with authentication configured names the cross-origin
    # callers it admits: no wildcard CORS allowlist.
    enforce_cors_not_wildcard_with_auth()

    # OIDC issuer reserved-host check — only when OIDC is the configured
    # auth provider. A misconfigured generic-OIDC issuer would otherwise
    # only surface as a 500 at the user's login callback.
    validate_oidc_issuer_config!()

    # A webhook's body cap above a host call's body would read more than
    # an unauthenticated caller may send; refused here, not clamped.
    validate_webhook_max_body_bytes!()

    # Warn (don't block) if auth is configured but no platform admin is
    # declared — no user could access the system until one is seeded.
    warn_if_no_platform_admin()

    # Attach OTEL tenant handler if OpenTelemetry is enabled
    if Application.get_env(:cyfr, :opentelemetry_enabled, false) do
      Cyfr.OtelTenantHandler.attach()
    end

    # Webhook verify-failed → log at :warning. Operators can disable by
    # detaching `"cyfr-webhook-verify-failed-log"` if they prefer an
    # alternative sink (e.g. forwarding to SIEM via a Telemetry Metrics
    # consumer).
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
    # still has its pool open for every claim they release. Every
    # long-running child states its stop bound (`shutdown:`) in the spec
    # that declares it; a supervisor waits for its own children and keeps
    # `:infinity`.
    children = Enum.map(layout(), &tier/1)

    opts = [strategy: :rest_for_one, name: Cyfr.Supervisor, max_restarts: 10, max_seconds: 60]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      # A listener is known by what it runs, so the tree's are read once
      # the tree has started them, the HostAPI's once `Opus.Supervisor`
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
  Stop `endpoint` accepting: each socket server it serves on, its loopback
  listener and, in a tailnet or public home, its proxy listener
  (`endpoint_servers/1`), is suspended (`suspend_server/1`). With none,
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
            "(#{Prima.LogFilter.inspect_reason(reason)}); it drains while it still accepts"
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
  The socket servers `endpoint` serves on: every socket server in its
  supervision tree, found as the listener census finds one
  (`listeners/1`), so the loopback listener Phoenix runs as the endpoint's
  own child and the proxy listener under its supervisor
  (`CyfrWeb.Ingress`) are both found. Empty when it serves no listener, as
  under `server: false`, or is not running.
  """
  @spec endpoint_servers(Supervisor.supervisor()) :: [pid()]
  def endpoint_servers(endpoint), do: socket_servers(endpoint)

  defp socket_servers(supervisor) do
    {servers, others} = supervisor |> children() |> Enum.split_with(&socket_server?/1)

    for({_id, pid, _type, _modules} <- servers, is_pid(pid), do: pid) ++
      for {_id, pid, :supervisor, _modules} <- others,
          is_pid(pid),
          server <- socket_servers(pid),
          do: server
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

  @doc """
  Refuse the boot when a span processor of the SDK's effective
  configuration (`app_env`, the `:opentelemetry` application environment,
  merged with the operating-system environment as the SDK merges it)
  exports through anything but the `traces_exporter` the runtime
  configuration names. That exporter is the credential scrub wrapping
  OTLP's, and the SDK lets `OTEL_TRACES_EXPORTER` replace it: a replaced
  exporter sends every span as recorded, request paths and all.
  """
  @spec ensure_configured_traces_exporter!(keyword()) :: :ok
  def ensure_configured_traces_exporter!(app_env \\ Application.get_all_env(:opentelemetry)) do
    configured = Keyword.get(app_env, :traces_exporter)

    case :otel_configuration.merge_with_os(app_env) do
      %{sdk_disabled: true} ->
        :ok

      %{processors: processors} ->
        stray =
          for {processor, opts} <- processors,
              not (is_map(opts) and Map.get(opts, :exporter) == configured),
              do: processor

        # The refusal names modules alone: an exporter's options can carry
        # the collector's headers, which a crash report must not print.
        if stray != [] do
          raise "OpenTelemetry is enabled but span processors #{inspect(stray)} do not " <>
                  "export through the configured traces exporter " <>
                  "#{inspect(exporter_module(configured))} " <>
                  "(is OTEL_TRACES_EXPORTER set?); refusing to boot"
        end

        :ok
    end
  end

  defp exporter_module({module, _opts}) when is_atom(module), do: module
  defp exporter_module(module) when is_atom(module), do: module
  defp exporter_module(_other), do: :unknown

  # The socket servers a listener runs: a Bandit server, or a bare
  # ThousandIsland one.
  @socket_servers [Bandit, ThousandIsland]

  @doc """
  The listeners running under `supervisor`: each supervisor in its tree
  that runs a socket server as a direct child, named by its own child id
  (`Opus.HostListener`; `CyfrWeb.Endpoint`, whose own child is the
  loopback listener; `CyfrWeb.Ingress.Proxy`, the proxy listener's), or by
  `supervisor` itself for a socket server started directly under it. A
  server's own subtree is not read, and a child that is gone by the time
  it is asked is skipped: it listens on nothing.
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
    Sanctum.Gate.Supervisor,
    Compendium.Supervisor,
    Opus.Supervisor,
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
  # starts before the endpoint and so stops after it: the listeners have
  # closed before the tree stops (`prep_stop/1`), and a delivery already in
  # flight is ended after the endpoint. The endpoint's listeners, the
  # loopback listener and in a tailnet or public home the proxy listener
  # (`CyfrWeb.Ingress`), drain their open connections for the
  # `thousand_island_options` `shutdown_timeout` in `config/config.exs`.
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
  #
  # A declared restore's transition runs right before it, under this
  # member's slot (`declared_restore/0`), so the reconcile and every child
  # after it read the store the transition left. Between the two, the
  # storage reserve derives its latch (`Cyfr.StorageReserve`), so a home
  # below the reserve's mark, or one restarted while depleted, admits
  # nothing but reads and authority-reducing changes from its first
  # request; the transition and the reconcile take authority away and
  # write rows, which the latch never refuses. A reserve directory the
  # boot cannot use stops its start, and the boot. The sandboxed test boot
  # omits all three.
  defp gate do
    if bootstrap_skipped?(@bootstrap_skip_permitted, boot_work_enabled?()),
      do: [],
      else: [
        %{
          id: :declared_restore,
          start: {__MODULE__, :declared_restore, []},
          restart: :transient,
          type: :worker
        },
        # 5 s: its stop, which holds no work in flight.
        Supervisor.child_spec(Cyfr.StorageReserve, shutdown: 5_000),
        Supervisor.child_spec(Cyfr.Bootstrap, restart: :transient)
      ]
  end

  @doc """
  The declared restore's step before the gate (`ARCHITECTURE.md` §6.9):
  when `cyfr restore` left the marker `restore_pending`, its transition
  (`Arca.SecurityTransitions.restore/1`) runs in one transaction under
  this member's slot, and only its commit lets the gate start. Answers
  `:ignore` once it committed or when there was no marker, so the
  supervisor starts the gate next and keeps nothing running for it; a
  restart of the cell's claimant or of anything before it runs it again,
  finding no marker. A member that should hold a slot and does not, a
  lost slot, a postcondition that did not hold, a store that cannot
  answer or a raise answer `{:error, {:restore_refused, class}}`, so the
  supervisor's start fails and the application does not boot: the marker
  stays for the next boot, and nothing admits work over a half-restored
  store.
  """
  @spec declared_restore() :: :ignore | {:error, {:restore_refused, atom()}}
  def declared_restore do
    with {:ok, slot} <- restore_slot(),
         {:ok, change} <- Arca.SecurityTransitions.restore(slot: slot) do
      restored(change)
    else
      {:error, reason} -> restore_refused(reason)
    end
  rescue
    e -> restore_refused({:exception, e})
  catch
    kind, _reason -> restore_refused({:exception, kind})
  end

  # The slot this member holds (`Arca.ControlPlane.member_slot/0`): a
  # deployment where no member claims one has nothing to fence, and runs
  # the transition under none; one that should hold a slot and does not
  # runs nothing.
  defp restore_slot do
    case Arca.ControlPlane.member_slot() do
      {:ok, slot} -> {:ok, slot}
      {:error, :not_owner} -> {:error, :slot_not_held}
    end
  end

  defp restored(:none), do: :ignore

  defp restored(%{restore_id: restore_id} = change) do
    Logger.warning(
      "[Cyfr.Application] declared restore #{restore_id} applied: " <>
        "#{length(change.user_ids)} people must recover; " <>
        "#{length(change.revoked_session_hashes)} sessions retired, " <>
        "#{length(change.suspended_api_key_ids)} keys, " <>
        "#{length(change.suspended_webhook_ids)} webhooks, " <>
        "#{length(change.suspended_paired_client_ids)} devices and " <>
        "#{length(change.suspended_passkey_ids)} passkeys suspended, " <>
        "#{length(change.failed_execution_ids)} runs and " <>
        "#{length(change.uncertain_turn_ids)} turns ended uncertain"
    )

    :ignore
  end

  defp restore_refused({class, %{__exception__: true, __struct__: module}}) do
    Logger.error(
      "[Cyfr.Application] declared restore refused: #{class} (#{inspect(module)}); " <>
        "this member admits no work"
    )

    {:error, {:restore_refused, class}}
  end

  defp restore_refused({:exception, kind}) when is_atom(kind),
    do: restore_refused(:exception)

  defp restore_refused(reason) when is_atom(reason) do
    Logger.error(
      "[Cyfr.Application] declared restore refused: #{reason}; this member admits no work"
    )

    {:error, {:restore_refused, reason}}
  end

  defp restore_refused(_reason), do: restore_refused(:exception)

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
      Sanctum.Gate.Supervisor,
      Compendium.Supervisor,
      # The slots' caps and the host API's bind and port
      # (`CYFR_HOST_API_BIND`, `CYFR_HOST_API_PORT`) are read here and
      # handed down: a domain's subtree reads no configuration. The
      # listener's drain is the time an open host call has to finish once
      # it stops accepting.
      {Opus.Supervisor,
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
      Supervisor.child_spec({Task.Supervisor, name: Opus.Schedules.TaskSupervisor},
        shutdown: 30_000
      ),
      # 10 s: its terminate cancelling the timers of every schedule it
      # holds, before a fire can reach a stopping tree.
      Supervisor.child_spec(Opus.Schedules.Scheduler, shutdown: 10_000),
      # The console's: the tincture registry, and the task supervisor its
      # pages start their asynchronous work on. 5 s: the registry's stop,
      # which holds no work in flight; 30 s: the longest page task it lets
      # finish.
      Supervisor.child_spec(Prism.TinctureRegistry, shutdown: 5_000),
      Supervisor.child_spec({Task.Supervisor, name: Prism.TaskSupervisor}, shutdown: 30_000)
    ]
  end

  # Last in the infra tier, and optional: offers new seed media to the
  # athanors that exist. Its start returns before the offer runs, so the
  # web tier does not wait for it; its failure is logged and never stops
  # the boot, and as a temporary child it restarts nothing. The sandboxed
  # test boot omits it with the gate's runtime switch.
  defp seed_offer do
    if boot_work_enabled?(), do: [seed_offer_spec()], else: []
  end

  @doc false
  # The seed offer's child spec, read by the shutdown census, which the
  # suite's boot (boot work off) does not start.
  def seed_offer_spec do
    Supervisor.child_spec({Cyfr.SeedOffer, sync: &Compendium.sync_seeds/0}, restart: :temporary)
  end

  @doc false
  # Pure decision seam: the gate is omitted only when the build was
  # compiled with the test permission (`config/test.exs` alone sets it)
  # AND the runtime switch turns boot work off. Either alone keeps it.
  @spec bootstrap_skipped?(boolean(), boolean()) :: boolean()
  def bootstrap_skipped?(skip_permitted?, boot_work_enabled?),
    do: skip_permitted? == true and boot_work_enabled? == false

  defp boot_work_enabled?, do: Application.get_env(:cyfr, :provisioning_boot_enabled, true)

  # The execution slots (`Opus.Slots`) boot on the caps the operator
  # configured (`CYFR_OPUS_MAX_CONCURRENT`,
  # `CYFR_OPUS_MAX_CONCURRENT_PER_TENANT`), else the shipped ones. The
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
    {Application.get_env(:cyfr, :opus_max_concurrent, Prima.Slots.default_max()),
     Application.get_env(
       :cyfr,
       :opus_max_concurrent_per_tenant,
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
       "[Opus.Slots] one athanor can hold every slot on this node: " <>
         "#{key_max} roots x depth #{Prima.Authority.depth_cap()} = #{footprint} >= " <>
         "#{max} slots. Children are exempt from the per-athanor cap by design (a chain " <>
         "must be able to finish), so the cap bounds roots, not footprint. Lower " <>
         "CYFR_OPUS_MAX_CONCURRENT_PER_TENANT or raise " <>
         "CYFR_OPUS_MAX_CONCURRENT to keep one athanor off the whole pool."}
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
    if Arca.ControlPlane.claimed?(),
      do: [Supervisor.child_spec(Cyfr.Cell, shutdown: 5_000)],
      else: []
  end

  # Discovery, when a topology is configured. `config/runtime.exs` writes
  # one only under `CYFR_CLUSTER=on`, and `Cyfr.Cell` refuses that flag
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

  # Once authentication is configured the CORS allowlist must be an explicit
  # one, never the wildcard. Fail closed at boot in a real release (gated on
  # RELEASE_ROOT, so dev/test are never blocked); warn loudly otherwise. A
  # no-auth deployment may configure the wildcard.
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
  end

  @doc false
  # Pure decision seam (testable without booting). A deployment that has
  # authentication configured must name its CORS origins in an explicit
  # allowlist, never the wildcard. Fail closed at boot in a real release (gated
  # on RELEASE_ROOT, so dev/test are never blocked); warn loudly otherwise.
  @spec cors_enforcement(boolean(), term(), boolean()) ::
          :ok | {:raise, String.t()} | {:warn, String.t()}
  def cors_enforcement(auth_configured?, origins, real_release?) do
    if auth_configured? and "*" in List.wrap(origins) do
      message =
        "[Cyfr] FATAL: CORS wildcard \"*\" is configured in a deployment with " <>
          "authentication enabled, which admits only the origins it names. Set " <>
          "CYFR_CORS_ALLOWED_ORIGINS (comma-separated origins) — or :cyfr, " <>
          ":cors_allowed_origins in config — to an explicit origin allowlist."

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
  Refuse the boot when a declared stream (`Sanctum.Catalog.stream_entries/0`,
  or `entries`) names a topic `Cyfr.Bus` does not roster, one no grant can
  scope, or a refresh no module exports (`stream_topic_findings/1`).
  """
  @spec check_stream_topics!([{module(), Prima.Provider.Stream.t()}]) :: :ok
  def check_stream_topics!(entries \\ Sanctum.Catalog.stream_entries()) do
    case stream_topic_findings(entries) do
      [] ->
        :ok

      findings ->
        raise "declared streams name topics the bus cannot carry or refreshes that do not " <>
                "exist; refusing to boot:\n" <> Enum.map_join(findings, "\n", &("  - " <> &1))
    end
  end

  @doc """
  One sentence per declared stream whose topic is not on the `Cyfr.Bus`
  roster (`Cyfr.Bus.topic?/1`), is on it but cannot carry the stream's
  grant (`Cyfr.Bus.grantable?/2`), or whose `refresh` is not a function
  of arity 2 its module exports, naming the provider, the stream and the
  topic. A filtering stream's subject selects payloads on one topic, so
  its grant is checked as one that takes no subject. Empty when every
  stream rides a topic a grant can scope and refreshes through a function
  that exists, so a missing refresh refuses the boot rather than a
  delivery.
  """
  @spec stream_topic_findings([{module(), Prima.Provider.Stream.t()}]) :: [String.t()]
  def stream_topic_findings(entries) when is_list(entries) do
    for {provider, %Prima.Provider.Stream{} = stream} <- entries,
        finding = stream_topic_finding(stream),
        do: "#{inspect(provider)} declares #{stream.name} on #{inspect(stream.topic)}: #{finding}"
  end

  defp stream_topic_finding(stream) do
    topic_subject? = not is_nil(stream.subject) and is_nil(stream.filter)

    cond do
      not Cyfr.Bus.topic?(stream.topic) ->
        "the bus declares no such topic"

      not Cyfr.Bus.grantable?(stream.topic, topic_subject?) ->
        "the topic is not a tenant topic of the stream's subject shape"

      not refresh_exported?(stream.refresh) ->
        "its refresh is not a function of arity 2 its module exports"

      true ->
        nil
    end
  end

  defp refresh_exported?(nil), do: true

  defp refresh_exported?({module, function}) when is_atom(module) and is_atom(function),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, 2)

  defp refresh_exported?(_refresh), do: false

  defp validate_webhook_max_body_bytes! do
    case Cyfr.RuntimeConfig.webhook_max_body_bytes() do
      {:ok, _bytes} -> :ok
      {:error, message} -> raise "[Cyfr] FATAL: #{message}"
    end
  end

  # OIDC issuer reserved-host check. A generic-OIDC issuer pointed at a
  # reserved direct-provider host (github.com, accounts.google.com) would
  # produce cross-deployment colliding user ids and silently break login.
  # Surface it at boot so a deploy fails loudly instead of every login.
  defp validate_oidc_issuer_config! do
    if Cyfr.RuntimeConfig.auth_provider() == Sanctum.Auth.OIDC do
      case check_oidc_issuer(Sanctum.Auth.OIDC.issuer()) do
        :ok -> :ok
        {:error, message} -> raise "[Cyfr] FATAL: #{message}"
      end
    end
  end

  # The boot's half of the assertion `Sanctum.Auth.OIDC`'s issuer
  # resolution makes at sign-in.
  defp check_oidc_issuer(issuer) when is_binary(issuer) and issuer != "" do
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

  defp check_oidc_issuer(_),
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
        # runtime.exs reads CYFR_CRYPTO_KEYRING from the .env file and the
        # process environment alike into :crypto_keyring_json, blank as
        # unset.
        keyring =
          case Application.get_env(:cyfr, :crypto_keyring_json) do
            nil -> derive_keyring_from_secret_key_base!()
            json -> parse_keyring_env!(json)
          end

        Application.put_env(:sanctum, :crypto_keyring, keyring)
    end
  end

  defp derive_keyring_from_secret_key_base! do
    keyring = derive_keyring!(Application.get_env(:sanctum, :secret_key_base))

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

    keyring
  end

  @doc false
  # Public for the same reason `cors_enforcement/3` is. The key base is
  # held to the rule `config/runtime.exs` holds CYFR_SECRET_KEY_BASE to
  # (`Cyfr.RuntimeConfig.check_secret_key_base/1`), so a refusal here
  # never sends the operator to a value the boot then refuses.
  @spec derive_keyring!(term()) :: %{primary: String.t(), keys: map()}
  def derive_keyring!(key_base) do
    case Cyfr.RuntimeConfig.check_secret_key_base(key_base) do
      :ok ->
        master = :crypto.hash(:sha256, "cyfr-cipher-keyring|" <> key_base)
        %{primary: "default", keys: %{"default" => master}}

      {:error, message} ->
        raise """
        [Cyfr] FATAL: cannot derive :crypto_keyring: #{message}. Or provide
        CYFR_CRYPTO_KEYRING as JSON
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
