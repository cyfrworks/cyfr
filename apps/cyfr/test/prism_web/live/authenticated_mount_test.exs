# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AuthenticatedMountTest do
  @moduledoc """
  The harness contract: a signed-in test user (claimed namespace, membership,
  session) mounts an authenticated LiveView; a session without a claimed
  namespace is sent to the claim gate.
  """

  use PrismWeb.ConnCase, async: false

  test "a signed-in user mounts /settings", %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)

    {view, html} = live_authenticated(conn, "/settings")

    assert html =~ user.email
    assert render(view) =~ "Settings"
  end

  test "an anonymous conn is redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/settings")
  end

  test "a session without a claimed namespace is sent to the claim gate", %{conn: conn} do
    conn = log_in_user(conn, test_user(), claim: false)

    assert {:error, {:redirect, %{to: to}}} = live(conn, "/settings")
    assert to =~ "/claim-namespace" or to =~ "/login"
  end
end
