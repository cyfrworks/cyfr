# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.MCPOriginTest do
  use ExUnit.Case, async: false

  alias CyfrWeb.Plugs.MCPOrigin

  # A test that sets its own allowlist restores the suite's afterwards,
  # registering the restore before the change.
  defp put_origins(origins) do
    prior = Application.fetch_env(:cyfr, :mcp_allowed_origins)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:cyfr, :mcp_allowed_origins, value)
        :error -> Application.delete_env(:cyfr, :mcp_allowed_origins)
      end
    end)

    Application.put_env(:cyfr, :mcp_allowed_origins, origins)
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

  test "the suite's local-home allowlist admits localhost variants" do
    for origin <- ["http://localhost", "https://localhost", "http://127.0.0.1:4000"] do
      refute call(origin).halted, "expected #{origin} to be allowed"
    end
  end

  test "the suite's local-home allowlist refuses a non-localhost origin" do
    conn = call("https://test.otakuent.net")
    assert conn.halted
    assert conn.status == 403
  end

  test "configured CYFR_HOST origin is allowed" do
    put_origins([
      "https://test.otakuent.net",
      "http://test.otakuent.net",
      "http://localhost"
    ])

    refute call("https://test.otakuent.net").halted
    refute call("http://test.otakuent.net").halted
    assert call("https://evil.example.com").halted
  end

  test "localhost matches with any port" do
    put_origins(["http://localhost"])
    refute call("http://localhost:4000").halted
    refute call("http://localhost:5173").halted
  end

  # The allowlist a home boots with is its access settings' origins, which
  # `config/runtime.exs` writes (`Cyfr.RuntimeConfigWiringTest`): its own
  # https origin in a tailnet or public home, and the localhost origins on
  # its port.
  defp home_origins(process) do
    {:ok, access} =
      Cyfr.RuntimeConfig.resolve_access(%{file: nil, process: process, release?: true})

    put_origins(access.check_origins)
  end

  test "a tailnet home allows its own https origin and the localhost ones on its port alone" do
    home_origins(%{
      "CYFR_ACCESS" => "tailnet",
      "CYFR_HOST" => "cyfr.tail1a2b3c.ts.net",
      "CYFR_TAILNET_NODE_ID" => "nAbc123XYZ1CNTRL",
      "CYFR_PUBLIC_URL" => "https://cyfr.tail1a2b3c.ts.net"
    })

    for origin <- ["https://cyfr.tail1a2b3c.ts.net", "http://localhost:4000", "http://[::1]:4000"] do
      refute call(origin).halted, origin
    end

    for origin <- [
          "http://cyfr.tail1a2b3c.ts.net",
          "https://cyfr.tail1a2b3c.ts.net:8443",
          "http://localhost:4100",
          "https://evil.example"
        ] do
      assert call(origin).status == 403, origin
    end
  end

  test "a local home allows the localhost origins on its port alone" do
    home_origins(%{"CYFR_ACCESS" => "local", "CYFR_PORT" => "4005"})

    refute call("http://localhost:4005").halted
    refute call("https://127.0.0.1:4005").halted

    for origin <- ["http://localhost:4000", "https://cyfr.tail1a2b3c.ts.net", "https://localhost"] do
      assert call(origin).status == 403, origin
    end
  end
end
