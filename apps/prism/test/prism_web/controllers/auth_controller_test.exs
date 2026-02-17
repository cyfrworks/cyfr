defmodule PrismWeb.AuthControllerTest do
  use PrismWeb.ConnCase

  describe "GET /auth/logout" do
    test "redirects to login page", %{conn: conn} do
      conn = get(conn, ~p"/auth/logout")
      assert redirected_to(conn) == "/login"
    end
  end

  describe "GET /auth/session" do
    test "redirects to login without code param", %{conn: conn} do
      conn = get(conn, ~p"/auth/session")
      assert redirected_to(conn) == "/login"
    end

    test "redirects to login with invalid exchange code", %{conn: conn} do
      conn = get(conn, ~p"/auth/session?code=invalid_code")
      assert redirected_to(conn) == "/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid or expired"
    end

    test "redirects to login when raw token is passed instead of code", %{conn: conn} do
      conn = get(conn, ~p"/auth/session?token=some_raw_token")
      assert redirected_to(conn) == "/login"
    end
  end
end
