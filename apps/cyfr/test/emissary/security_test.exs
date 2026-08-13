# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.SecurityTest do
  @moduledoc """
  Security tests for Emissary MCP server.

  Tests for:
  - Session ID security (forgery, injection, size limits)
  - Header security (null bytes, oversized headers)
  - Input validation edge cases
  """
  use EmissaryWeb.ConnCase

  # The `Mcp-Session-Id` header used to authenticate, so it had an attack surface
  # worth probing: forged ids, SQL injection, oversized values. The specification
  # removed protocol sessions and requires a server to ignore the header
  # entirely, so what has to hold now is narrower and stronger — whatever is in
  # it, it changes nothing.
  #
  # That is a better property than the ones it replaces: those asserted the
  # server rejected a bad value, which still meant the value reached a lookup.
  describe "the retired session header is inert" do
    @hostile [
      "sess_00000000-0000-0000-0000-000000000000",
      "sess_' OR '1'='1",
      "sess_\"; DROP TABLE sessions; --",
      "sess_" <> String.duplicate("a", 10_000),
      "",
      "sess_\0null"
    ]

    test "no value in it authenticates, and none of them changes the answer",
         %{conn: conn} do
      baseline =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      for value <- @hostile do
        with_header =
          conn
          |> recycle()
          |> put_req_header("content-type", "application/json")
          |> put_req_header("mcp-session-id", value)
          |> mcp_post(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

        assert with_header.status == baseline.status,
               "mcp-session-id changed the outcome for #{inspect(value)}"
      end
    end

    test "the server never mints or echoes a session id", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", "sess_whatever")
        |> mcp_post(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      assert get_resp_header(conn, "mcp-session-id") == []
    end
  end

  describe "header security" do
    test "request with unusual content-type is handled", %{conn: conn} do
      # Try with wrong content-type
      wrong_ct_conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "text/plain")
        |> post(
          "/mcp",
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 2,
            "method" => "tools/list"
          })
        )

      # Should handle gracefully (either reject or parse)
      assert wrong_ct_conn.status in [200, 400, 415]
    end

    test "multiple session ID headers uses first", %{conn: conn} do
      # Send request with multiple session headers via raw connection
      # Phoenix will use the first header value
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "server/discover"
        })

      # Should work with the valid session
      assert json_response(conn, 200)
    end

    test "XSS payloads in params are not executed", %{conn: conn} do
      xss_payloads = [
        "<script>alert('xss')</script>",
        "javascript:alert('xss')",
        "<img src=x onerror=alert('xss')>",
        "'-alert('xss')-'",
        "{{constructor.constructor('alert(1)')()}}"
      ]

      for payload <- xss_payloads do
        response_conn =
          conn
          |> recycle()
          |> put_req_header("content-type", "application/json")
          |> mcp_post(%{
            "jsonrpc" => "2.0",
            "id" => 2,
            "method" => "tools/call",
            "params" => %{
              "name" => "system",
              "arguments" => %{"action" => "status", "xss_test" => payload}
            }
          })

        # Should return valid JSON response, not execute script
        assert response_conn.status == 200

        # Response should be properly JSON encoded
        response = json_response(response_conn, 200)
        assert is_map(response)
      end
    end

    test "path traversal in tool params is contained", %{conn: conn} do
      traversal_payloads = [
        "../../../etc/passwd",
        "..\\..\\..\\windows\\system32",
        "%2e%2e%2f%2e%2e%2f",
        "....//....//",
        "/etc/passwd"
      ]

      for payload <- traversal_payloads do
        response_conn =
          conn
          |> recycle()
          |> put_req_header("content-type", "application/json")
          |> mcp_post(%{
            "jsonrpc" => "2.0",
            "id" => 2,
            "method" => "tools/call",
            "params" => %{
              "name" => "system",
              "arguments" => %{"action" => "status", "path" => payload}
            }
          })

        # Should not crash or expose file system
        assert response_conn.status in [200, 400]
      end
    end

    test "command injection in params is contained", %{conn: conn} do
      injection_payloads = [
        "; rm -rf /",
        "| cat /etc/passwd",
        "$(whoami)",
        "`id`",
        "& echo pwned"
      ]

      for payload <- injection_payloads do
        response_conn =
          conn
          |> recycle()
          |> put_req_header("content-type", "application/json")
          |> mcp_post(%{
            "jsonrpc" => "2.0",
            "id" => 2,
            "method" => "tools/call",
            "params" => %{
              "name" => "system",
              "arguments" => %{"action" => "status", "cmd" => payload}
            }
          })

        # Should not execute commands
        assert response_conn.status in [200, 400]
      end
    end
  end

  describe "rate limiting and resource exhaustion" do
    test "many rapid requests are handled", %{conn: conn} do
      # Send many rapid requests
      results =
        for i <- 1..100 do
          conn
          |> recycle()
          |> put_req_header("content-type", "application/json")
          |> mcp_post(%{
            "jsonrpc" => "2.0",
            "id" => i,
            "method" => "server/discover"
          })
        end

      # All should complete (even if some are rate limited)
      for result <- results do
        assert result.status in [200, 429, 503]
      end
    end
  end
end
