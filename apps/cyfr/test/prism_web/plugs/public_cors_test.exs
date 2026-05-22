# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.Plugs.PublicCorsTest do
  use ExUnit.Case, async: true

  alias PrismWeb.Plugs.PublicCors

  describe "single-user CORS" do
    test "sets Access-Control-Allow-Origin: * for GET requests" do
      conn =
        Plug.Test.conn(:get, "/public/local/test/q/latest")
        |> PublicCors.call(PublicCors.init([]))

      assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == ["*"]
      refute conn.halted
    end

    test "does not set Vary: Origin with wildcard" do
      conn =
        Plug.Test.conn(:get, "/public/local/test/q/latest")
        |> PublicCors.call(PublicCors.init([]))

      assert Plug.Conn.get_resp_header(conn, "vary") == []
    end

    test "exposes retry-after header" do
      conn =
        Plug.Test.conn(:get, "/public/local/test/q/latest")
        |> PublicCors.call(PublicCors.init([]))

      assert Plug.Conn.get_resp_header(conn, "access-control-expose-headers") == ["retry-after"]
    end
  end

  describe "OPTIONS preflight" do
    test "returns 204 and halts" do
      conn =
        Plug.Test.conn(:options, "/public/local/test/q/latest")
        |> PublicCors.call(PublicCors.init([]))

      assert conn.status == 204
      assert conn.halted
    end

    test "includes CORS preflight headers" do
      conn =
        Plug.Test.conn(:options, "/public/local/test/q/latest")
        |> PublicCors.call(PublicCors.init([]))

      assert Plug.Conn.get_resp_header(conn, "access-control-allow-methods") == ["GET, OPTIONS"]
      assert Plug.Conn.get_resp_header(conn, "access-control-allow-headers") == ["content-type"]
      assert Plug.Conn.get_resp_header(conn, "access-control-max-age") == ["86400"]
    end

    test "sets allow-origin on preflight" do
      conn =
        Plug.Test.conn(:options, "/public/local/test/q/latest")
        |> PublicCors.call(PublicCors.init([]))

      assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end
  end
end
