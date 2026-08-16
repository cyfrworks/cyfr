# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ConnectionsLiveTest do
  @moduledoc """
  Minimal smoke test in the WebhooksLiveTest convention — the vault verbs
  themselves are covered by `vault_test`, `oauth_grant_test` and the MCP
  dispatch tests. Here we verify the route is wired and gated behind
  authentication.
  """

  use PrismWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "GET /connections (unauthenticated)" do
    test "redirects to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, athanor_path("/connections"))
    end
  end
end
