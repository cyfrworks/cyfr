# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus do
  @moduledoc """
  The one place a message crosses the PubSub server (`Cyfr.PubSub`): every
  topic named once, the struct each one carries, who puts it there, who
  hears it, and the checks every publish and subscribe passes.

  `topics/0` is the roster. Each topic has a scope and exactly one payload
  struct under `Cyfr.Bus.*`, whose closed `kinds/0` union says what
  happened; a publisher builds it with the struct's constructor and a
  subscriber matches it. Payloads carry plain values and never a schema,
  a context or a credential.

  ## Scopes

    * `:tenant` — prefixed `tenant:<athanor_id>:` (`prefix/1`), built from
      an actor. `broadcast/3` publishes only when the topic's prefix, the
      actor's athanor and the payload's athanor agree and the payload is
      the struct declared for the topic; otherwise it answers
      `{:error, :cross_tenant}` and emits `[:cyfr, :bus, :publish_refused]`.
      `subscribe/2` refuses a topic outside the actor's own prefix.
    * `:global` — deliberately unscoped, each with the reason `global/0`
      gives. Only those topics pass `broadcast_global/2`,
      `subscribe_global/1` and `unsubscribe_global/1`.
    * `:page` — one page instance talking to the views nested beside it,
      broadcast on this node alone (`broadcast_page/2`).

  ## Who publishes

  Broadcast follows commit: the layer that owns a fact publishes it from
  the committed change. The foundations below the host emit `:telemetry`
  and never touch this module; the host's bridge (`Cyfr.TelemetryBridge`)
  is the one place an event becomes a message. Execution deltas are the
  documented exception: buffered and broadcast before the write-behind
  sink persists them, numbered for replay.
  """

  alias Prima.Actor

  alias Cyfr.Bus.{
    ApiKeys,
    AthanorArchived,
    BoundedDispatcher,
    Build,
    CallerInvalidated,
    Components,
    Execution,
    ExecutionEvent,
    McpServers,
    Membership,
    Notify,
    Ping,
    PolicyDecision,
    Progress,
    Request,
    RoomInView,
    ScheduleCompleted,
    ScheduleRun,
    Schedules,
    Session,
    ThreadEvent,
    Tinctures,
    VaultEntryChanged,
    Viewing,
    Webhooks
  }

  @pubsub Cyfr.PubSub
  @tenant "tenant:"

  # The roster. `match` is how a topic string is recognised (its whole
  # base, or a base followed by a subject id); `template` is how it reads.
  @topics [
    # --- tenant: the console's dashboards ---
    %{
      key: :executions,
      scope: :tenant,
      struct: Execution,
      match: {:exact, "bus:executions"},
      template: "tenant:<athanor_id>:bus:executions",
      producers: ["Cyfr.TelemetryBridge"],
      consumers: ["PrismWeb.ExecutionsLive", "PrismWeb.SchedulesLive", "PrismWeb.TopbarLive"],
      reason: "an execution's lifecycle, for the athanor's own dashboards"
    },
    %{
      key: :requests,
      scope: :tenant,
      struct: Request,
      match: {:exact, "bus:requests"},
      template: "tenant:<athanor_id>:bus:requests",
      producers: ["Cyfr.TelemetryBridge"],
      consumers: ["PrismWeb.ActivitiesLive", "PrismWeb.SettingsLive", "PrismWeb.TopbarLive"],
      reason: "the athanor's MCP request log grew"
    },
    %{
      key: :components,
      scope: :tenant,
      struct: Components,
      match: {:exact, "bus:components"},
      template: "tenant:<athanor_id>:bus:components",
      producers: ["Cyfr.TelemetryBridge", "Compendium.Providers.Component"],
      consumers: [
        "PrismWeb.ComponentsLive",
        "PrismWeb.ComponentDetailLive",
        "PrismWeb.RegistryLive",
        "PrismWeb.SchedulesLive"
      ],
      reason: "the athanor's component registry changed after the change committed"
    },
    %{
      key: :builds,
      scope: :tenant,
      struct: Build,
      match: {:exact, "bus:builds"},
      template: "tenant:<athanor_id>:bus:builds",
      producers: ["Cyfr.TelemetryBridge"],
      consumers: ["PrismWeb.TopbarLive"],
      reason: "every build of the athanor, for the in-flight indicator"
    },
    %{
      key: :schedule_runs,
      scope: :tenant,
      struct: ScheduleRun,
      match: {:exact, "bus:schedule_runs"},
      template: "tenant:<athanor_id>:bus:schedule_runs",
      producers: ["Cyfr.TelemetryBridge"],
      consumers: ["PrismWeb.ActivitiesLive", "PrismWeb.TopbarLive"],
      reason: "a schedule of the athanor fired or failed"
    },
    %{
      key: :tinctures,
      scope: :tenant,
      struct: Tinctures,
      match: {:exact, "bus:tinctures"},
      template: "tenant:<athanor_id>:bus:tinctures",
      producers: ["Cyfr.TelemetryBridge", "Compendium.ProjectionReconciler"],
      consumers: ["PrismWeb.ActivitiesLive", "PrismWeb.TopbarLive", "Prism.TinctureRegistry"],
      reason: "a tincture of the athanor was invoked, or its tinctures changed"
    },
    %{
      key: :enforcement,
      scope: :tenant,
      struct: PolicyDecision,
      match: {:exact, "bus:enforcement"},
      template: "tenant:<athanor_id>:bus:enforcement",
      producers: ["Cyfr.TelemetryBridge"],
      consumers: ["PrismWeb.EnforcementsLive"],
      reason: "the athanor's enforcement log recorded a decision"
    },
    %{
      key: :webhooks,
      scope: :tenant,
      struct: Webhooks,
      match: {:exact, "bus:webhooks"},
      template: "tenant:<athanor_id>:bus:webhooks",
      producers: ["Cyfr.TelemetryBridge"],
      consumers: ["PrismWeb.WebhooksLive"],
      reason: "the athanor's webhook rows changed"
    },
    %{
      key: :api_keys,
      scope: :tenant,
      struct: ApiKeys,
      match: {:exact, "bus:api_keys"},
      template: "tenant:<athanor_id>:bus:api_keys",
      producers: ["Cyfr.TelemetryBridge"],
      consumers: ["PrismWeb.ApiKeysLive"],
      reason: "the athanor's API key rows changed"
    },
    %{
      key: :mcp_servers,
      scope: :tenant,
      struct: McpServers,
      match: {:exact, "bus:mcp_servers"},
      template: "tenant:<athanor_id>:bus:mcp_servers",
      producers: ["Emissary.External.Provider", "Emissary.External.Server"],
      consumers: ["PrismWeb.McpServersLive", "Emissary.MCP.Subscriptions"],
      reason: "the athanor's external MCP servers or their tool lists changed"
    },
    %{
      key: :schedules,
      scope: :tenant,
      struct: Schedules,
      match: {:exact, "bus:schedules"},
      template: "tenant:<athanor_id>:bus:schedules",
      producers: ["Crucible.Schedules.Scheduler"],
      consumers: ["PrismWeb.SchedulesLive"],
      reason: "a schedule's occurrence started or its run ended"
    },
    %{
      key: :vault_changed,
      scope: :tenant,
      struct: VaultEntryChanged,
      match: {:exact, "bus:vault_changed"},
      template: "tenant:<athanor_id>:bus:vault_changed",
      producers: ["Cyfr.TelemetryBridge"],
      consumers: ["PrismWeb.VaultLive"],
      reason: "a vault entry of the athanor changed; no material travels"
    },
    %{
      key: :notify,
      scope: :tenant,
      struct: Notify,
      match: {:exact, "notify"},
      template: "tenant:<athanor_id>:notify",
      producers: ["Cyfr.TelemetryBridge"],
      consumers: [
        "PrismWeb.TopbarLive",
        "PrismWeb.ChatLive",
        "PrismWeb.ShellLive",
        "PrismWeb.MembersLive",
        "PrismWeb.AquaLive",
        "PrismWeb.ThreadPaneLive",
        "Aqua.Runner"
      ],
      reason: "the athanor's tray fan-in: what its members see happened"
    },
    # --- tenant: one subject at a time ---
    %{
      key: :progress,
      scope: :tenant,
      struct: Progress,
      match: {:prefix, "progress:"},
      template: "tenant:<athanor_id>:progress:<build|register|pull|request>:<id>",
      dispatcher: BoundedDispatcher,
      producers: ["Compendium.Builds.Provider", "Compendium.Providers.Component"],
      consumers: ["PrismWeb.BuildsLive", "PrismWeb.ComponentsLive", "EmissaryWeb.MCPController"],
      reason:
        "one build's, registration's or pull's progress, on its own topic and on the " <>
          "topic of the MCP request it runs for; bounded per subscriber"
    },
    %{
      key: :execution_events,
      scope: :tenant,
      struct: ExecutionEvent,
      match: {:prefix, "execution:events:"},
      template: "tenant:<athanor_id>:execution:events:<execution_id>",
      producers: ["Crucible.Events"],
      consumers: ["EmissaryWeb.ExecutionEventsController", "Aqua.Loop.Stream"],
      reason:
        "one execution's stream: durable rows after commit, deltas before the " <>
          "write-behind sink keeps them, numbered for replay"
    },
    %{
      key: :thread,
      scope: :tenant,
      struct: ThreadEvent,
      match: {:prefix, "thread:"},
      template: "tenant:<athanor_id>:thread:<thread_id>",
      producers: ["Aqua.Tape"],
      consumers: ["Aqua.Runner", "PrismWeb.ThreadPaneLive", "PrismWeb.ChatLive"],
      reason: "one thread's committed rows and its runner's live state"
    },
    # --- global: unscoped on purpose ---
    %{
      key: :vault_changed_global,
      scope: :global,
      struct: VaultEntryChanged,
      match: {:exact, "sanctum:vault_changed"},
      template: "sanctum:vault_changed",
      producers: ["Cyfr.TelemetryBridge"],
      consumers: ["Emissary.External.Reconciler"],
      reason:
        "server-wide credential reconciliation: one reconciler restarts any external " <>
          "server whose headers named the entry, whichever athanor owns it"
    },
    %{
      key: :athanor_archived_global,
      scope: :global,
      struct: AthanorArchived,
      match: {:exact, "sanctum:athanor_archived"},
      template: "sanctum:athanor_archived",
      producers: ["Cyfr.TelemetryBridge"],
      consumers: [
        "Crucible.ArchiveWatch",
        "Emissary.External.Reconciler",
        "CyfrWeb.ContextGuard"
      ],
      reason: "stops the processes serving an archived athanor from outside any tenant topic"
    },
    %{
      key: :caller_invalidated_global,
      scope: :global,
      struct: CallerInvalidated,
      match: {:exact, "sanctum:caller_invalidated"},
      template: "sanctum:caller_invalidated",
      producers: ["Cyfr.TelemetryBridge"],
      consumers: ["Cyfr.StandingWatch", "CyfrWeb.ContextGuard"],
      reason: "drops a cached authorization decision on every member"
    },
    %{
      key: :sessions,
      scope: :global,
      struct: Session,
      match: {:exact, "sanctum:sessions"},
      template: "sanctum:sessions",
      producers: ["Cyfr.TelemetryBridge"],
      consumers: ["CyfrWeb.ContextGuard"],
      reason: "an internal auth signal keyed by person; a revocation reaches every socket"
    },
    %{
      key: :memberships,
      scope: :global,
      struct: Membership,
      match: {:prefix, "sanctum:memberships:"},
      template: "sanctum:memberships:<user_id>",
      producers: ["Cyfr.TelemetryBridge"],
      consumers: ["CyfrWeb.ContextGuard", "PrismWeb.TopbarLive", "PrismWeb.ChatLive"],
      reason: "the subject is the person, not an athanor: which estates they may now reach"
    },
    %{
      key: :platform_notify,
      scope: :global,
      struct: Notify,
      match: {:exact, "platform:notify"},
      template: "platform:notify",
      producers: ["Cyfr.TelemetryBridge"],
      consumers: ["PrismWeb.SettingsLive", "PrismWeb.TopbarLive"],
      reason: "the audience is the operator, outside any athanor"
    },
    %{
      key: :health_check,
      scope: :global,
      struct: Ping,
      match: {:prefix, "health_check:"},
      template: "health_check:<nonce>",
      producers: ["EmissaryWeb.HealthController"],
      consumers: ["EmissaryWeb.HealthController"],
      reason: "a prober's round trip to itself; no tenant data crosses it"
    },
    %{
      key: :schedule_completions,
      scope: :global,
      struct: ScheduleCompleted,
      match: {:exact, "cyfr:schedule_completions"},
      template: "cyfr:schedule_completions",
      producers: ["Crucible.Schedules.Scheduler"],
      consumers: ["Aqua.ScheduleNotes"],
      reason:
        "a committed completion heard on every member; only the issuing member's " <>
          "subscriber acts, so a peer's delivery writes nothing twice"
    },
    # --- page: one page instance and the views beside it ---
    %{
      key: :page_viewing,
      scope: :page,
      struct: Viewing,
      match: {:prefix, "page:viewing:"},
      template: "page:viewing:<page_pid>",
      producers: ["PrismWeb.TopbarLive"],
      consumers: ["PrismWeb.TopbarLive"],
      reason: "a page tells the bar over it which estate it has in view"
    },
    %{
      key: :room_feed,
      scope: :page,
      struct: RoomInView,
      match: {:prefix, "page:room_feed:"},
      template: "page:room_feed:<socket_id>",
      producers: ["PrismWeb.RoomFeed"],
      consumers: ["PrismWeb.AquaPanelLive", "PrismWeb.ThreadPaneLive"],
      reason: "a page tells the assistant beside it which room it has open"
    }
  ]

  @typedoc "A topic's scope."
  @type scope :: :tenant | :global | :page

  @typedoc "A row of the roster."
  @type row :: %{
          required(:key) => atom(),
          required(:scope) => scope(),
          required(:struct) => module(),
          required(:template) => String.t(),
          required(:producers) => [String.t()],
          required(:consumers) => [String.t()],
          required(:reason) => String.t(),
          optional(atom()) => term()
        }

  @typedoc "A subject whose progress rides `progress/2`."
  @type subject :: {:build | :register | :pull | :request, String.t()}

  # ---------------------------------------------------------------------------
  # The roster
  # ---------------------------------------------------------------------------

  @doc """
  Every topic: its key (the function that names it), scope, payload
  struct, the modules that publish and hear it, and why it is scoped as
  it is. The one roster; the tests read the tree against it.
  """
  @spec topics() :: [row()]
  def topics, do: Enum.map(@topics, &Map.delete(&1, :match))

  @doc """
  The unscoped topics and why each one is unscoped, for anyone auditing
  tenancy. Every tenant topic is `tenant:`-prefixed; page topics never
  leave the node.
  """
  @spec global() :: [{String.t(), String.t()}]
  def global, do: for(%{scope: :global} = row <- @topics, do: {row.template, row.reason})

  @doc """
  The tenant prefix of `actor`'s athanor: `tenant:<athanor_id>:`. An actor
  with a nil or empty athanor is a bug and raises; there is no default
  tenant to route to.
  """
  @spec prefix(Actor.t()) :: String.t()
  def prefix(%Actor{athanor_id: athanor_id}) when is_binary(athanor_id) and athanor_id != "",
    do: @tenant <> athanor_id <> ":"

  def prefix(%Actor{athanor_id: athanor_id}) do
    raise ArgumentError,
          "a tenant topic requires an actor with a non-empty athanor_id, " <>
            "got #{inspect(athanor_id)}"
  end

  def prefix(other) do
    raise ArgumentError, "a tenant topic requires a Prima.Actor, got #{inspect(other, limit: 3)}"
  end

  # ---------------------------------------------------------------------------
  # Tenant topics
  # ---------------------------------------------------------------------------

  @doc "Execution lifecycle (`Cyfr.Bus.Execution`)."
  @spec executions(Actor.t()) :: String.t()
  def executions(actor), do: prefix(actor) <> "bus:executions"

  @doc "The MCP request log (`Cyfr.Bus.Request`)."
  @spec requests(Actor.t()) :: String.t()
  def requests(actor), do: prefix(actor) <> "bus:requests"

  @doc "The component registry (`Cyfr.Bus.Components`)."
  @spec components(Actor.t()) :: String.t()
  def components(actor), do: prefix(actor) <> "bus:components"

  @doc "Every build of the athanor (`Cyfr.Bus.Build`)."
  @spec builds(Actor.t()) :: String.t()
  def builds(actor), do: prefix(actor) <> "bus:builds"

  @doc "Schedule firings and failures (`Cyfr.Bus.ScheduleRun`)."
  @spec schedule_runs(Actor.t()) :: String.t()
  def schedule_runs(actor), do: prefix(actor) <> "bus:schedule_runs"

  @doc "Tincture invocations and changes (`Cyfr.Bus.Tinctures`)."
  @spec tinctures(Actor.t()) :: String.t()
  def tinctures(actor), do: prefix(actor) <> "bus:tinctures"

  @doc "The enforcement log (`Cyfr.Bus.PolicyDecision`)."
  @spec enforcement(Actor.t()) :: String.t()
  def enforcement(actor), do: prefix(actor) <> "bus:enforcement"

  @doc "Webhook rows (`Cyfr.Bus.Webhooks`)."
  @spec webhooks(Actor.t()) :: String.t()
  def webhooks(actor), do: prefix(actor) <> "bus:webhooks"

  @doc "API key rows (`Cyfr.Bus.ApiKeys`)."
  @spec api_keys(Actor.t()) :: String.t()
  def api_keys(actor), do: prefix(actor) <> "bus:api_keys"

  @doc "External MCP servers (`Cyfr.Bus.McpServers`)."
  @spec mcp_servers(Actor.t()) :: String.t()
  def mcp_servers(actor), do: prefix(actor) <> "bus:mcp_servers"

  @doc "Schedule occurrences (`Cyfr.Bus.Schedules`)."
  @spec schedules(Actor.t()) :: String.t()
  def schedules(actor), do: prefix(actor) <> "bus:schedules"

  @doc """
  The athanor's vault entries (`Cyfr.Bus.VaultEntryChanged`). The
  server-wide counterpart is `vault_changed_global/0`.
  """
  @spec vault_changed(Actor.t()) :: String.t()
  def vault_changed(actor), do: prefix(actor) <> "bus:vault_changed"

  @doc "The athanor's tray fan-in (`Cyfr.Bus.Notify`)."
  @spec notify(Actor.t()) :: String.t()
  def notify(actor), do: prefix(actor) <> "notify"

  @doc """
  One subject's progress (`Cyfr.Bus.Progress`): a build, a registration,
  a pull, or every progress step of one MCP request (`{:request, id}`).
  """
  @spec progress(Actor.t(), subject()) :: String.t()
  def progress(actor, {kind, id})
      when kind in [:build, :register, :pull, :request] and is_binary(id) and id != "",
      do: prefix(actor) <> "progress:#{kind}:" <> id

  @doc "One execution's event stream (`Cyfr.Bus.ExecutionEvent`)."
  @spec execution_events(Actor.t(), String.t()) :: String.t()
  def execution_events(actor, execution_id) when is_binary(execution_id),
    do: prefix(actor) <> "execution:events:" <> execution_id

  @doc "One thread's live events (`Cyfr.Bus.ThreadEvent`)."
  @spec thread(Actor.t(), String.t()) :: String.t()
  def thread(actor, thread_id) when is_binary(thread_id),
    do: prefix(actor) <> "thread:" <> thread_id

  # ---------------------------------------------------------------------------
  # Global topics
  # ---------------------------------------------------------------------------

  @doc "A vault entry changed anywhere on this server (`Cyfr.Bus.VaultEntryChanged`)."
  @spec vault_changed_global() :: String.t()
  def vault_changed_global, do: "sanctum:vault_changed"

  @doc "An athanor was archived (`Cyfr.Bus.AthanorArchived`)."
  @spec athanor_archived_global() :: String.t()
  def athanor_archived_global, do: "sanctum:athanor_archived"

  @doc "An established-caller memo is no longer good (`Cyfr.Bus.CallerInvalidated`)."
  @spec caller_invalidated_global() :: String.t()
  def caller_invalidated_global, do: "sanctum:caller_invalidated"

  @doc "Session lifecycle (`Cyfr.Bus.Session`)."
  @spec sessions() :: String.t()
  def sessions, do: "sanctum:sessions"

  @doc "One person's seats (`Cyfr.Bus.Membership`)."
  @spec memberships(String.t()) :: String.t()
  def memberships(user_id) when is_binary(user_id) and user_id != "",
    do: "sanctum:memberships:" <> user_id

  @doc "Server-level events for platform admins (`Cyfr.Bus.Notify`, `athanor_id: :platform`)."
  @spec platform_notify() :: String.t()
  def platform_notify, do: "platform:notify"

  @doc "A health probe's round trip (`Cyfr.Bus.Ping`)."
  @spec health_check(term()) :: String.t()
  def health_check(nonce), do: "health_check:#{nonce}"

  @doc "A committed schedule completion (`Cyfr.Bus.ScheduleCompleted`)."
  @spec schedule_completions() :: String.t()
  def schedule_completions, do: "cyfr:schedule_completions"

  # ---------------------------------------------------------------------------
  # Page topics
  # ---------------------------------------------------------------------------

  @doc """
  What the page `host` has in view (`Cyfr.Bus.Viewing`). A bar rendered
  with no page over it listens on a topic nobody publishes to.
  """
  @spec page_viewing(pid() | nil) :: String.t()
  def page_viewing(host) when is_pid(host),
    do: "page:viewing:" <> List.to_string(:erlang.pid_to_list(host))

  def page_viewing(nil), do: "page:viewing:none"

  @doc "The room the page `socket_id` has open (`Cyfr.Bus.RoomInView`)."
  @spec room_feed(String.t()) :: String.t()
  def room_feed(socket_id) when is_binary(socket_id) and socket_id != "",
    do: "page:room_feed:" <> socket_id

  # ---------------------------------------------------------------------------
  # Publishing and subscribing
  # ---------------------------------------------------------------------------

  @doc """
  Publish `payload` on the tenant topic `topic` for `actor`.

  The topic must lie under the actor's prefix, the payload must be the
  struct the roster declares for it, and its `athanor_id` must be the
  actor's. Anything else answers `{:error, :cross_tenant}`, publishes
  nothing and emits `[:cyfr, :bus, :publish_refused]`.
  """
  @spec broadcast(Actor.t(), String.t(), struct()) :: :ok | {:error, term()}
  def broadcast(%Actor{} = actor, topic, %module{} = payload) when is_binary(topic) do
    with {:ok, athanor_id} <- tenant_of(actor),
         {:ok, row} <- tenant_row(topic, athanor_id),
         true <- row.struct == module,
         true <- Map.get(payload, :athanor_id) == athanor_id do
      publish(row, topic, payload)
    else
      _ -> refuse(actor, topic, module)
    end
  end

  @doc """
  Publish a progress step on its subject's topic and, when it names the
  request it runs for, on that request's topic too — where the transport
  streaming the request's response hears it. Each publish passes
  `broadcast/3`'s checks; the first refusal is the answer.
  """
  @spec broadcast_progress(Actor.t(), Progress.t()) :: :ok | {:error, term()}
  def broadcast_progress(%Actor{} = actor, %Progress{subject: subject} = step) do
    topics =
      case step.request_id do
        request_id when is_binary(request_id) and request_id != "" ->
          [progress(actor, subject), progress(actor, {:request, request_id})]

        _none ->
          [progress(actor, subject)]
      end

    Enum.reduce(topics, :ok, fn topic, acc ->
      case broadcast(actor, topic, step) do
        :ok -> acc
        error -> if acc == :ok, do: error, else: acc
      end
    end)
  end

  @doc "Publish `payload` on the global topic `topic`. Any other topic or struct raises."
  @spec broadcast_global(String.t(), struct()) :: :ok | {:error, term()}
  def broadcast_global(topic, %_{} = payload) when is_binary(topic) do
    row = scoped_row!(:global, topic, payload)
    publish(row, topic, payload)
  end

  @doc "Publish `payload` on the page topic `topic`, on this node only."
  @spec broadcast_page(String.t(), struct()) :: :ok
  def broadcast_page(topic, %_{} = payload) when is_binary(topic) do
    _row = scoped_row!(:page, topic, payload)
    Phoenix.PubSub.local_broadcast(@pubsub, topic, payload)
  end

  @doc """
  Subscribe the calling process to the tenant topic `topic`, which must
  lie under `actor`'s prefix: `{:error, :cross_tenant}` otherwise.
  """
  @spec subscribe(Actor.t(), String.t()) :: :ok | {:error, term()}
  def subscribe(%Actor{} = actor, topic) when is_binary(topic) do
    with {:ok, _row} <- own_topic(actor, topic), do: Phoenix.PubSub.subscribe(@pubsub, topic)
  end

  @doc "Unsubscribe the calling process from `actor`'s tenant topic `topic`."
  @spec unsubscribe(Actor.t(), String.t()) :: :ok | {:error, term()}
  def unsubscribe(%Actor{} = actor, topic) when is_binary(topic) do
    with {:ok, _row} <- own_topic(actor, topic), do: Phoenix.PubSub.unsubscribe(@pubsub, topic)
  end

  @doc "Subscribe the calling process to a global topic. Any other topic raises."
  @spec subscribe_global(String.t()) :: :ok | {:error, term()}
  def subscribe_global(topic) when is_binary(topic) do
    _row = scoped_row!(:global, topic)
    Phoenix.PubSub.subscribe(@pubsub, topic)
  end

  @doc "Unsubscribe the calling process from a global topic."
  @spec unsubscribe_global(String.t()) :: :ok
  def unsubscribe_global(topic) when is_binary(topic) do
    _row = scoped_row!(:global, topic)
    Phoenix.PubSub.unsubscribe(@pubsub, topic)
  end

  @doc "Subscribe the calling process to a page topic. Any other topic raises."
  @spec subscribe_page(String.t()) :: :ok | {:error, term()}
  def subscribe_page(topic) when is_binary(topic) do
    _row = scoped_row!(:page, topic)
    Phoenix.PubSub.subscribe(@pubsub, topic)
  end

  @doc "Unsubscribe the calling process from a page topic."
  @spec unsubscribe_page(String.t()) :: :ok
  def unsubscribe_page(topic) when is_binary(topic) do
    _row = scoped_row!(:page, topic)
    Phoenix.PubSub.unsubscribe(@pubsub, topic)
  end

  @doc """
  Subscribe the calling process to every announcement that can end a
  held context's standing: sessions, caller invalidation and archives,
  and — for a person — their memberships. Each holder filters for its
  own caller.
  """
  @spec subscribe_standing(String.t() | nil) :: :ok
  def subscribe_standing(user_id) do
    Enum.each(standing_topics(user_id), &Phoenix.PubSub.subscribe(@pubsub, &1))
  end

  @doc "Undo `subscribe_standing/1` for the same person."
  @spec unsubscribe_standing(String.t() | nil) :: :ok
  def unsubscribe_standing(user_id) do
    Enum.each(standing_topics(user_id), &Phoenix.PubSub.unsubscribe(@pubsub, &1))
  end

  defp standing_topics(user_id) do
    person = if is_binary(user_id) and user_id != "", do: [memberships(user_id)], else: []
    [sessions(), caller_invalidated_global(), athanor_archived_global()] ++ person
  end

  # ---------------------------------------------------------------------------
  # Classification
  # ---------------------------------------------------------------------------

  defp tenant_of(%Actor{athanor_id: athanor_id}) when is_binary(athanor_id) and athanor_id != "",
    do: {:ok, athanor_id}

  defp tenant_of(_actor), do: :error

  defp own_topic(actor, topic) do
    with {:ok, athanor_id} <- tenant_of(actor),
         {:ok, row} <- tenant_row(topic, athanor_id) do
      {:ok, row}
    else
      _ -> {:error, :cross_tenant}
    end
  end

  # The tenant row `topic` names under `athanor_id`'s own prefix.
  defp tenant_row(topic, athanor_id) do
    own = @tenant <> athanor_id <> ":"

    if String.starts_with?(topic, own),
      do:
        find_row(:tenant, binary_part(topic, byte_size(own), byte_size(topic) - byte_size(own))),
      else: :error
  end

  defp scoped_row!(scope, topic, payload \\ nil) do
    case find_row(scope, topic) do
      {:ok, row} when is_nil(payload) ->
        row

      {:ok, %{struct: module} = row} when is_struct(payload, module) ->
        row

      {:ok, row} ->
        raise ArgumentError,
              "#{inspect(topic)} carries #{inspect(row.struct)}, not #{inspect(payload.__struct__)}"

      :error ->
        raise ArgumentError, "#{inspect(topic)} is not a #{scope} topic of Cyfr.Bus"
    end
  end

  defp find_row(scope, topic) do
    Enum.find_value(@topics, :error, fn
      %{scope: ^scope, match: {:exact, ^topic}} = row ->
        {:ok, row}

      %{scope: ^scope, match: {:prefix, base}} = row ->
        if String.starts_with?(topic, base) and byte_size(topic) > byte_size(base),
          do: {:ok, row}

      _row ->
        nil
    end)
  end

  defp publish(%{dispatcher: dispatcher}, topic, payload),
    do: Phoenix.PubSub.broadcast(@pubsub, topic, payload, dispatcher)

  defp publish(_row, topic, payload), do: Phoenix.PubSub.broadcast(@pubsub, topic, payload)

  # A publish whose tenant or payload disagrees is a bug somewhere above
  # this module, and possibly a leak: it is refused and counted, and the
  # count names the payload's type and the actor's athanor, never the
  # payload.
  defp refuse(actor, topic, module) do
    :telemetry.execute([:cyfr, :bus, :publish_refused], %{count: 1}, %{
      athanor_id: Map.get(actor, :athanor_id),
      payload: module,
      topic_key: topic_key(topic)
    })

    {:error, :cross_tenant}
  end

  defp topic_key(@tenant <> rest) do
    case String.split(rest, ":", parts: 2) do
      [_athanor, base] ->
        case find_row(:tenant, base) do
          {:ok, row} -> row.key
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp topic_key(topic) do
    Enum.find_value([:global, :page], fn scope ->
      case find_row(scope, topic) do
        {:ok, row} -> row.key
        :error -> nil
      end
    end)
  end
end
