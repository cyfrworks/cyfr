# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.ControlPlaneOwnershipTest do
  # Flips the process-wide ownership flag, so it owns the flag for its run.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias EmissaryWeb.Plugs.ControlPlaneOwnership

  @flag {Cyfr.ControlPlane, :owner?}

  setup do
    previous = :persistent_term.get(@flag, true)
    on_exit(fn -> :persistent_term.put(@flag, previous) end)
    :ok
  end

  test "a boot that lost the control plane answers 503 to everything but health" do
    :persistent_term.put(@flag, false)

    conn = ControlPlaneOwnership.call(conn(:get, "/a/home/chat"), [])
    assert conn.halted
    assert conn.status == 503
    assert get_resp_header(conn, "retry-after") == ["5"]
    assert %{"code" => "control_plane_lost"} = Jason.decode!(conn.resp_body)

    probe = ControlPlaneOwnership.call(conn(:get, "/api/health/ready"), [])
    refute probe.halted
  end

  test "the owner is not touched" do
    :persistent_term.put(@flag, true)
    conn = ControlPlaneOwnership.call(conn(:get, "/a/home/chat"), [])
    refute conn.halted
    assert :ok = Cyfr.ControlPlane.assert_owner()
  end
end
