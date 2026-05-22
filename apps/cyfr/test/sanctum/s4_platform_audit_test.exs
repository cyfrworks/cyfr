# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.S4PlatformAuditTest do
  @moduledoc """
  Phase 2 S4: every `scope: :platform` context construction is audited via
  `[:cyfr, :sanctum, :platform_context]` telemetry. The sanctioned path
  (`Context.internal/1` / `Sanctum.system_context/0`) is marked
  `sanctioned: true`; a direct `Context.build(scope: :platform, ...)` is
  still allowed (legitimate test fixtures depend on it) but recorded
  `sanctioned: false` and logged, so it is observable rather than silent.

  (A hard raise on direct platform construction is deferred: ~20 cross-app
  test fixtures build platform contexts directly; migrating them to
  `internal/1` is a separate, isolated step. The audit objective — knowing
  who creates the tenant-bypassing scope — is fully met here.)
  """
  use ExUnit.Case, async: false

  alias Sanctum.Context

  setup do
    handler = "s4-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:cyfr, :sanctum, :platform_context],
      fn _e, meas, meta, _ -> send(parent, {:platform_ctx, meas, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  test "Context.internal/0 emits a sanctioned platform event" do
    Context.internal()
    assert_received {:platform_ctx, %{count: 1}, meta}
    assert meta.sanctioned == true
    assert meta.user_id == "system"
    assert is_binary(meta.caller)
  end

  test "Sanctum.system_context/0 is sanctioned" do
    Sanctum.system_context()
    assert_received {:platform_ctx, %{count: 1}, %{sanctioned: true}}
  end

  test "Sanctum.internal_context(scope: :platform) is sanctioned and does not raise" do
    assert %Context{scope: :platform} = Sanctum.internal_context(user_id: "svc")
    assert_received {:platform_ctx, %{count: 1}, %{sanctioned: true, user_id: "svc"}}
  end

  test "a direct Context.build(scope: :platform) is allowed but unsanctioned" do
    assert %Context{scope: :platform} =
             Context.build(user_id: "u1", scope: :platform, authenticated: true)

    assert_received {:platform_ctx, %{count: 1}, %{sanctioned: false, user_id: "u1"}}
  end

  test "non-platform construction emits NO platform event" do
    Context.build(user_id: "u", namespace: "ns", scope: :project, authenticated: true)
    refute_received {:platform_ctx, _, _}
  end

  test "telemetry_bridge-style org-scoped unauthenticated context is not platform" do
    # Mirrors prism/telemetry_bridge.ex after S4: scope :org, not :platform.
    Context.build(scope: :org, org_id: "acme", project_id: "default", authenticated: false)
    refute_received {:platform_ctx, _, _}
  end
end
