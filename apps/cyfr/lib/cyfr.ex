# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr do
  @moduledoc """
  The host: boot, the control-plane claim and its renewal, the bus,
  telemetry, runtime configuration and the release tasks.

  Every ordinary `Cyfr.*` module belongs to this boundary. It sits above
  the gate, the identity domain and persistence and names nothing above
  itself: a domain or a surface reaches the host downward, and the host
  reaches up only through a port or the bus. The composition root
  (`Cyfr.Application`), the Mix tasks (`Cyfr.Mix`) and the test support
  are boundaries of their own beside it.
  """

  use Boundary,
    deps: [Grimoire, Sanctum, Arca],
    exports: [
      Admission,
      Bootstrap,
      Bus,
      Bus.ApiKeys,
      Bus.AthanorArchived,
      Bus.Build,
      Bus.CallerInvalidated,
      Bus.CardRefreshed,
      Bus.Components,
      Bus.Execution,
      Bus.ExecutionEvent,
      Bus.InstanceEntryChanged,
      Bus.LayoutPublished,
      Bus.McpServers,
      Bus.Membership,
      Bus.Notify,
      Bus.Ping,
      Bus.PolicyDecision,
      Bus.Progress,
      Bus.Request,
      Bus.RoomInView,
      Bus.ScheduleCompleted,
      Bus.ScheduleRun,
      Bus.Schedules,
      Bus.Session,
      Bus.SettingsChanged,
      Bus.ThreadEvent,
      Bus.Tinctures,
      Bus.VaultEntryChanged,
      Bus.Viewing,
      Bus.Webhooks,
      Cell,
      KeyringFingerprint.Check,
      OtelTenantHandler,
      Platform.Settings,
      Platform.Settings.Roster,
      RetentionScheduler,
      RuntimeConfig,
      SeedOffer,
      StandingWatch,
      Telemetry.Catalog,
      TelemetryBridge
    ],
    check: [aliases: true]
end
