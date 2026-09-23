# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus do
  @moduledoc """
  Every PubSub topic in the system, named once, with the messages each one
  carries.

  Defines topic names and message shapes for publishers and subscribers.

  Naming them here makes a rename a compile error. `Sanctum.Notify` proves the
  shape: one function for the topic, a `@type` for what rides on it.

  Naming a topic is not broadcasting on it. The foundations below the
  host emit `:telemetry` and never touch PubSub — every topic below whose
  producer is the identity domain is put on the bus by the host's bridge
  (`Prism.TelemetryBridge`), from the event `Sanctum.Telemetry`
  announced. The topic strings stay the domain's, which is why several of
  them delegate downward.

  The `bus:` prefix is an in-VM PubSub address shared by the AQUA domain
  and console, independent of module names.

  ## Athanor-scoped topics

  These carry tenant data and go through `Sanctum.PubSub.topic/2`, which
  prefixes `tenant:<athanor_id>:` and raises when the athanor is missing. The
  athanor arrives either as a `Sanctum.Context` or as a bare id.

  ## Global topics

  Seven topics are deliberately unscoped, and each is listed in `global/0` with
  the reason. They carry no tenant payload, or they are the signal that a
  tenant boundary just moved — `sanctum:vault_changed` exists precisely so a
  reconciler outside any one athanor learns that a credential changed.
  """

  alias Sanctum.Context
  alias Sanctum.PubSub

  @typedoc "The athanor a scoped topic belongs to."
  @type athanor :: Context.t() | String.t()

  @typedoc """
  What the telemetry bridge broadcasts: the raw telemetry pair, re-shaped as a
  tagged tuple so a LiveView can pattern-match it.
  """
  @type telemetry_message :: {atom(), map(), map()}

  # ---------------------------------------------------------------------------
  # Athanor-scoped — the Prism dashboards
  # ---------------------------------------------------------------------------

  @doc """
  Execution lifecycle.

  Messages: `{:execution_started | :execution_completed | :execution_failed,
  metadata, measurements}`.
  """
  @spec executions(athanor()) :: String.t()
  def executions(athanor), do: PubSub.topic("bus:executions", athanor)

  @doc """
  MCP request log.

  Messages: `{:request, metadata, measurements}`.
  """
  @spec requests(athanor()) :: String.t()
  def requests(athanor), do: PubSub.topic("bus:requests", athanor)

  @doc """
  Component install/remove.

  Messages: `{:component_installed | :component_removed, metadata,
  measurements}` from the telemetry bridge, and the bare `:components_changed`
  from `Compendium.MCP.ComponentTool`.
  """
  @spec components(athanor()) :: String.t()
  def components(athanor), do: PubSub.topic("bus:components", athanor)

  @doc """
  Build lifecycle, across all builds of an athanor.

  Messages: `{:build_started | :build_progress | :build_stopped, metadata,
  measurements}`. Note the three-element shape — a single build's own progress
  travels on `build/2` as a two-element tuple.
  """
  @spec builds(athanor()) :: String.t()
  def builds(athanor), do: PubSub.topic("bus:builds", athanor)

  @doc """
  A schedule fired or failed to fire.

  Messages: `{:schedule_fired | :schedule_failed, metadata, measurements}`.
  Distinct from `schedules/1`, which carries changes to the schedule rows.
  """
  @spec schedule_runs(athanor()) :: String.t()
  def schedule_runs(athanor), do: PubSub.topic("bus:schedule_runs", athanor)

  @doc """
  Tincture invocation lifecycle.

  Messages: `{:tincture_invoke_started | :tincture_invoke_stopped, metadata,
  measurements}`.
  """
  @spec tinctures(athanor()) :: String.t()
  def tinctures(athanor), do: PubSub.topic("bus:tinctures", athanor)

  @doc """
  Policy enforcement decisions — the allow/deny audit trail.

  Messages: `{:policy_decision, metadata, measurements}`.
  """
  @spec enforcement(athanor()) :: String.t()
  def enforcement(athanor), do: PubSub.topic("bus:enforcement", athanor)

  @doc """
  Webhook rows changed.

  Messages: `:webhooks_changed`.
  """
  @spec webhooks(athanor()) :: String.t()
  def webhooks(athanor), do: PubSub.topic("bus:webhooks", athanor)

  @doc """
  API key rows changed.

  Messages: `:api_keys_changed`.
  """
  @spec api_keys(athanor()) :: String.t()
  def api_keys(athanor), do: PubSub.topic("bus:api_keys", athanor)

  @doc """
  External MCP server rows changed.

  Messages: `:mcp_servers_changed`.
  """
  @spec mcp_servers(athanor()) :: String.t()
  def mcp_servers(athanor), do: PubSub.topic("bus:mcp_servers", athanor)

  @doc """
  Schedule rows changed — created, edited, paused, removed.

  Messages: `:schedules_updated`. Distinct from `schedule_runs/1`, which
  carries firings.
  """
  @spec schedules(athanor()) :: String.t()
  def schedules(athanor), do: PubSub.topic("bus:schedules", athanor)

  @doc """
  A vault entry in this athanor changed.

  Messages: `{:vault_entry_changed, entry_id, verb}`. The cross-athanor
  counterpart is `vault_changed_global/0`.
  """
  @spec vault_changed(athanor()) :: String.t()
  def vault_changed(athanor), do: PubSub.topic("bus:vault_changed", athanor)

  # ---------------------------------------------------------------------------
  # Athanor-scoped — one subject at a time
  # ---------------------------------------------------------------------------

  @doc """
  One build's compile progress.

  Messages: `{:build_progress, %{phase:, message:, timestamp:}}` — two
  elements, unlike the same atom's three-element form on `builds/1`.
  """
  @spec build(String.t(), athanor()) :: String.t()
  def build(build_id, athanor), do: PubSub.topic("build:#{build_id}", athanor)

  @doc """
  One component registration's progress.

  Messages: `{:register_progress, %{phase:, message:, timestamp:}}`.
  """
  @spec register(String.t(), athanor()) :: String.t()
  def register(register_id, athanor), do: PubSub.topic("register:#{register_id}", athanor)

  @doc """
  One pull or publish's progress.

  Messages: `{:progress, %{phase:, message:, timestamp:}}`.
  """
  @spec progress(String.t(), athanor()) :: String.t()
  def progress(progress_id, athanor), do: PubSub.topic("progress:#{progress_id}", athanor)

  @doc """
  One execution's event stream.

  Messages: `{:execution_event, %{type:, execution_id:, sequence:, durable:,
  delta:, timestamp:, data:, origin:}}` — a durable row (`execution.*`, a
  turn's own rows; `sequence` is its number) or a delta (`emit`;
  `sequence` is `<durable>.<n>`).
  """
  @spec execution_events(String.t(), athanor()) :: String.t()
  def execution_events(execution_id, athanor),
    do: PubSub.topic("execution:events:#{execution_id}", athanor)

  @doc """
  One thread's live events, fanned out by `Aqua.Tape` and `Aqua.Runner`.

  Messages: `{:thread, thread_id, event}` — the event shapes
  are documented on the runner, which owns a turn's vocabulary.
  """
  @spec thread(String.t(), athanor()) :: String.t()
  def thread(thread_id, athanor),
    do: PubSub.topic("thread:#{thread_id}", athanor)

  # ---------------------------------------------------------------------------
  # Global — unscoped on purpose
  # ---------------------------------------------------------------------------

  @doc """
  A vault entry changed anywhere on this server.

  Messages: `{:vault_entry_changed_global, athanor_id, entry_id, verb, meta}`
  — `meta` carries the entry's `name` for every verb (a deleted row can no
  longer be read for it), and `old_name` too on a rename (the name being
  vacated is what a live server's header template still spells).

  Unscoped on purpose: `Emissary.MCP.ExternalServerReconciler` is a single
  server-wide process that must restart any external MCP server whose headers
  referenced the changed credential, whichever athanor owns it. Scoping this
  would mean one subscription per athanor and a revoked credential still in
  flight until the next restart.
  """
  @spec vault_changed_global() :: String.t()
  def vault_changed_global, do: "sanctum:vault_changed"

  @doc """
  An athanor was archived. Messages: `{:athanor_archived_global, athanor_id}`.

  Unscoped on purpose: the processes that serve an athanor from outside any
  tenant topic — the external MCP servers — must stop whichever athanor it
  was.
  """
  @spec athanor_archived_global() :: String.t()
  def athanor_archived_global, do: "sanctum:athanor_archived"

  @doc """
  An established-caller memo is no longer good anywhere in the cell.
  Messages: `{:caller_invalidated, token_hash}`.

  Unscoped on purpose: the subject is a session row key, and the memo it
  addresses is a cached AUTHORIZATION decision held in each member's own
  table. `Cyfr.StandingWatch` on every member drops it. The memo's TTL
  (`:sanctum, :caller_memo_ttl_ms`, 2 s) is what bounds a delivery that
  never arrives; this topic is what makes the usual case immediate.
  """
  @spec caller_invalidated_global() :: String.t()
  def caller_invalidated_global, do: "sanctum:caller_invalidated"

  @doc """
  Session lifecycle. Messages: `{:sessions_revoked, user_id}`,
  `{:session_created, ...}`.

  Unscoped: an internal auth signal, keyed by person rather than athanor, and
  a revocation must reach every athanor's sockets at once.
  """
  @spec sessions() :: String.t()
  defdelegate sessions(), to: Sanctum.Session, as: :topic

  @doc """
  One person's membership set changed. Messages: `{:membership_changed, map}`.

  Unscoped by shape: the subject is the person, not an athanor — the event
  exists to tell a socket which athanors it may now reach.
  """
  @spec memberships(String.t()) :: String.t()
  defdelegate memberships(user_id), to: Sanctum.Tenancy.Members, as: :topic

  @doc """
  The tray fan-in for one athanor. Messages: `{:notify, athanor_id, kind,
  payload}`; see `Sanctum.Notify` for `kind`.

  Tenant-prefixed but built by `Sanctum.Notify`, which owns the message
  vocabulary; named here so the whole topic list is in one place.
  """
  @spec notify(String.t()) :: String.t()
  defdelegate notify(athanor_id), to: Sanctum.Notify, as: :topic

  @doc """
  Server-level events for platform admins. Messages: `{:notify, :platform,
  kind, payload}`.

  Unscoped: its audience is the operator, who is not acting inside an athanor.
  """
  @spec platform_notify() :: String.t()
  defdelegate platform_notify(), to: Sanctum.Notify, as: :platform_topic

  @doc """
  A health probe's own round-trip check. Messages: `:ping`.

  Unscoped: the prober subscribes and publishes to itself to prove PubSub is
  alive; no tenant data crosses it.
  """
  @spec health_check(term()) :: String.t()
  def health_check(nonce), do: "health_check:#{nonce}"

  @doc """
  The unscoped topics and why each one is unscoped, for anyone auditing
  tenancy. Every other topic in this module is `tenant:`-prefixed.
  """
  @spec global() :: [{String.t(), String.t()}]
  def global do
    [
      {"sanctum:vault_changed", "server-wide credential reconciliation"},
      {"sanctum:athanor_archived", "stops the processes serving an archived athanor"},
      {"sanctum:caller_invalidated", "drops a cached authorization decision on every member"},
      {"sanctum:sessions", "internal auth signal, keyed by person"},
      {"sanctum:memberships:<user_id>", "subject is the person, not an athanor"},
      {"platform:notify", "audience is the operator, outside any athanor"},
      {"health_check:<nonce>", "a prober's round-trip to itself"}
    ]
  end
end
