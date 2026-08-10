# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ServerDiscoverTest do
  @moduledoc """
  `server/discover` is how a client learns which protocol revisions a server
  speaks. It has to answer before authentication and without establishing
  anything, or it cannot do that job.
  """
  use EmissaryWeb.ConnCase, async: false

  alias Emissary.MCP.Protocol

  defp discover(conn, id \\ 1) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", %{"jsonrpc" => "2.0", "id" => id, "method" => "server/discover"})
  end

  test "answers without any credential", %{conn: conn} do
    body = json_response(discover(conn), 200)

    assert body["id"] == 1
    assert body["result"]["protocolVersions"] == Protocol.supported()
    assert body["result"]["serverInfo"]["name"] == "CYFR"
    assert is_map(body["result"]["capabilities"])
  end

  test "advertises the version the server actually announces", %{conn: conn} do
    body = json_response(discover(conn), 200)

    # The advertised list and the response header must agree — a server that
    # says one revision and validates another is the failure this replaces.
    assert Protocol.version() in body["result"]["protocolVersions"]
    assert [Protocol.version()] == get_resp_header(discover(conn), "mcp-protocol-version")
  end

  test "establishes nothing — no session id comes back", %{conn: conn} do
    conn = discover(conn)

    assert json_response(conn, 200)
    assert get_resp_header(conn, "mcp-session-id") == []
  end

  test "does not require the initialize handshake first", %{conn: conn} do
    # A bare tools/call without a credential is rejected; discovery is not.
    rejected =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", %{"jsonrpc" => "2.0", "id" => 9, "method" => "tools/list"})

    assert rejected.status == 400
    assert json_response(discover(conn, 10), 200)["result"]
  end
end
