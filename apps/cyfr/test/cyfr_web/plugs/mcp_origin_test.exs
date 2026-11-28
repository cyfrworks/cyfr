# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.MCPOriginTest do
  @moduledoc """
  The MCP Origin check: an origin is allowed when it is the address of
  the listener that accepted the request, the private address on the
  loopback listener and the browser address on the proxy listener, or one
  of `CYFR_MCP_ALLOWED_ORIGINS`'s extras.
  """
  use ExUnit.Case, async: false

  alias CyfrWeb.Plugs.MCPOrigin

  @browser "https://cyfr.tail1a2b3c.ts.net"

  setup do
    Prima.Test.Env.put_app_env(:sanctum, :browser_address, @browser)
    :ok
  end

  defp call(origin, entry \\ :loopback) do
    conn = Plug.Test.conn(:post, "/mcp", "{}")
    conn = if entry, do: Sanctum.ClientIp.put_ingress(conn, entry), else: conn
    conn = if origin, do: Plug.Conn.put_req_header(conn, "origin", origin), else: conn
    MCPOrigin.call(conn, MCPOrigin.init([]))
  end

  test "passes through when no Origin header is present" do
    conn = call(nil)
    refute conn.halted
    assert conn.status == nil
  end

  test "the loopback listener allows the private address alone" do
    refute call(Sanctum.private_address(), :loopback).halted

    for origin <- [
          @browser,
          "http://localhost:4002",
          "http://127.0.0.1:4002",
          "http://h-aaaaaaaaaaaaaaaa.localhost:4002",
          "https://evil.example"
        ] do
      assert call(origin, :loopback).status == 403, origin
    end
  end

  test "the proxy listener allows the browser address alone" do
    refute call(@browser, :proxy).halted

    for origin <- [
          Sanctum.private_address(),
          "http://cyfr.tail1a2b3c.ts.net",
          @browser <> ":8443"
        ] do
      assert call(origin, :proxy).status == 403, origin
    end
  end

  test "a request no listener tagged allows no origin but the extras" do
    for origin <- [Sanctum.private_address(), @browser] do
      assert call(origin, nil).status == 403, origin
    end
  end

  test "the extras are allowed at either entry, a localhost one on any port" do
    Prima.Test.Env.put_app_env(:cyfr, :mcp_extra_origins, [
      "https://tool.example",
      "http://localhost"
    ])

    for entry <- [:loopback, :proxy] do
      refute call("https://tool.example", entry).halted
      refute call("http://localhost:5173", entry).halted
      assert call("https://evil.example.com", entry).halted
    end
  end
end
