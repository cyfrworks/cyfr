# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.S4PlatformAuditTest do
  @moduledoc """
  Phase 2 S4: platform-scope construction is closed and audited. Every
  `scope: :platform` construction emits `[:cyfr, :sanctum, :platform_context]`
  telemetry; the one sanctioned path (`Context.internal/1` /
  `Sanctum.system_context/0`, fixtures via `Sanctum.TestContext.platform/1`)
  is marked `sanctioned: true`, and a direct
  `Context.build(scope: :platform, ...)` raises — the telemetry event still
  fires first, so even a refused construction leaves a record of who tried.
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

  test "a direct Context.build(scope: :platform) is refused, and the attempt recorded" do
    assert_raise ArgumentError, ~r/platform-scope context is built only by/, fn ->
      Context.build(user_id: "u1", scope: :platform, authenticated: true)
    end

    assert_received {:platform_ctx, %{count: 1}, %{sanctioned: false, user_id: "u1"}}
  end

  test "Sanctum.TestContext.platform/1 is the sanctioned fixture path" do
    assert %Context{scope: :platform, platform_admin: true} =
             Sanctum.TestContext.platform(user_id: "ops", platform_admin: true)

    assert_received {:platform_ctx, %{count: 1}, %{sanctioned: true, user_id: "ops"}}
  end

  test "non-platform construction emits NO platform event" do
    Context.build(user_id: "u", namespace: "ns", scope: :athanor, authenticated: true)
    refute_received {:platform_ctx, _, _}
  end

  test "telemetry_bridge-style athanor-scoped unauthenticated context is not platform" do
    # Mirrors prism/telemetry_bridge.ex: scope :athanor, not :platform.
    Context.build(scope: :athanor, athanor_id: "ath_acme", authenticated: false)
    refute_received {:platform_ctx, _, _}
  end
end
