# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.MCPOriginTest do
  use ExUnit.Case, async: false

  alias EmissaryWeb.Plugs.MCPOrigin

  setup do
    prior = Application.get_env(:cyfr, :mcp_allowed_origins)

    on_exit(fn ->
      if is_nil(prior) do
        Application.delete_env(:cyfr, :mcp_allowed_origins)
      else
        Application.put_env(:cyfr, :mcp_allowed_origins, prior)
      end
    end)

    :ok
  end

  defp call(origin) do
    conn = Plug.Test.conn(:post, "/mcp", "{}")
    conn = if origin, do: Plug.Conn.put_req_header(conn, "origin", origin), else: conn
    MCPOrigin.call(conn, MCPOrigin.init([]))
  end

  test "passes through when no Origin header is present" do
    conn = call(nil)
    refute conn.halted
    assert conn.status == nil
  end

  test "default config allows localhost variants" do
    Application.delete_env(:cyfr, :mcp_allowed_origins)

    for origin <- ["http://localhost", "https://localhost", "http://127.0.0.1:4000"] do
      refute call(origin).halted, "expected #{origin} to be allowed by default"
    end
  end

  test "default config rejects a non-localhost origin" do
    Application.delete_env(:cyfr, :mcp_allowed_origins)
    conn = call("https://test.otakuent.net")
    assert conn.halted
    assert conn.status == 403
  end

  test "configured CYFR_HOST origin is allowed" do
    Application.put_env(:cyfr, :mcp_allowed_origins, [
      "https://test.otakuent.net",
      "http://test.otakuent.net",
      "http://localhost"
    ])

    refute call("https://test.otakuent.net").halted
    refute call("http://test.otakuent.net").halted
    assert call("https://evil.example.com").halted
  end

  test "localhost matches with any port" do
    Application.put_env(:cyfr, :mcp_allowed_origins, ["http://localhost"])
    refute call("http://localhost:4000").halted
    refute call("http://localhost:5173").halted
  end
end
