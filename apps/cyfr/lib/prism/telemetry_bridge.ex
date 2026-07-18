# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.TelemetryBridge do
  @moduledoc """
  Bridges CYFR telemetry events to PubSub for LiveView consumption.

  Attaches to existing telemetry events and broadcasts to PubSub topics
  that LiveViews can subscribe to for real-time updates.

  Topics are scoped per-tenant via `Sanctum.PubSub.topic/2` so that a
  tenant-scoped deployment isolates broadcasts per org. In single-tenant
  mode topics pass through unchanged.

  ## Topics

  - `prism:executions` — Execution lifecycle events
  - `prism:system` — System status changes
  - `prism:requests` — MCP request events
  - `prism:components` — Component/policy change events
  - `prism:builds` — Locus build lifecycle events
  - `prism:schedules` — Cron schedule firing events
  - `prism:secrets` — Secret grant/revoke events
  - `prism:tinctures` — Tincture invoke lifecycle events
  - `prism:aqua_approvals` — AQUA approval card decisions (approve/decline)
  - `prism:enforcement` — Policy enforcement decisions (allow/deny audit trail)
  """

  use GenServer
  require Logger

  @pubsub Emissary.PubSub

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    attach_handlers()
    {:ok, %{}}
  end

  defp attach_handlers do
    events = [
      {[:cyfr, :opus, :execute, :start], :execution_start},
      {[:cyfr, :opus, :execute, :stop], :execution_stop},
      {[:cyfr, :opus, :execute, :exception], :execution_exception},
      {[:cyfr, :emissary, :request], :request},
      {[:cyfr, :sanctum, :auth], :auth},
      {[:cyfr, :sanctum, :policy], :policy},
      {[:cyfr, :sanctum, :policy, :decision], :policy_decision},
      {[:cyfr, :locus, :build, :start], :build_start},
      {[:cyfr, :locus, :build, :progress], :build_progress},
      {[:cyfr, :locus, :build, :stop], :build_stop},
      {[:cyfr, :opus, :schedule, :fired], :schedule_fired},
      {[:cyfr, :sanctum, :secret, :grant], :secret_grant},
      {[:cyfr, :sanctum, :secret, :revoke], :secret_revoke},
      {[:cyfr, :compendium, :component, :install], :component_install},
      {[:cyfr, :compendium, :component, :remove], :component_remove},
      {[:cyfr, :emissary, :tincture, :invoke, :start], :tincture_invoke_start},
      {[:cyfr, :emissary, :tincture, :invoke, :stop], :tincture_invoke_stop},
      {[:prism, :aqua, :approval], :aqua_approval}
    ]

    for {event, id} <- events do
      :telemetry.attach(
        "prism-#{id}",
        event,
        &__MODULE__.handle_event/4,
        nil
      )
    end
  end

  def handle_event([:cyfr, :opus, :execute, :start], measurements, metadata, _config) do
    safe_broadcast("prism:executions", metadata, {:execution_started, metadata, measurements})
  end

  def handle_event([:cyfr, :opus, :execute, :stop], measurements, metadata, _config) do
    safe_broadcast("prism:executions", metadata, {:execution_completed, metadata, measurements})
  end

  def handle_event([:cyfr, :opus, :execute, :exception], measurements, metadata, _config) do
    safe_broadcast("prism:executions", metadata, {:execution_failed, metadata, measurements})
  end

  def handle_event([:cyfr, :emissary, :request], measurements, metadata, _config) do
    safe_broadcast("prism:requests", metadata, {:request, metadata, measurements})
  end

  def handle_event([:cyfr, :sanctum, :auth], measurements, metadata, _config) do
    safe_broadcast("prism:system", metadata, {:auth_event, metadata, measurements})
  end

  def handle_event([:cyfr, :sanctum, :policy], measurements, metadata, _config) do
    safe_broadcast("prism:components", metadata, {:policy_changed, metadata, measurements})
  end

  def handle_event([:cyfr, :sanctum, :policy, :decision], measurements, metadata, _config) do
    safe_broadcast("prism:enforcement", metadata, {:policy_decision, metadata, measurements})
  end

  def handle_event([:cyfr, :locus, :build, :start], measurements, metadata, _config) do
    safe_broadcast("prism:builds", metadata, {:build_started, metadata, measurements})
  end

  def handle_event([:cyfr, :locus, :build, :progress], measurements, metadata, _config) do
    safe_broadcast("prism:builds", metadata, {:build_progress, metadata, measurements})
  end

  def handle_event([:cyfr, :locus, :build, :stop], measurements, metadata, _config) do
    safe_broadcast("prism:builds", metadata, {:build_stopped, metadata, measurements})
  end

  def handle_event([:cyfr, :opus, :schedule, :fired], measurements, metadata, _config) do
    safe_broadcast("prism:schedules", metadata, {:schedule_fired, metadata, measurements})
  end

  def handle_event([:cyfr, :sanctum, :secret, :grant], measurements, metadata, _config) do
    safe_broadcast("prism:secrets", metadata, {:secret_granted, metadata, measurements})
  end

  def handle_event([:cyfr, :sanctum, :secret, :revoke], measurements, metadata, _config) do
    safe_broadcast("prism:secrets", metadata, {:secret_revoked, metadata, measurements})
  end

  def handle_event([:cyfr, :compendium, :component, :install], measurements, metadata, _config) do
    safe_broadcast("prism:components", metadata, {:component_installed, metadata, measurements})
  end

  def handle_event([:cyfr, :compendium, :component, :remove], measurements, metadata, _config) do
    safe_broadcast("prism:components", metadata, {:component_removed, metadata, measurements})
  end

  def handle_event(
        [:cyfr, :emissary, :tincture, :invoke, :start],
        measurements,
        metadata,
        _config
      ) do
    safe_broadcast(
      "prism:tinctures",
      metadata,
      {:tincture_invoke_started, metadata, measurements}
    )
  end

  def handle_event([:cyfr, :emissary, :tincture, :invoke, :stop], measurements, metadata, _config) do
    safe_broadcast(
      "prism:tinctures",
      metadata,
      {:tincture_invoke_stopped, metadata, measurements}
    )
  end

  def handle_event([:prism, :aqua, :approval], measurements, metadata, _config) do
    safe_broadcast("prism:aqua_approvals", metadata, {:aqua_approval, metadata, measurements})
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  @impl true
  def handle_info(msg, state) do
    Logger.warning("#{__MODULE__}: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Wrap PubSub broadcast so that a failure never propagates to the caller.
  # This is critical inside :telemetry handler callbacks — if the handler
  # raises, the telemetry library permanently detaches it and all Prism
  # dashboard live updates silently stop.
  defp safe_broadcast(base_topic, metadata, message) do
    topic = scoped_topic(base_topic, metadata)

    case Phoenix.PubSub.broadcast(@pubsub, topic, message) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[TelemetryBridge] PubSub broadcast failed: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.warning("[TelemetryBridge] PubSub broadcast error: #{Exception.message(e)}")
      :ok
  end

  # Build a tenant-scoped topic from telemetry metadata.
  #
  # Always produces a `tenant:<org>:<project>:<base>` topic so it matches the
  # subscribers (every authenticated LiveView context now carries a concrete
  # org — the single-operator default being the seeded `local`/`default`). An
  # event whose metadata omits the tenant is treated as that single-operator
  # default; multi-tenant events carry their org/project and route to that
  # tenant's subscribers. Earlier this fell back to the bare base topic, which
  # no subscriber listened on — so live request/rate updates never fired.
  defp scoped_topic(base, metadata) do
    # Topic-only, unauthenticated context — never reaches authz/storage. `:org`
    # (not `:platform`) avoids the platform-scope audit and models a single
    # resolved org for the prefix.
    ctx =
      Sanctum.Context.build(
        scope: :org,
        org_id: metadata[:org_id] || Arca.Tenant.local_org(),
        project_id: metadata[:project_id] || Arca.Tenant.default_project(),
        authenticated: false
      )

    Sanctum.PubSub.topic(base, ctx)
  end
end
