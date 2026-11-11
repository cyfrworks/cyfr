# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.SignInCeilingsTest do
  @moduledoc """
  Each sign-in path's shipped request ceiling, per address in a minute
  (`CyfrWeb.Plugs.AuthRateLimit` as the routers mount it), run up to at
  its route and refused one past it: a company sign-in's start (30), the
  sign-in callbacks with the vault's OAuth grant callback (60, one
  bucket), a sign-in's ticket (30), a protected device's unlock (30) and
  a protected command line's session (30).

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

  test "a company sign-in's start: 30 a minute", %{conn: conn} do
    conn = from(conn, 1)

    # The browser pipeline's CSRF check runs before this throttle; a test
    # skips it as Plug provides, so the throttle is what answers.
    run_up(30, fn ->
      conn
      |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)
      |> post("/auth/company")
    end)
  end

  test "the sign-in callbacks and the vault's OAuth grant callback: 60 a minute, one bucket",
       %{conn: conn} do
    conn = from(conn, 2)

    for _ <- 1..30, do: refute(get(conn, "/auth/company/callback").status == 429)

    run_up(30, fn -> get(conn, "/auth/oauth/callback") end)
  end

  test "a sign-in's ticket: 30 a minute", %{conn: conn} do
    conn = from(conn, 3)
    run_up(30, fn -> get(conn, "/auth/passkey/complete/tkt_not_issued") end)
  end

  test "a protected device's unlock: 30 a minute", %{conn: conn} do
    conn = from(conn, 4)
    run_up(30, fn -> get(conn, "/auth/device/complete") end)
  end

  test "a protected command line's session: 30 a minute", %{conn: conn} do
    conn = from(conn, 5)

    run_up(30, fn ->
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/device/session", ~s({"ticket":"not-issued"}))
    end)
  end
end
