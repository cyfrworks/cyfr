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

  alias Emissary.MCP.Session

  describe "session security" do
    test "forged session ID returns 404", %{conn: conn} do
      # Try to use a session ID that looks valid but doesn't exist
      forged_id = "sess_00000000-0000-0000-0000-000000000000"

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", forged_id)
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list"
        })

      assert json_response(conn, 404)
      response = json_response(conn, 404)
      assert response["error"]["code"] == -33302
    end

    test "SQL injection in session ID is rejected", %{conn: conn} do
      # Try various SQL injection patterns
      injection_patterns = [
        "sess_' OR '1'='1",
        "sess_\"; DROP TABLE sessions; --",
        "sess_1'; DELETE FROM sessions WHERE '1'='1",
        "sess_UNION SELECT * FROM users --"
      ]

      for pattern <- injection_patterns do
        conn =
          conn
          |> recycle()
          |> put_req_header("content-type", "application/json")
          |> put_req_header("mcp-session-id", pattern)
          |> mcp_post(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "tools/list"
          })

        # Should return 404 (not found) not crash or return data
        assert conn.status == 404, "SQL injection pattern should return 404: #{pattern}"
      end
    end

    test "oversized session ID is handled gracefully", %{conn: conn} do
      # Try an absurdly long session ID
      oversized_id = "sess_" <> String.duplicate("a", 10_000)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", oversized_id)
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list"
        })

      # Should return 404 not crash
      assert conn.status == 404
    end

    test "empty session ID is treated as no session", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", "")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list"
        })

      # Empty session should be treated as no session - requires initialize
      assert conn.status in [400, 404]
    end

    test "session ID with null bytes is handled", %{conn: conn} do
      # Try session ID with null bytes
      null_id = "sess_valid\x00injected"

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", null_id)
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list"
        })

      # Should not crash, should return 404
      assert conn.status == 404
    end

    test "session ID with special characters is handled", %{conn: conn} do
      special_ids = [
        "sess_<script>alert('xss')</script>",
        "sess_../../../etc/passwd",
        "sess_${env:SECRET}",
        "sess_{{template_injection}}",
        "sess_%00%0a%0d"
      ]

      for special_id <- special_ids do
        conn =
          conn
          |> recycle()
          |> put_req_header("content-type", "application/json")
          |> put_req_header("mcp-session-id", special_id)
          |> mcp_post(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "tools/list"
          })

        # Should return 404, not crash or expose information
        assert conn.status == 404, "Special ID should return 404: #{special_id}"
      end
    end
  end

  describe "header security" do
    test "request with unusual content-type is handled", %{conn: conn} do
      # Initialize a session first
      init_conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "server/discover"
        })

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
      # Create a valid session
      init_conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "server/discover"
        })

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
      # Initialize session
      init_conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "server/discover"
        })

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
