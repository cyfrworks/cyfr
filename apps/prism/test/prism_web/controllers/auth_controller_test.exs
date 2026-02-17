defmodule PrismWeb.AuthControllerTest do
  use PrismWeb.ConnCase

  describe "GET /auth/logout" do
    test "redirects to login page", %{conn: conn} do
      conn = get(conn, ~p"/auth/logout")
      assert redirected_to(conn) == "/login"
    end
  end

  describe "GET /auth/session" do
    test "redirects to login without token", %{conn: conn} do
      conn = get(conn, ~p"/auth/session")
      assert redirected_to(conn) == "/login"
    end
  end
end
