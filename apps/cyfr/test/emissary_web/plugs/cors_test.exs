# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.CORSTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias EmissaryWeb.Plugs.CORS

  setup do
    original = Application.get_env(:cyfr, :cors_allowed_origins)
    on_exit(fn -> Application.put_env(:cyfr, :cors_allowed_origins, original) end)
    :ok
  end

  describe "OPTIONS preflight" do
    test "returns 204 with CORS headers" do
      Application.put_env(:cyfr, :cors_allowed_origins, ["*"])

      conn =
        conn(:options, "/mcp")
        |> put_req_header("origin", "https://example.com")
        |> CORS.call(CORS.init([]))

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-methods") |> List.first() =~ "POST"

      assert get_resp_header(conn, "access-control-allow-headers") |> List.first() =~
               "content-type"

      assert get_resp_header(conn, "access-control-expose-headers") == ["mcp-session-id"]
      assert conn.halted
    end

    test "returns 204 with specific origin when configured" do
      Application.put_env(:cyfr, :cors_allowed_origins, ["https://app.cyfr.run"])

      conn =
        conn(:options, "/mcp")
        |> put_req_header("origin", "https://app.cyfr.run")
        |> CORS.call(CORS.init([]))

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["https://app.cyfr.run"]
    end

    test "no allow-origin header for disallowed origin" do
      Application.put_env(:cyfr, :cors_allowed_origins, ["https://app.cyfr.run"])

      conn =
        conn(:options, "/mcp")
        |> put_req_header("origin", "https://evil.com")
        |> CORS.call(CORS.init([]))

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end
  end

  describe "non-OPTIONS requests" do
    test "adds CORS headers without halting" do
      Application.put_env(:cyfr, :cors_allowed_origins, ["*"])

      conn =
        conn(:post, "/mcp")
        |> put_req_header("origin", "https://example.com")
        |> CORS.call(CORS.init([]))

      refute conn.halted
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-expose-headers") == ["mcp-session-id"]
      assert get_resp_header(conn, "vary") == ["Origin"]
    end

    test "sets Vary: Origin even without matching origin" do
      Application.put_env(:cyfr, :cors_allowed_origins, ["https://app.cyfr.run"])

      conn =
        conn(:post, "/mcp")
        |> put_req_header("origin", "https://evil.com")
        |> CORS.call(CORS.init([]))

      assert get_resp_header(conn, "vary") == ["Origin"]
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end

    test "no origin header present" do
      Application.put_env(:cyfr, :cors_allowed_origins, ["*"])

      conn =
        conn(:post, "/mcp")
        |> CORS.call(CORS.init([]))

      # Wildcard still set when configured as ["*"]
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end
  end
end
