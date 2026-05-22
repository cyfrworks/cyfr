# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.Plugs.RequireAuthTest do
  use ExUnit.Case, async: true

  alias PrismWeb.Plugs.RequireAuth

  defp build_conn_with_session(session_data \\ %{}) do
    Plug.Test.conn(:get, "/t/local/test")
    |> Map.put(:secret_key_base, String.duplicate("a", 64))
    |> Plug.Session.call(
      Plug.Session.init(
        store: :cookie,
        key: "_test_key",
        signing_salt: "test_salt"
      )
    )
    |> Plug.Conn.fetch_session()
    |> then(fn conn ->
      Enum.reduce(session_data, conn, fn {k, v}, acc ->
        Plug.Conn.put_session(acc, k, v)
      end)
    end)
  end

  describe "call/2" do
    test "redirects to /login when no session token" do
      conn =
        build_conn_with_session()
        |> RequireAuth.call(RequireAuth.init([]))

      assert conn.halted
      assert Plug.Conn.get_resp_header(conn, "location") == ["/login"]
    end

    test "redirects to /login when session token is invalid" do
      conn =
        build_conn_with_session(%{session_token: "invalid_token_xyz"})
        |> RequireAuth.call(RequireAuth.init([]))

      assert conn.halted
      assert Plug.Conn.get_resp_header(conn, "location") == ["/login"]
    end
  end
end
