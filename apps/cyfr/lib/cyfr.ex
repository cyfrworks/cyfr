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
  (`Cyfr.Application`), the Mix tasks that render from the gate's
  operation table or a shared contract (`Cyfr.Mix`) and the test support
  are boundaries of their own beside it.
  """

  use Boundary,
    deps: [Sanctum, Arca],
    exports: [
      Admission,
      Bus,
      Bus.ApiKeys,
      Bus.AquaAsk,
      Bus.AthanorArchived,
      Bus.Attention,
      Bus.Build,
      Bus.CallerInvalidated,
      Bus.Components,
      Bus.CrewActivity,
      Bus.CrewPending,
      Bus.Execution,
      Bus.ExecutionEvent,
      Bus.FeedPublished,
      Bus.FeedRun,
      Bus.FileListed,
      Bus.FileOffer,
      Bus.FrameCredential,
      Bus.LayoutPublished,
      Bus.McpServers,
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
      Bus.ShareChanged,
      Bus.SharedThreadChanged,
      Bus.SystemStatus,
      Bus.ThreadEvent,
      Bus.ThreadListed,
      Bus.Tinctures,
      Bus.VaultEntry,
      Bus.VaultEntryChanged,
      Bus.Webhooks,
      Cell,
      KeyringFingerprint.Check,
      OtelTenantHandler,
      Platform.Settings,
      Platform.Settings.Roster,
      ReleaseChannel,
      Requests,
      RetentionScheduler,
      RuntimeConfig,
      SeedOffer,
      StandingWatch,
      StorageReserve,
      Telemetry.Catalog,
      TelemetryBridge
    ],
    check: [aliases: true]

  # config:compile-runtime-ok — the permission is compiled in on purpose: a
  # release is built without it, so no setting it is given at start-up
  # (`sys.config`, `ERL_AFLAGS`) reaches a test seam.
  @test_seams_permitted Application.compile_env(:cyfr, :bootstrap_skip_permitted, false)

  @doc false
  # A test seam's value: what `read` answers in a build compiled with the
  # test permission (`config/test.exs` alone sets it), else `default`, with
  # `read` never called, so a release reads no seam's key at all. The
  # host's seams are the boot switches the sandboxed suite turns off (the
  # boot gate, the database checks, the timers and watches) and the hooks
  # it points at its stand-ins.
  @spec seam(value, (-> value)) :: value when value: term()
  def seam(default, read), do: seam(@test_seams_permitted, default, read)

  @doc false
  # Pure decision seam, as `Sanctum.seam/3` is: the build's permission,
  # the shipped default and the seam's read.
  @spec seam(boolean(), value, (-> value)) :: value when value: term()
  def seam(true, _default, read) when is_function(read, 0), do: read.()
  def seam(false, default, read) when is_function(read, 0), do: default
end
