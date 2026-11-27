# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.SignInCeilingsTest do
  @moduledoc """
  Each sign-in path's shipped request ceiling, per address in a minute
  (`CyfrWeb.Plugs.AuthRateLimit` as the routers mount it), run up to at
  its route and refused one past it: the vault's OAuth grant callback
  (60), a sign-in's ticket (30) and a protected device's unlock (30).

  Each test comes from an address of its own, so no other test's
  requests count against it.
  """
  use CyfrWeb.ConnCase, async: false

  defp from(conn, n), do: %{conn | remote_ip: {198, 51, 101, n}}

  # `n` requests answered, whatever their answer, and the next one refused
  # 429 with its retry-after.
  defp run_up(n, request) do
    for i <- 1..n do
      status = request.().status
      refute status == 429, "request #{i} of #{n} was refused 429"
    end

    over = request.()
    assert over.status == 429
    assert [_seconds] = get_resp_header(over, "retry-after")
  end

  test "the vault's OAuth grant callback: 60 a minute", %{conn: conn} do
    conn = from(conn, 2)
    run_up(60, fn -> get(conn, "/auth/oauth/callback") end)
  end

  test "a sign-in's ticket: 30 a minute", %{conn: conn} do
    conn = from(conn, 3)
    run_up(30, fn -> get(conn, "/auth/passkey/complete/tkt_not_issued") end)
  end

  test "a protected device's unlock: 30 a minute", %{conn: conn} do
    conn = from(conn, 4)
    run_up(30, fn -> get(conn, "/auth/device/complete") end)
  end
end
