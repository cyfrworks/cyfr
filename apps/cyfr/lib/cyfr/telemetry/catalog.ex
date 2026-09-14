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
  - `:bridge` — `Prism.TelemetryBridge` → console PubSub. Pinned equal by
    test.
  - `:metrics` — `EmissaryWeb.Telemetry` metric definitions. Pinned equal
    by test.
  - `:log` — a dedicated Logger attach (`Cyfr.Application`).
  - `:notes` — `Cyfr.ScheduleNotes`, which files a completed schedule's
    outcome as a note when the schedule asked for it. Pinned by test.
  - `:operator` — consciously unconsumed by shipped machinery: kept for an
    operator's own monitoring attach, or pinned by tests. The `note` says
    why it earns its place; no event is orphaned silently.
  """

  @catalog %{
    # ——— audit plane ———
    [:cyfr, :audit, :pipeline_failure] => %{
      consumers: [:operator],
      note:
        "the audit plane's own alarm — deliberately OUTSIDE its own pipeline: " <>
          "auditing it would recurse when every sink is down"
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
    [:cyfr, :opus, :secret, :accessed] => %{consumers: [:audit]},
    [:cyfr, :opus, :secret, :denied] => %{consumers: [:audit]},

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
      note: "component-bytes fetch during execution setup; execute.start/stop carry the outcome"
    },
    [:cyfr, :opus, :runtime, :authority_entered] => %{
      consumers: [:operator],
      note:
        "pinned by the authority characterization tests — every WASM entry names its authority"
    },
    [:cyfr, :opus, :execution_events, :broadcast_failure] => %{
      consumers: [:operator],
      note: "a guest event could not reach its subscribers; the execution itself continues"
    },
    [:cyfr, :opus, :execution, :unreaped_kill] => %{
      consumers: [:operator],
      note:
        "a timeout kill left a native thread spinning (no wasmex epoch interruption) — " <>
          "the one signal that a node is quietly losing cores; the semaphore refuses the " <>
          "tenant past a threshold"
    },
    [:cyfr, :opus, :execution, :unsigned] => %{
      consumers: [:operator],
      note:
        "code with no verified signature ran because CYFR_REQUIRE_SIGNED_PULLS is off — " <>
          "the operator's posture made visible at the moment it is exercised, so " <>
          "'we allow unsigned pulls' does not read the same as 'we have none'"
    },

    # ——— guest activity (high-frequency observability) ———
    [:cyfr, :opus, :http, :request] => %{
      consumers: [:operator],
      note: "guest egress activity; bounded and consented elsewhere, kept for operator metrics"
    },
    [:cyfr, :opus, :storage, :call] => %{
      consumers: [:operator],
      note: "guest storage activity, kept for operator metrics"
    },
    [:cyfr, :opus, :mcp_tool, :call] => %{
      consumers: [:operator],
      note: "guest tool-call activity, kept for operator metrics"
    },
    [:cyfr, :opus, :formula, :spawn] => %{
      consumers: [:operator],
      note: "formula concurrency activity, kept for operator metrics"
    },
    [:cyfr, :opus, :emit] => %{
      consumers: [:operator],
      note: "guest stream events, kept for operator metrics"
    },
    [:cyfr, :opus, :formula, :cancel] => %{
      consumers: [:operator],
      note: "formula concurrency activity, kept for operator metrics"
    },
    [:cyfr, :opus, :formula, :await] => %{
      consumers: [:operator],
      note: "formula concurrency activity, kept for operator metrics"
    },
    [:cyfr, :opus, :formula, :await_any] => %{
      consumers: [:operator],
      note: "formula concurrency activity, kept for operator metrics"
    },
    [:cyfr, :opus, :formula, :await_all] => %{
      consumers: [:operator],
      note: "formula concurrency activity, kept for operator metrics"
    },

    # ——— schedules ———
    [:cyfr, :schedules, :fired] => %{consumers: [:bridge]},
    [:cyfr, :schedules, :completed] => %{
      consumers: [:notes],
      note: "a schedule with `keep_outcome` in its metadata files the run's output as a note"
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

    # ——— MCP transport & tinctures & webhooks ———
    [:cyfr, :emissary, :request] => %{consumers: [:bridge, :metrics]},
    [:cyfr, :emissary, :tincture, :invoke, :start] => %{consumers: [:bridge, :metrics]},
    [:cyfr, :emissary, :tincture, :invoke, :stop] => %{consumers: [:bridge, :metrics]},
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

  @doc "The note for an event, or nil."
  @spec note([atom(), ...]) :: String.t() | nil
  def note(event), do: @catalog |> Map.get(event, %{}) |> Map.get(:note)
end
