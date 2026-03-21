defmodule PrismWeb.ShellRedirectTest do
  use PrismWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "GET / (unauthenticated)" do
    test "redirects to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/")
    end
  end
end
