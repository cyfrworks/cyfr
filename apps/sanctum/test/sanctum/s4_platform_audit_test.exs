# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.S4PlatformAuditTest do
  @moduledoc """
  Platform-context construction emits audit telemetry, and nothing else
  does. Internal builders are sanctioned; direct Context.build attempts
  emit an unsanctioned event before raising. A person's focus, an
  operator's included, is no platform context and emits nothing: the
  capability is over the instance, and a person's platform capability
  never enters an athanor.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Context

  setup do
    handler = "s4-#{System.unique_integer([:positive])}"
    parent = self()

    # This case's own process alone: other modules build internal contexts
    # beside it.
    :telemetry.attach(
      handler,
      [:cyfr, :sanctum, :platform_context],
      fn _e, meas, meta, _ ->
        if self() == parent, do: send(parent, {:platform_ctx, meas, meta})
      end,
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

  describe "a person's focus" do
    setup tags do
      Arca.Test.Sandbox.setup!(tags)
      :ok
    end

    test "emits no platform event, an operator's included, admitted or refused" do
      n = System.unique_integer([:positive])
      alice = "github|https://github.com|s4-alice-#{n}"
      ops = "github|https://github.com|s4-ops-#{n}"
      {:ok, group} = Sanctum.Tenancy.Athanors.create_group(alice, "S4 #{n}")
      {:ok, _} = Sanctum.Tenancy.Members.ensure_platform(ops)

      person = fn user_id, athanor_id, admin? ->
        Context.build(
          user_id: user_id,
          athanor_id: athanor_id,
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true,
          platform_admin: admin?
        )
      end

      # Whatever setting the rows up built is not the focus's.
      flush()

      # A member's focus, an operator's refused one, and the revalidation
      # of an operator's session that still names the group.
      assert {:ok, _} = Context.focus(person.(alice, nil, false), group.id)
      assert {:error, :not_member} = Context.focus(person.(ops, nil, true), group.id)
      assert {:ok, %{athanor_id: nil}} = Sanctum.Tenancy.revalidate(person.(ops, group.id, true))

      refute_received {:platform_ctx, _, _}
    end
  end

  defp flush do
    receive do
      {:platform_ctx, _, _} -> flush()
    after
      0 -> :ok
    end
  end
end
