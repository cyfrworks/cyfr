# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.OtelTenantHandlerTest do
  use ExUnit.Case, async: true

  alias Cyfr.OtelTenantHandler

  describe "attach/0" do
    test "does not crash when OpenTelemetry is not loaded" do
      assert :ok == OtelTenantHandler.attach()
    end
  end

  describe "the subscribed events" do
    # The handler once hooked the :start pair, which Phoenix emits BEFORE
    # the pipeline runs — `assigns[:context]` was always nil there, so no
    # tenant attribute was ever written and no test noticed. Pin the
    # post-pipeline :stop pair so that regression cannot come back.
    test "are the post-pipeline :stop events" do
      root = Path.expand("../../../..", __DIR__)
      source = File.read!(Path.join(root, "apps/cyfr/lib/cyfr/otel_tenant_handler.ex"))

      assert source =~ "[:phoenix, :endpoint, :stop]"
      assert source =~ "[:phoenix, :router_dispatch, :stop]"
      refute source =~ "[:phoenix, :endpoint, :start]"
      refute source =~ "[:phoenix, :router_dispatch, :start]"
    end
  end

  describe "attributes_from/1" do
    test "an authenticated conn yields both tenant attributes" do
      ctx = Sanctum.TestContext.local()
      conn = %Plug.Conn{assigns: %{context: ctx}}

      attrs = OtelTenantHandler.attributes_from(conn)

      assert {"tenant.athanor_id", ctx.athanor_id} in attrs
      assert {"tenant.user_id", ctx.user_id} in attrs
    end

    test "nil fields are dropped, never written as nil attributes" do
      ctx = Sanctum.Context.build(user_id: "u1", athanor_id: nil)
      conn = %Plug.Conn{assigns: %{context: ctx}}

      assert OtelTenantHandler.attributes_from(conn) == [{"tenant.user_id", "u1"}]
    end

    test "a conn without a context yields nothing" do
      assert OtelTenantHandler.attributes_from(%Plug.Conn{assigns: %{}}) == []
      assert OtelTenantHandler.attributes_from(%Plug.Conn{assigns: %{context: :garbage}}) == []
      assert OtelTenantHandler.attributes_from(nil) == []
    end
  end

  describe "handle_event/4" do
    test "tolerates missing conn in metadata" do
      assert :ok == OtelTenantHandler.handle_event([:test], %{}, %{}, %{})
    end

    test "tolerates conn without context assigns" do
      conn = %Plug.Conn{assigns: %{}}
      assert :ok == OtelTenantHandler.handle_event([:test], %{}, %{conn: conn}, %{})
    end
  end
end
