# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.MCPErrorTest do
  @moduledoc """
  JSON-RPC requires an error response to echo the id of the request that caused
  it. Every ingress rejection used to hand-roll its envelope with `"id" => nil`,
  so a client could not correlate the failure to the call it made.
  """
  use EmissaryWeb.ConnCase, async: true

  alias Emissary.MCP.Message

  describe "request id echoing" do
    test "a rate-limit rejection echoes the request id", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-protocol-version", "not-a-version")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 4242,
          "method" => "tools/list"
        })

      body = json_response(conn, 400)
      assert body["id"] == 4242
      assert body["jsonrpc"] == "2.0"
      assert body["error"]["code"] == Message.error_code(:header_mismatch)
    end

    test "a string request id round-trips unchanged", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-protocol-version", "nope")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => "req-abc-1",
          "method" => "tools/list"
        })

      assert json_response(conn, 400)["id"] == "req-abc-1"
    end

    test "an origin rejection echoes the request id", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "https://evil.example.com")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 77,
          "method" => "tools/list"
        })

      body = json_response(conn, 403)
      assert body["id"] == 77
      assert body["error"]["message"] =~ "Origin not allowed"
    end

    test "a batch rejection carries a nil id, which is correct", %{conn: conn} do
      # A batch has no single id to echo, and JSON-RPC allows null only here.
      # ConnTest.post/3 takes a map, so the array is encoded by hand.
      batch_body =
        Jason.encode!([
          %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"},
          %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}
        ])

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> Phoenix.ConnTest.dispatch(EmissaryWeb.Endpoint, :post, "/mcp", batch_body)

      body = json_response(conn, 400)
      assert body["id"] == nil
      assert body["error"]["message"] =~ "Batch requests not supported"
    end
  end
  describe "parser failures on /mcp" do
    # These once escaped to Phoenix's {"errors":{"detail":"Bad Request"}} —
    # no envelope, no -32700, the id lost. The id genuinely cannot be
    # echoed (it was inside the body that failed to parse), so null is the
    # honest value; the envelope and the code are what a JSON-RPC client
    # can branch on.
    test "malformed JSON answers -32700 in the JSON-RPC envelope", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", ~s({"jsonrpc":"2.0","id":7,))

      body = json_response(conn, 400)
      assert body["jsonrpc"] == "2.0"
      assert body["id"] == nil
      assert body["error"]["code"] == Message.error_code(:parse_error)
      assert get_resp_header(conn, "mcp-protocol-version") != []
    end

    test "a non-JSON content type is refused, not degraded to empty params", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "text/plain")
        |> post("/mcp", "jsonrpc 2.0 tools/list")

      body = json_response(conn, 400)
      assert body["error"]["code"] == Message.error_code(:parse_error)
      assert body["error"]["message"] =~ "Content-Type"
    end

    test "a browser path keeps Phoenix's rendering", %{conn: conn} do
      assert_raise Plug.Parsers.ParseError, fn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/auth/whoami", ~s({"broken":))
      end
    end
  end
end
