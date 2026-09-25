# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.ControlPlaneOwnershipTest do
  # Flips the process-wide standing record, so it owns it for its run.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Arca.ControlPlane
  alias EmissaryWeb.Plugs.ControlPlaneOwnership

  setup do
    on_exit(fn -> ControlPlane.record(:unclaimed) end)
    :ok
  end

  test "a member that lost its cell slot answers 503 to everything but health" do
    ControlPlane.record(:lost)

    conn = ControlPlaneOwnership.call(conn(:get, "/a/home/chat"), [])
    assert conn.halted
    assert conn.status == 503
    assert get_resp_header(conn, "retry-after") == ["5"]
    assert %{"code" => "not_owner"} = Jason.decode!(conn.resp_body)

    probe = ControlPlaneOwnership.call(conn(:get, "/api/health/ready"), [])
    refute probe.halted
  end

  test "a member holding its slot is not touched" do
    ControlPlane.record({:held, 60_000})
    conn = ControlPlaneOwnership.call(conn(:get, "/a/home/chat"), [])
    refute conn.halted
    assert ControlPlane.held?()
  end

  test "a lease that expired on the clock is not ownership, whatever the tick saw" do
    ControlPlane.record({:held, 0})
    conn = ControlPlaneOwnership.call(conn(:get, "/a/home/chat"), [])
    assert conn.halted
    assert conn.status == 503
  end

  test "the catalog dispatches nothing for a member that lost its slot" do
    ctx = Sanctum.TestContext.local()
    ControlPlane.record(:lost)

    # A stale owner admits no work: the gate refuses before any handler,
    # and the refusal is its own, of class not_owner.
    assert {:error,
            %Prima.Refusal{
              stage: :admission,
              class: :not_owner,
              reason: :control_plane_lost,
              message: message
            }} = Grimoire.call_external("system", ctx, %{"action" => "status"})

    assert message == Grimoire.Error.render(:control_plane_lost)
    assert message =~ "control plane"

    ControlPlane.record(:unclaimed)
    assert {:ok, _} = Grimoire.call_external("system", ctx, %{"action" => "status"})
  end

  test "a proxied external server is not dispatched for a member that lost its slot" do
    ctx = Sanctum.TestContext.local()
    ControlPlane.record(:lost)

    assert {:error, %Prima.Refusal{stage: :admission, reason: :control_plane_lost}} =
             Grimoire.call_external("notion:create_page", ctx, %{"action" => "create"})
  end

  # Over `/mcp` the gate's admission refusal is a JSON-RPC error by its
  # class, not a failed tool result.
  test "a tools/call to a member that lost its slot answers the not_owner error code" do
    ctx = Sanctum.TestContext.local()
    ControlPlane.record(:lost)

    call = %Emissary.MCP.Message{
      type: :request,
      id: 1,
      method: "tools/call",
      params: %{"name" => "system", "arguments" => %{"action" => "status"}}
    }

    assert {:error, :not_owner, message} = Emissary.MCP.Router.dispatch(ctx, call)
    assert message == Grimoire.Error.render(:control_plane_lost)
    assert Emissary.MCP.Message.error_code(:not_owner) == -33_102
  end
end
