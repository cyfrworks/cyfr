# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.ControlPlaneOwnershipTest do
  # Flips the process-wide ownership record, so it owns it for its run.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Cyfr.ControlPlane
  alias EmissaryWeb.Plugs.ControlPlaneOwnership

  setup do
    on_exit(fn -> ControlPlane.mark(:unclaimed) end)
    :ok
  end

  test "a boot that lost the control plane answers 503 to everything but health" do
    ControlPlane.mark(:lost)

    conn = ControlPlaneOwnership.call(conn(:get, "/a/home/chat"), [])
    assert conn.halted
    assert conn.status == 503
    assert get_resp_header(conn, "retry-after") == ["5"]
    assert %{"code" => "control_plane_lost"} = Jason.decode!(conn.resp_body)

    probe = ControlPlaneOwnership.call(conn(:get, "/api/health/ready"), [])
    refute probe.halted
  end

  test "the owner is not touched" do
    ControlPlane.mark({:held, DateTime.add(DateTime.utc_now(), 60, :second)})
    conn = ControlPlaneOwnership.call(conn(:get, "/a/home/chat"), [])
    refute conn.halted
    assert :ok = ControlPlane.assert_owner()
  end

  test "a lease that expired on the clock is not ownership, whatever the tick saw" do
    ControlPlane.mark({:held, DateTime.add(DateTime.utc_now(), -1, :second)})
    conn = ControlPlaneOwnership.call(conn(:get, "/a/home/chat"), [])
    assert conn.halted
    assert conn.status == 503
  end

  test "the catalog dispatches nothing for a boot that lost the plane" do
    ctx = Sanctum.TestContext.local()
    ControlPlane.mark(:lost)

    assert {:error, :control_plane_lost} =
             Cyfr.Ops.Catalog.call_external("system", ctx, %{"action" => "status"})

    assert Cyfr.Ops.Error.render(:control_plane_lost) =~ "control plane"

    ControlPlane.mark(:unclaimed)
    assert {:ok, _} = Cyfr.Ops.Catalog.call_external("system", ctx, %{"action" => "status"})
  end
end
