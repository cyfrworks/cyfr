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
    assert %{"code" => "control_plane_lost"} = Jason.decode!(conn.resp_body)

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

    assert {:error, :control_plane_lost} =
             Grimoire.Catalog.call_external("system", ctx, %{"action" => "status"})

    assert Grimoire.Error.render(:control_plane_lost) =~ "control plane"

    ControlPlane.record(:unclaimed)
    assert {:ok, _} = Grimoire.Catalog.call_external("system", ctx, %{"action" => "status"})
  end

  test "a proxied external server is not dispatched for a member that lost its slot" do
    ctx = Sanctum.TestContext.local()
    ControlPlane.record(:lost)

    assert {:error, :control_plane_lost} =
             Grimoire.Catalog.call_external("notion:create_page", ctx, %{"action" => "create"})
  end
end
