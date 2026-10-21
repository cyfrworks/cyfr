# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ShellRedirectTest do
  use PrismWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "GET / (unauthenticated)" do
    test "redirects to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/")
    end
  end
end
