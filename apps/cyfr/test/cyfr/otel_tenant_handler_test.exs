# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.OtelTenantHandlerTest do
  # attach/0 attaches a handler global to the node.
  use ExUnit.Case, async: false

  alias Cyfr.OtelTenantHandler

  describe "attach/0" do
    test "attaches one handler to the post-pipeline :stop events, however often it is called" do
      on_exit(fn -> :telemetry.detach("cyfr-otel-tenant") end)

      assert :ok == OtelTenantHandler.attach()
      assert :ok == OtelTenantHandler.attach()

      handlers =
        for event <- [[:phoenix, :endpoint, :stop], [:phoenix, :router_dispatch, :stop]],
            %{id: "cyfr-otel-tenant"} = handler <- :telemetry.list_handlers(event),
            do: handler.event_name

      assert handlers == [[:phoenix, :endpoint, :stop], [:phoenix, :router_dispatch, :stop]]
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
