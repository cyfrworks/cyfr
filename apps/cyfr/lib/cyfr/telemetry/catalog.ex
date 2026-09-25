# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Telemetry.Catalog do
  @moduledoc """
  Every `[:cyfr, …]` telemetry event, and who consumes it.

  Classifies every emitted telemetry event and identifies its consumers
  or availability for operator-provided handlers.

  ## Consumers

  - `:audit` — `Arca.AuditHandler` → audit sinks. Its roster **derives**
    from this table (`consumed_by(:audit)`).
  - `:bridge` — `Cyfr.TelemetryBridge` → `Cyfr.Bus`. Its attach is this
    roster (`consumed_by(:bridge)`).
  - `:metrics` — `EmissaryWeb.Telemetry` metric definitions. Pinned equal
    by test.
  - `:log` — a dedicated Logger attach (`Cyfr.Application`).
  - `:estate` — `Compendium.Provisioning`, the component domain's answer
    to the identity domain's "this athanor needs filling". A foundation
    below the host announces and never calls up, and this is the one
    event whose consumer does work rather than fan out.
  - `:projection` — `Compendium.ProjectionReconciler`, which reconciles
    the component registry and the agent index when a seeded root's unit
    changes. Its attach is this roster (`consumed_by(:projection)`), and
    it only hastens work every read's barrier and the periodic recovery
    would do anyway.
  - `:operator` — consciously unconsumed by shipped machinery: kept for an
    operator's own monitoring attach, or pinned by tests. The `note` says
    why it earns its place; no event is orphaned silently.

  ## Emitters

  Every consumer above but `:operator` attaches in the control plane's VM,
  and telemetry does not cross a process boundary, so an event with one of
  them is emitted by the control plane (`apps/cyfr/lib`). An event marked
  `emitter: :worker` is emitted only inside a runner, the OS process that
  runs a guest (`apps/opus/lib`), and is for the operator's own attach
  there alone (`emitted_by/1`). What a runner does that the control plane
  must know, it learns from the runner's host calls and emits itself: a
  credential a runner is handed is audited where CYFR hands it over, and a
  guest refused one is audited when its runner reports the refusal.
  """

  @catalog %{
    # ——— audit plane ———
    [:cyfr, :audit, :recorded] => %{
      consumers: [:operator],
      note:
        "one entry of the audit trail, sanitized, as `Arca.Audit.Event`: where a " <>
          "deployment's own SIEM or object-store trail attaches. Deliberately " <>
          "OUTSIDE the audit roster — recording an entry must not produce another"
    },
    [:cyfr, :audit, :pipeline_failure] => %{
      consumers: [:operator],
      note:
        "the audit plane's own alarm — deliberately OUTSIDE its own pipeline: " <>
          "auditing it would recurse when the trail cannot be written"
    },
    [:cyfr, :opus, :audit_error] => %{
      consumers: [:audit],
      note: "an execution record failed to persist — the run happened, the trail did not"
    },
    [:cyfr, :sanctum, :policy, :audit_failure] => %{
      consumers: [:audit],
      note: "a policy consultation could not be logged"
    },

    # ——— identity, door, tenancy ———
    [:cyfr, :sanctum, :auth] => %{consumers: [:audit]},
    [:cyfr, :sanctum, :door, :refused] => %{consumers: [:audit]},
    [:cyfr, :sanctum, :door, :denied] => %{consumers: [:audit]},
    [:cyfr, :sanctum, :door, :revoke_failed] => %{
      consumers: [:audit],
      note: "a revoked person's sessions could not be retired — must be findable later"
    },
    [:cyfr, :sanctum, :identity, :namespace_divergence] => %{
      consumers: [:audit],
      note: "a provider answered a different namespace than the stored identity"
    },
    [:cyfr, :sanctum, :tenancy, :platform_admin_bootstrap] => %{consumers: [:audit]},
    [:cyfr, :sanctum, :platform_context] => %{consumers: [:audit]},
    [:cyfr, :sanctum, :notify] => %{
      consumers: [:bridge],
      note: "the tray fan-in: what an estate's members, or the operator, see happened"
    },
    [:cyfr, :sanctum, :caller, :invalidated] => %{
      consumers: [:bridge],
      note:
        "an established-caller memo — a cached authorization decision — is no longer " <>
          "good; every member drops the memos it holds for that session row key"
    },
    [:cyfr, :sanctum, :session, :created] => %{
      consumers: [:bridge],
      note: "a session was minted; no token travels, a subscriber adopts its own"
    },
    [:cyfr, :sanctum, :sessions, :revoked] => %{
      consumers: [:bridge],
      note: "every session of a person was retired; their sockets must let go"
    },
    [:cyfr, :sanctum, :membership, :changed] => %{
      consumers: [:bridge],
      note: "which estates a person may now reach"
    },
    [:cyfr, :sanctum, :vault, :entry_changed] => %{
      consumers: [:bridge],
      note:
        "a credential changed: the athanor's own topic and the global one a " <>
          "server-wide reconciler reads"
    },
    [:cyfr, :sanctum, :athanor, :archived] => %{
      consumers: [:bridge],
      note: "what serves an archived athanor from outside any tenant topic must stop"
    },
    [:cyfr, :sanctum, :api_keys, :changed] => %{consumers: [:bridge]},
    [:cyfr, :sanctum, :webhooks, :changed] => %{consumers: [:bridge]},
    [:cyfr, :sanctum, :provisioning, :fill_requested] => %{
      consumers: [:estate],
      note:
        "an athanor needs filling; the component domain fills it " <>
          "(`Compendium.Provisioning`) — the identity domain owns the claim and the " <>
          "consents, not the bundle"
    },
    [:cyfr, :sanctum, :provisioning, :failed] => %{
      consumers: [:operator],
      note: "athanor provisioning failed mid-way; the sign-in path logs and surfaces it"
    },

    # ——— consent, policy, credentials ———
    [:cyfr, :sanctum, :consent, :integrity_alarm] => %{consumers: [:audit]},
    [:cyfr, :sanctum, :policy, :decision] => %{consumers: [:bridge, :metrics]},
    [:cyfr, :sanctum, :tool_server, :description_drift] => %{
      consumers: [:audit],
      note: "an external tool's description changed under a standing consent (rug-pull signal)"
    },
    [:cyfr, :sanctum, :tool_server, :description_drift_check_failed] => %{
      consumers: [:audit],
      note: "the drift check itself failed — a broken check must be distinguishable from no drift"
    },
    [:cyfr, :sanctum, :provider_credentials, :fetch] => %{
      consumers: [:audit],
      note: "a stored provider credential was unsealed for use"
    },
    [:cyfr, :sanctum, :vault, :oauth_refresh] => %{
      consumers: [:audit],
      note: "a vault OAuth credential was refreshed (or failed to be)"
    },
    [:cyfr, :opus, :oauth, :token_request] => %{
      consumers: [:audit],
      note: "a component asked the host to dispense an OAuth token"
    },
    [:cyfr, :opus, :secret, :dispensed] => %{
      consumers: [:audit],
      note:
        "a vault field of the consented projection handed to a runner at the attach that " <>
          "claimed its attempt, by name, once per field and attempt"
    },
    [:cyfr, :opus, :secret, :denied] => %{
      consumers: [:audit],
      note:
        "a runner reported its guest refused a vault field outside its projection, by the " <>
          "name the guest asked for, attributed to the attempt whose call key signed the report"
    },

    # ——— key rotation ———
    [:cyfr, :sanctum, :crypto_rotation, :run] => %{
      consumers: [:audit],
      note: "a keyring rotation ran — the audit trail records that sealed rows were rewritten"
    },
    [:cyfr, :sanctum, :crypto_rotation, :table] => %{
      consumers: [:operator],
      note: "per-table rotation progress; the :run summary is audited"
    },
    [:cyfr, :sanctum, :crypto_rotation, :row] => %{
      consumers: [:operator],
      note: "per-row rotation failures; the :run summary is audited"
    },

    # ——— executions ———
    [:cyfr, :opus, :execute, :start] => %{consumers: [:audit, :bridge]},
    [:cyfr, :opus, :execute, :stop] => %{consumers: [:audit, :bridge]},
    [:cyfr, :opus, :execute, :exception] => %{consumers: [:audit, :bridge]},
    [:cyfr, :opus, :force_release] => %{
      consumers: [:audit],
      note: "a platform admin forcibly released an execution lease — a platform-scope verb"
    },
    [:cyfr, :opus, :fetch] => %{
      consumers: [:operator],
      note:
        "a component's bytes read by digest, at admission and for its runner's fetch_artifact; " <>
          "execute.start/stop carry the outcome"
    },
    [:cyfr, :opus, :runtime, :authority_entered] => %{
      consumers: [:operator],
      emitter: :worker,
      note:
        "every WASM entry in a runner names the authority it runs under; the control plane " <>
          "knows it from the assignment it signed"
    },
    [:cyfr, :opus, :execution_events, :broadcast_failure] => %{
      consumers: [:operator],
      note: "a guest event could not reach its subscribers; the execution itself continues"
    },
    [:cyfr, :storage_projection, :changed] => %{
      consumers: [:projection],
      note:
        "a unit under a seeded root changed, committed: the root's epoch, and whether the " <>
          "bytes the change names are served yet. The component domain's reconciler " <>
          "re-derives its projection of the root from it; a lost one costs a read's barrier"
    },
    [:cyfr, :storage_gc, :sweep] => %{
      consumers: [:operator],
      note:
        "one estate's staged-revision sweep: prefixes examined, collected, kept and repaired, " <>
          "moves still pending and errors, so an operator sees staging that is not draining"
    },
    [:cyfr, :opus, :execution, :unreaped_kill] => %{
      consumers: [:operator],
      note:
        "a run was killed whose native work may still be running, counted against its " <>
          "tenant; the execution slots refuse the tenant past a threshold"
    },
    [:cyfr, :execution, :child, :admission] => %{
      consumers: [:operator],
      note:
        "a child run's step span (`Crucible.StepSpans`): the call of run_child to the " <>
          "guest's start; `mix cyfr.bench.step` reads it for the per-step latency baseline"
    },
    [:cyfr, :execution, :child, :first_delta] => %{
      consumers: [:operator],
      note:
        "a child run's step span (`Crucible.StepSpans`): the guest's start to its " <>
          "first streamed delta; `mix cyfr.bench.step` reads it for time to first delta"
    },
    [:cyfr, :execution, :child, :completion] => %{
      consumers: [:operator],
      note:
        "a child run's step span (`Crucible.StepSpans`): the guest's start to its " <>
          "completed row; `mix cyfr.bench.step` reads it for the per-step latency baseline"
    },
    [:cyfr, :execution, :run_child] => %{
      consumers: [:operator],
      note:
        "a child run's whole call as its caller waits on it (`Crucible.StepSpans`); " <>
          "`mix cyfr.bench.step` reads it for the per-step total"
    },
    [:cyfr, :opus, :execution, :unsigned] => %{
      consumers: [:operator],
      note:
        "code with no verified signature ran because CYFR_REQUIRE_SIGNED_PULLS is off — " <>
          "the operator's posture made visible at the moment it is exercised, so " <>
          "'we allow unsigned pulls' does not read the same as 'we have none'"
    },
    # A tincture invoking one of its dependencies (`Crucible.invoke_tincture/3`),
    # whichever surface asked.
    [:cyfr, :crucible, :tincture, :invoke, :start] => %{consumers: [:bridge, :metrics]},
    [:cyfr, :crucible, :tincture, :invoke, :stop] => %{consumers: [:bridge, :metrics]},

    # ——— guest activity (high-frequency observability) ———
    [:cyfr, :opus, :http, :request] => %{
      consumers: [:operator],
      emitter: :worker,
      note: "guest egress activity; bounded and consented elsewhere, kept for operator metrics"
    },
    [:cyfr, :opus, :storage, :call] => %{
      consumers: [:operator],
      emitter: :worker,
      note: "guest storage activity, kept for operator metrics"
    },
    [:cyfr, :opus, :mcp_tool, :call] => %{
      consumers: [:operator],
      emitter: :worker,
      note: "guest tool-call activity, kept for operator metrics"
    },
    [:cyfr, :opus, :formula, :spawn] => %{
      consumers: [:operator],
      emitter: :worker,
      note: "formula concurrency activity, kept for operator metrics"
    },
    [:cyfr, :opus, :emit] => %{
      consumers: [:operator],
      note: "guest stream events, kept for operator metrics"
    },
    [:cyfr, :opus, :formula, :cancel] => %{
      consumers: [:operator],
      emitter: :worker,
      note: "formula concurrency activity, kept for operator metrics"
    },
    [:cyfr, :opus, :formula, :await] => %{
      consumers: [:operator],
      emitter: :worker,
      note: "formula concurrency activity, kept for operator metrics"
    },
    [:cyfr, :opus, :formula, :await_any] => %{
      consumers: [:operator],
      emitter: :worker,
      note: "formula concurrency activity, kept for operator metrics"
    },
    [:cyfr, :opus, :formula, :await_all] => %{
      consumers: [:operator],
      emitter: :worker,
      note: "formula concurrency activity, kept for operator metrics"
    },

    # ——— schedules ———
    [:cyfr, :schedules, :fired] => %{consumers: [:bridge]},
    [:cyfr, :schedules, :completed] => %{
      consumers: [:operator],
      note:
        "a schedule's occurrence completed, for operator metrics; what keeps the outcome as " <>
          "a note is the committed `Cyfr.Bus.ScheduleCompleted` message, not this event"
    },
    [:cyfr, :schedules, :failed] => %{consumers: [:bridge]},
    [:cyfr, :schedules, :scheduler, :load_failed] => %{
      consumers: [:operator],
      note: "scheduler self-alarm: the schedule table could not be read; retried on a timer"
    },
    [:cyfr, :schedules, :scheduler, :fire_failed] => %{
      consumers: [:operator],
      note: "scheduler self-alarm: a due schedule could not be dispatched"
    },
    [:cyfr, :schedules, :scheduler, :timer_failed] => %{
      consumers: [:operator],
      note: "scheduler self-alarm: the tick timer could not be re-armed"
    },
    [:cyfr, :schedules, :scheduler, :record_error_failed] => %{
      consumers: [:operator],
      note: "scheduler self-alarm: a failure could not be recorded on the schedule row"
    },

    # ——— MCP transport & webhooks ———
    [:cyfr, :emissary, :request] => %{consumers: [:bridge, :metrics]},
    [:cyfr, :emissary, :webhook, :invoke, :start] => %{consumers: [:metrics]},
    [:cyfr, :emissary, :webhook, :invoke, :stop] => %{consumers: [:metrics]},
    [:cyfr, :emissary, :webhook, :verify_succeeded] => %{consumers: [:metrics]},
    [:cyfr, :emissary, :webhook, :verify_failed] => %{consumers: [:metrics, :log]},
    [:cyfr, :emissary, :webhook, :dedup_unavailable] => %{consumers: [:metrics]},
    [:cyfr, :emissary, :webhook, :dedup_release_failed] => %{
      consumers: [:operator],
      note:
        "a failed delivery's idempotency claim could not be given back, so the sender's " <>
          "retry will read as a duplicate and the target will never run for that key"
    },
    [:cyfr, :emissary, :webhook, :dedup_settle_failed] => %{
      consumers: [:operator],
      note:
        "a delivery finished but its idempotency claim could not be marked succeeded or " <>
          "failed, so a retry may read as a duplicate (or re-run) against a stale claim"
    },
    [:cyfr, :emissary, :external_server, :reconciled] => %{
      consumers: [:operator],
      note: "external-server reconciler outcome; the reconciler logs the same fact"
    },
    [:cyfr, :emissary, :external_server, :reconcile_failed] => %{
      consumers: [:operator],
      note: "external-server reconciler outcome; the reconciler logs the same fact"
    },

    # ——— components & builds ———
    [:cyfr, :compendium, :component, :install] => %{consumers: [:bridge]},
    [:cyfr, :compendium, :component, :remove] => %{consumers: [:bridge]},
    [:cyfr, :compendium, :component, :push] => %{consumers: [:bridge]},
    [:cyfr, :compendium, :activation, :resolve] => %{
      consumers: [:operator],
      note: "activation-graph resolution timing, kept for operator metrics"
    },
    [:cyfr, :locus, :build, :start] => %{consumers: [:bridge]},
    [:cyfr, :locus, :build, :progress] => %{consumers: [:bridge]},
    [:cyfr, :locus, :build, :stop] => %{consumers: [:bridge]},
    [:cyfr, :mcp, :progress, :dropped] => %{
      consumers: [:operator],
      note:
        "a progress notification dropped because the listening connection's " <>
          "mailbox is backed up (a stalled socket) — the bound that keeps a " <>
          "chatty tool from growing the conn process without limit"
    },

    # ——— agents ———
    [:cyfr, :aqua, :approval] => %{
      consumers: [:audit],
      note: "a person approved or declined an agent's proposed action"
    },

    # ——— the bus ———
    [:cyfr, :bus, :publish_refused] => %{
      consumers: [:operator],
      note:
        "a tenant publish whose topic, actor and payload disagreed on the athanor, or whose " <>
          "payload is not the topic's struct, was refused: a bug above the bus and possibly " <>
          "a leak, counted by the payload's type and never its content"
    },
    [:cyfr, :bus, :bridge_dropped] => %{
      consumers: [:operator],
      note:
        "a bridged event that named no athanor, or lacked what its message needs, had " <>
          "nowhere to go and was dropped: counted, so a producer that stops naming its " <>
          "tenant shows up as a rising count rather than a quiet console"
    },

    # ——— record sink ———
    [:cyfr, :record_sink, :dropped] => %{
      consumers: [:operator],
      note:
        "the async record sink shed a write — mailbox backpressure, or a row " <>
          "still failing after a batch-rollback retry; the drop is counted, not hidden"
    }
  }

  @doc "The full catalog: event name → %{consumers: [...], note: ...}."
  @spec all() :: %{[atom(), ...] => map()}
  def all, do: @catalog

  @doc "Every catalogued event name, sorted."
  @spec events() :: [[atom(), ...]]
  def events, do: @catalog |> Map.keys() |> Enum.sort()

  @doc "The events a given consumer attaches to, sorted."
  @spec consumed_by(atom()) :: [[atom(), ...]]
  def consumed_by(consumer) do
    for {event, %{consumers: consumers}} <- @catalog, consumer in consumers do
      event
    end
    |> Enum.sort()
  end

  @doc """
  The events emitted by `emitter`, sorted: `:worker` for those emitted only
  inside a runner, `:control_plane` for every other.
  """
  @spec emitted_by(:worker | :control_plane) :: [[atom(), ...]]
  def emitted_by(emitter) when emitter in [:worker, :control_plane] do
    for {event, entry} <- @catalog, Map.get(entry, :emitter, :control_plane) == emitter do
      event
    end
    |> Enum.sort()
  end

  @doc "The note for an event, or nil."
  @spec note([atom(), ...]) :: String.t() | nil
  def note(event), do: @catalog |> Map.get(event, %{}) |> Map.get(:note)
end
