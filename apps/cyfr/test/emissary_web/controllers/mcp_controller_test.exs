defmodule EmissaryWeb.MCPControllerTest do
  use EmissaryWeb.ConnCase, async: false

  describe "POST /mcp - initialization" do
    test "initializes a new session", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-11-25",
            "clientInfo" => %{"name" => "test", "version" => "1.0"}
          }
        })

      assert json_response(conn, 200)
      response = json_response(conn, 200)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"]["protocolVersion"] == "2025-11-25"
      assert response["result"]["serverInfo"]["name"] == "CYFR"

      # Should return session ID header with sess_<uuid7> format
      assert [session_id] = get_resp_header(conn, "mcp-session-id")
      assert is_binary(session_id)
      assert String.starts_with?(session_id, "sess_")
      assert String.length(session_id) == 41  # sess_ (5) + uuid (36) = 41

      # Should return request ID header with req_<uuid7> format
      assert [request_id] = get_resp_header(conn, "x-request-id")
      assert String.starts_with?(request_id, "req_")
      assert String.length(request_id) == 40  # req_ (4) + uuid (36) = 40
    end

    test "returns server version for incompatible client version", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "1999-01-01"
          }
        })

      # Per MCP spec: server returns its own version; client decides compatibility
      response = json_response(conn, 200)
      assert response["result"]["protocolVersion"] == "2025-11-25"
    end
  end

  describe "POST /mcp - with session" do
    setup %{conn: conn} do
      # Initialize a session first
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-11-25"}
        })

      [session_id] = get_resp_header(conn, "mcp-session-id")
      {:ok, session_id: session_id}
    end

    test "lists available tools", %{conn: conn, session_id: session_id} do
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/list"
        })

      assert json_response(conn, 200)
      response = json_response(conn, 200)

      assert response["result"]["tools"]
      tools = response["result"]["tools"]
      tool_names = Enum.map(tools, & &1["name"])

      assert "system" in tool_names
      assert "session" in tool_names
      assert "retention" in tool_names

      # Should return request ID header
      assert [request_id] = get_resp_header(conn, "x-request-id")
      assert String.starts_with?(request_id, "req_")
    end

    test "calls system status action", %{conn: conn, session_id: session_id} do
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/call",
          "params" => %{
            "name" => "system",
            "arguments" => %{"action" => "status"}
          }
        })

      assert json_response(conn, 200)
      response = json_response(conn, 200)

      assert response["result"]["content"]
      [content] = response["result"]["content"]
      assert content["type"] == "text"

      # Parse the JSON text content
      result = Jason.decode!(content["text"])
      # Status may be "ok" or "degraded" depending on which services are available
      assert result["status"] in ["ok", "degraded"]
      assert is_map(result["services"])
    end

    test "calls system status with scope", %{conn: conn, session_id: session_id} do
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/call",
          "params" => %{
            "name" => "system",
            "arguments" => %{"action" => "status", "scope" => "sanctum"}
          }
        })

      assert json_response(conn, 200)
      response = json_response(conn, 200)

      [content] = response["result"]["content"]
      result = Jason.decode!(content["text"])
      assert result["status"] in ["ok", "degraded"]
      # Only sanctum should be in services
      assert Map.keys(result["services"]) == ["sanctum"]
    end

    test "calls system notify action", %{conn: conn, session_id: session_id} do
      # Use a mock endpoint that won't actually connect
      # The test verifies the action is recognized and parameters are processed
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "tools/call",
          "params" => %{
            "name" => "system",
            "arguments" => %{
              "action" => "notify",
              "event" => "test.event",
              "target" => "http://localhost:9999/webhook",
              "payload" => %{"test" => true}
            }
          }
        })

      assert json_response(conn, 200)
      response = json_response(conn, 200)

      [content] = response["result"]["content"]
      result = Jason.decode!(content["text"])

      # Should have attempted delivery (will fail since endpoint doesn't exist)
      assert result["delivered"] == false
      assert result["target"] == "http://localhost:9999/webhook"
      assert result["event"] == "test.event"
    end

    test "calls session whoami tool", %{conn: conn, session_id: session_id} do
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "tools/call",
          "params" => %{
            "name" => "session",
            "arguments" => %{"action" => "whoami"}
          }
        })

      assert json_response(conn, 200)
      response = json_response(conn, 200)

      [content] = response["result"]["content"]
      # With test auth provider, whoami returns user info
      result = Jason.decode!(content["text"])
      assert result["user_id"] == "test_user"
    end

    test "returns protocol error for unknown tool", %{conn: conn, session_id: session_id} do
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 5,
          "method" => "tools/call",
          "params" => %{
            "name" => "nonexistent/tool",
            "arguments" => %{}
          }
        })

      # Per MCP spec: unknown tools return JSON-RPC protocol error, not isError result
      response = json_response(conn, 400)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] =~ "Unknown tool: nonexistent/tool"
    end
  end

  describe "DELETE /mcp - session termination" do
    test "terminates an existing session", %{conn: conn} do
      # Initialize first
      init_conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-11-25"}
        })

      [session_id] = get_resp_header(init_conn, "mcp-session-id")

      # Terminate
      del_conn =
        conn
        |> recycle()
        |> put_req_header("mcp-session-id", session_id)
        |> delete("/mcp")

      assert response(del_conn, 202)

      # Subsequent requests should fail
      post_conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/list"
        })

      assert json_response(post_conn, 404)
    end
  end

  describe "POST /mcp - API key authentication" do
    setup %{conn: _conn} do
      # Use a temp directory for API key tests
      test_dir = Path.join(System.tmp_dir!(), "cyfr_api_key_ctrl_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(test_dir)

      # Store original config
      original_base_path = Application.get_env(:cyfr, :base_path)
      Application.put_env(:cyfr, :base_path, test_dir)

      # Create a test API key
      ctx = Sanctum.Context.local()
      {:ok, key_result} = Sanctum.ApiKey.create(ctx, %{
        name: "test-ctrl-key",
        type: :application
      })

      on_exit(fn ->
        File.rm_rf!(test_dir)
        if original_base_path do
          Application.put_env(:cyfr, :base_path, original_base_path)
        else
          Application.delete_env(:cyfr, :base_path)
        end
      end)

      {:ok, api_key: key_result.key}
    end

    test "tools/list works with API key (no session)", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list"
        })

      assert json_response(conn, 200)
      response = json_response(conn, 200)

      assert response["result"]["tools"]
      tools = response["result"]["tools"]
      tool_names = Enum.map(tools, & &1["name"])

      assert "system" in tool_names
    end

    test "tools/call works with API key", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{
            "name" => "system",
            "arguments" => %{"action" => "status"}
          }
        })

      assert json_response(conn, 200)
      response = json_response(conn, 200)

      assert response["result"]["content"]
      [content] = response["result"]["content"]
      assert content["type"] == "text"
    end

    test "ping works with API key", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "ping"
        })

      assert json_response(conn, 200)
      response = json_response(conn, 200)
      assert response["result"] == %{}
    end

    test "initialize with API key still creates a real persisted session", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-11-25",
            "clientInfo" => %{"name" => "test", "version" => "1.0"}
          }
        })

      assert json_response(conn, 200)
      response = json_response(conn, 200)

      assert response["result"]["protocolVersion"] == "2025-11-25"

      # Initialize should return a real session ID
      assert [session_id] = get_resp_header(conn, "mcp-session-id")
      assert String.starts_with?(session_id, "sess_")
    end

    test "response does NOT include mcp-session-id header for non-initialize requests", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 5,
          "method" => "tools/list"
        })

      assert json_response(conn, 200)
      assert get_resp_header(conn, "mcp-session-id") == []
    end

    test "DELETE /mcp with API key returns 404 (no session to terminate)", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> delete("/mcp")

      assert response(conn, 404)
    end
  end

  describe "request logging" do
    test "logs requests to mcp_logs", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-11-25"}
        })

      [request_id] = get_resp_header(conn, "x-request-id")

      # Logging is synchronous — no wait needed

      # Verify log was created
      log = Arca.Repo.get(Arca.McpLog, request_id)

      assert log.id == request_id
      assert log.method == "initialize"
      assert log.status == "success"
      assert is_integer(log.duration_ms)

      # Cleanup
      Arca.Repo.delete(log)
    end

    test "logs tool calls with tool and action", %{conn: conn} do
      # Initialize first
      init_conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-11-25"}
        })

      [session_id] = get_resp_header(init_conn, "mcp-session-id")
      [init_request_id] = get_resp_header(init_conn, "x-request-id")

      # Make a tool call
      tool_conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{
            "name" => "system",
            "arguments" => %{"action" => "status"}
          }
        })

      [request_id] = get_resp_header(tool_conn, "x-request-id")

      # Logging is synchronous — no wait needed

      log = Arca.Repo.get(Arca.McpLog, request_id)

      assert log.method == "tools/call"
      assert log.tool == "system"
      assert log.action == "status"
      assert log.status == "success"
      assert log.routed_to == "emissary"

      # Cleanup
      Arca.Repo.delete(log)
      Arca.Repo.get(Arca.McpLog, init_request_id) |> Arca.Repo.delete()
    end
  end

  # Note: Batch requests are not supported via HTTP per MCP 2025-11-25 spec
  # Batch request support is only available through the internal API (Emissary.MCP)

  describe "POST /mcp - notifications" do
    setup %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-11-25"}
        })

      [session_id] = get_resp_header(conn, "mcp-session-id")
      {:ok, session_id: session_id}
    end

    test "handles notifications/initialized", %{conn: conn, session_id: session_id} do
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized"
        })

      # Notifications return 202 Accepted with no body
      assert response(conn, 202)
    end

    test "handles notifications/cancelled", %{conn: conn, session_id: session_id} do
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "method" => "notifications/cancelled",
          "params" => %{"requestId" => 123}
        })

      assert response(conn, 202)
    end

    # Note: Batch requests (mixing requests and notifications) are not supported via HTTP
    # per MCP 2025-11-25 spec - only available through internal API
  end

  describe "POST /mcp - resources" do
    setup %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-11-25"}
        })

      [session_id] = get_resp_header(conn, "mcp-session-id")
      {:ok, session_id: session_id}
    end

    test "lists available resources", %{conn: conn, session_id: session_id} do
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "resources/list"
        })

      assert json_response(conn, 200)
      response = json_response(conn, 200)

      assert response["result"]["resources"]
      assert is_list(response["result"]["resources"])
    end

    test "returns error for unknown resource URI scheme", %{conn: conn, session_id: session_id} do
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "resources/read",
          "params" => %{
            "uri" => "unknown://resource/path"
          }
        })

      # Resource errors return 400 with JSON-RPC error
      assert json_response(conn, 400)
      response = json_response(conn, 400)

      assert response["error"]["message"] =~ "No provider found"
    end

    test "returns error for invalid URI format", %{conn: conn, session_id: session_id} do
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "resources/read",
          "params" => %{
            "uri" => "invalid-uri-no-scheme"
          }
        })

      assert json_response(conn, 400)
      response = json_response(conn, 400)

      assert response["error"]["message"] =~ "Invalid URI"
    end
  end

  describe "POST /mcp - JSON-RPC validation" do
    setup %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-11-25"}
        })

      [session_id] = get_resp_header(conn, "mcp-session-id")
      {:ok, session_id: session_id}
    end

    test "rejects invalid JSON-RPC version", %{conn: conn, session_id: session_id} do
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "1.0",
          "id" => 2,
          "method" => "tools/list"
        })

      assert json_response(conn, 400)
      response = json_response(conn, 400)
      assert response["error"]["message"] =~ "jsonrpc"
    end

    test "rejects missing jsonrpc field", %{conn: conn, session_id: session_id} do
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "id" => 2,
          "method" => "tools/list"
        })

      assert json_response(conn, 400)
      response = json_response(conn, 400)
      assert response["error"]["message"] =~ "jsonrpc"
    end

    test "handles ping method", %{conn: conn, session_id: session_id} do
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "ping"
        })

      assert json_response(conn, 200)
      response = json_response(conn, 200)
      assert response["result"] == %{}
    end
  end

  describe "POST /mcp - JSON-RPC edge cases" do
    setup %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-11-25"}
        })

      [session_id] = get_resp_header(conn, "mcp-session-id")
      {:ok, session_id: session_id}
    end

    test "rejects null id in request", %{conn: conn, session_id: session_id} do
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => nil,
          "method" => "ping"
        })

      # MCP spec: unlike base JSON-RPC, the ID MUST NOT be null
      response = json_response(conn, 400)
      assert response["error"]["message"] =~ "Request ID must not be null"
    end

    test "handles string id in request", %{conn: conn, session_id: session_id} do
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => "string-request-id",
          "method" => "ping"
        })

      assert json_response(conn, 200)
      response = json_response(conn, 200)
      assert response["id"] == "string-request-id"
      assert response["result"] == %{}
    end

    test "handles missing params field (optional per spec)", %{conn: conn, session_id: session_id} do
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/list"
        })

      # Request without params field should work
      assert json_response(conn, 200)
      response = json_response(conn, 200)
      assert is_list(response["result"]["tools"])
    end

    test "handles empty object as valid JSON-RPC (fails validation)", %{conn: conn, session_id: session_id} do
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{})

      # Empty object is missing required fields
      assert json_response(conn, 400)
      response = json_response(conn, 400)
      assert response["error"]["message"] =~ "jsonrpc" or response["error"]["message"] =~ "required"
    end

    test "handles deeply nested params", %{conn: conn, session_id: session_id} do
      # Create deeply nested structure
      deep_nested =
        Enum.reduce(1..50, %{"value" => "bottom"}, fn i, acc ->
          %{"level_#{i}" => acc}
        end)

      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "tools/call",
          "params" => %{
            "name" => "system",
            "arguments" => %{"action" => "status", "nested" => deep_nested}
          }
        })

      # Should handle deeply nested data without crashing
      assert conn.status in [200, 400]
    end

    test "handles very long method name", %{conn: conn, session_id: session_id} do
      long_method = String.duplicate("a", 10_000)

      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 5,
          "method" => long_method
        })

      # Should return method not found, not crash
      assert conn.status in [200, 400]
    end

    test "rejects numeric method (invalid per spec)", %{conn: conn, session_id: session_id} do
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 6,
          "method" => 12345
        })

      response = json_response(conn, 400)
      assert response["error"]["message"] =~ "Method must be a string"
    end

    test "rejects array as method (invalid per spec)", %{conn: conn, session_id: session_id} do
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 7,
          "method" => ["tools", "list"]
        })

      response = json_response(conn, 400)
      assert response["error"]["message"] =~ "Method must be a string"
    end

    test "handles negative integer id", %{conn: conn, session_id: session_id} do
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => -999,
          "method" => "ping"
        })

      # Negative IDs are valid per JSON-RPC
      assert json_response(conn, 200)
      response = json_response(conn, 200)
      assert response["id"] == -999
    end

    test "handles float id (should work per JSON-RPC)", %{conn: conn, session_id: session_id} do
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 3.14,
          "method" => "ping"
        })

      # Float IDs are technically valid but unusual
      assert conn.status in [200, 400]
    end

    test "handles special characters in string id", %{conn: conn, session_id: session_id} do
      special_id = "id-with-special-\u0000-\n-\t-chars"

      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => special_id,
          "method" => "ping"
        })

      # Should handle special characters
      assert conn.status in [200, 400]
    end

    test "handles unicode in params", %{conn: conn, session_id: session_id} do
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 8,
          "method" => "tools/call",
          "params" => %{
            "name" => "system",
            "arguments" => %{"action" => "status", "unicode" => "日本語 🎉 émojis"}
          }
        })

      # Should handle unicode without issues
      assert json_response(conn, 200)
    end
  end

  describe "concurrent requests" do
    setup %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-11-25"}
        })

      [session_id] = get_resp_header(conn, "mcp-session-id")
      {:ok, session_id: session_id}
    end

    @tag :slow
    test "handles 50 concurrent tool calls", %{conn: conn, session_id: session_id} do
      # Spawn 50 concurrent requests
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            conn
            |> recycle()
            |> put_req_header("content-type", "application/json")
            |> put_req_header("mcp-session-id", session_id)
            |> post("/mcp", %{
              "jsonrpc" => "2.0",
              "id" => i,
              "method" => "tools/call",
              "params" => %{
                "name" => "system",
                "arguments" => %{"action" => "status"}
              }
            })
          end)
        end

      # Wait for all and verify results
      results = Task.await_many(tasks, 30_000)

      for conn <- results do
        assert json_response(conn, 200)
        response = json_response(conn, 200)
        assert response["result"]["content"]
      end
    end

    @tag :slow
    test "multiple sessions do not interfere", %{conn: conn} do
      # Create 5 separate sessions
      sessions =
        for _ <- 1..5 do
          init_conn =
            conn
            |> recycle()
            |> put_req_header("content-type", "application/json")
            |> post("/mcp", %{
              "jsonrpc" => "2.0",
              "id" => 1,
              "method" => "initialize",
              "params" => %{"protocolVersion" => "2025-11-25"}
            })

          [session_id] = get_resp_header(init_conn, "mcp-session-id")
          session_id
        end

      # Make concurrent requests from each session
      tasks =
        for {session_id, i} <- Enum.with_index(sessions) do
          Task.async(fn ->
            conn
            |> recycle()
            |> put_req_header("content-type", "application/json")
            |> put_req_header("mcp-session-id", session_id)
            |> post("/mcp", %{
              "jsonrpc" => "2.0",
              "id" => i,
              "method" => "session",
              "params" => %{
                "name" => "session",
                "arguments" => %{"action" => "whoami"}
              }
            })
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # Each should succeed
      for conn <- results do
        assert conn.status in [200, 400]
      end

      # Terminate session 1 and verify it doesn't affect session 2
      Emissary.MCP.Session.terminate(Enum.at(sessions, 0))

      # Session 2 should still work
      session2 = Enum.at(sessions, 1)

      result_conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session2)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 99,
          "method" => "ping"
        })

      assert json_response(result_conn, 200)
    end
  end

  describe "tool routing" do
    setup %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-11-25"}
        })

      [session_id] = get_resp_header(conn, "mcp-session-id")
      {:ok, session_id: session_id}
    end

    @tool_routing_cases [
      {"component", "compendium"},
      {"retention", "arca"},
      {"session", "sanctum"},
      {"permission", "sanctum"},
      {"secret", "sanctum"},
      {"key", "sanctum"},
      {"system", "emissary"}
    ]

    for {tool, expected_service} <- @tool_routing_cases do
      @tool tool
      @expected_service expected_service

      test "routes #{tool} tool to #{expected_service}", %{conn: conn, session_id: session_id} do
        tool_conn =
          conn
          |> recycle()
          |> put_req_header("content-type", "application/json")
          |> put_req_header("mcp-session-id", session_id)
          |> post("/mcp", %{
            "jsonrpc" => "2.0",
            "id" => 2,
            "method" => "tools/call",
            "params" => %{
              "name" => @tool,
              "arguments" => %{"action" => "status"}
            }
          })

        [request_id] = get_resp_header(tool_conn, "x-request-id")

        # Logging is synchronous — no wait needed
        log = Arca.Repo.get(Arca.McpLog, request_id)
        assert log.routed_to == @expected_service

        # Cleanup
        Arca.Repo.delete(log)
      end
    end

    for {tool, expected_service} <- [{"execution", "opus"}, {"build", "locus"}] do
      @tool tool
      @expected_service expected_service

      @tag :requires_opus
      test "routes #{tool} tool to #{expected_service}", %{conn: conn, session_id: session_id} do
        tool_conn =
          conn
          |> recycle()
          |> put_req_header("content-type", "application/json")
          |> put_req_header("mcp-session-id", session_id)
          |> post("/mcp", %{
            "jsonrpc" => "2.0",
            "id" => 2,
            "method" => "tools/call",
            "params" => %{
              "name" => @tool,
              "arguments" => %{"action" => "status"}
            }
          })

        [request_id] = get_resp_header(tool_conn, "x-request-id")

        # Logging is synchronous — no wait needed
        log = Arca.Repo.get(Arca.McpLog, request_id)
        assert log.routed_to == @expected_service

        # Cleanup
        Arca.Repo.delete(log)
      end
    end

    test "routes unknown tools to emissary", %{conn: conn, session_id: session_id} do
      tool_conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{
            "name" => "unknown_tool",
            "arguments" => %{"action" => "test"}
          }
        })

      [request_id] = get_resp_header(tool_conn, "x-request-id")

      # Logging is synchronous — no wait needed

      log = Arca.Repo.get(Arca.McpLog, request_id)
      assert log.routed_to == "emissary"

      # Cleanup
      Arca.Repo.delete(log)
    end
  end

  describe "payload handling" do
    setup %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-11-25"}
        })

      [session_id] = get_resp_header(conn, "mcp-session-id")
      {:ok, session_id: session_id}
    end

    test "handles large request body (100KB)", %{conn: conn, session_id: session_id} do
      # Create a large payload (~100KB)
      large_data = String.duplicate("x", 100_000)

      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{
            "name" => "system",
            "arguments" => %{"action" => "status", "extra" => large_data}
          }
        })

      # Should handle large payloads without crashing
      assert conn.status in [200, 400, 413]
    end

    test "handles large response from tool", %{conn: conn, session_id: session_id} do
      # Call a tool that returns substantial data
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/list"
        })

      assert json_response(conn, 200)
      response = json_response(conn, 200)

      # Verify we got a valid list back
      assert is_list(response["result"]["tools"])
    end
  end

  describe "CYFR error codes (PRD §4.5)" do
    test "session required error returns CYFR code -33301", %{conn: conn} do
      # Try to make a request without initializing a session
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list"
        })

      assert json_response(conn, 400)
      response = json_response(conn, 400)

      # Should return CYFR transport error code for session_required
      assert response["error"]["code"] == -33301
      assert response["error"]["message"] =~ "Session required"
    end

    test "session expired/not found returns CYFR code -33302", %{conn: conn} do
      # Try to use a non-existent session
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", "sess_nonexistent_00000000-0000-0000-0000-000000000000")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list"
        })

      assert json_response(conn, 404)
      response = json_response(conn, 404)

      # Should return CYFR transport error code for session_expired
      assert response["error"]["code"] == -33302
      assert response["error"]["message"] =~ "Session not found or expired"
    end

    test "invalid MCP-Protocol-Version header returns CYFR code -33303", %{conn: conn} do
      # Initialize a session first
      init_conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-11-25"}
        })

      [session_id] = get_resp_header(init_conn, "mcp-session-id")

      # The header validation applies to non-initialize requests
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "1999-01-01")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "ping"
        })

      response = json_response(conn, 400)

      # Should return CYFR transport error code for invalid_protocol
      assert response["error"]["code"] == -33303
      assert response["error"]["message"] =~ "Unsupported MCP-Protocol-Version"
    end

    test "CYFR error codes are in correct ranges" do
      alias Emissary.MCP.Message

      # Transport errors: -33300 to -33399
      assert Message.cyfr_code(:session_required) == -33301
      assert Message.cyfr_code(:session_expired) == -33302
      assert Message.cyfr_code(:invalid_protocol) == -33303

      # Auth errors: -33000 to -33099
      assert Message.cyfr_code(:auth_required) == -33001
      assert Message.cyfr_code(:auth_invalid) == -33002
      assert Message.cyfr_code(:auth_expired) == -33003
      assert Message.cyfr_code(:insufficient_permissions) == -33004

      # Execution errors: -33100 to -33199
      assert Message.cyfr_code(:execution_failed) == -33100
      assert Message.cyfr_code(:execution_timeout) == -33101
      assert Message.cyfr_code(:capability_denied) == -33102

      # Registry errors: -33200 to -33299
      assert Message.cyfr_code(:component_not_found) == -33200
      assert Message.cyfr_code(:component_invalid) == -33201
      assert Message.cyfr_code(:registry_unavailable) == -33202

      # Signature errors: -33400 to -33499
      assert Message.cyfr_code(:signature_invalid) == -33400
      assert Message.cyfr_code(:signature_expired) == -33401
      assert Message.cyfr_code(:signature_missing) == -33402
    end

    test "cyfr_error?/1 correctly identifies CYFR error codes" do
      alias Emissary.MCP.Message

      # CYFR codes should return true
      assert Message.cyfr_error?(-33000) == true
      assert Message.cyfr_error?(-33301) == true
      assert Message.cyfr_error?(-33499) == true

      # JSON-RPC standard codes should return false
      assert Message.cyfr_error?(-32700) == false
      assert Message.cyfr_error?(-32600) == false
      assert Message.cyfr_error?(0) == false
    end

    test "encode_error/4 handles CYFR error code atoms", %{conn: _conn} do
      alias Emissary.MCP.Message

      # Verify encode_error produces correct code for CYFR atoms
      error = Message.encode_error(1, :session_required, "Test error")
      assert error["error"]["code"] == -33301

      error = Message.encode_error(2, :auth_required, "Auth needed")
      assert error["error"]["code"] == -33001

      error = Message.encode_error(3, :execution_failed, "Exec failed")
      assert error["error"]["code"] == -33100
    end
  end

  describe "mcp-protocol-version header" do
    test "included on initialization response", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-11-25"}
        })

      assert json_response(conn, 200)
      assert get_resp_header(conn, "mcp-protocol-version") == ["2025-11-25"]
    end

    test "included on notification 202 response", %{conn: conn} do
      # Initialize first
      init_conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-11-25"}
        })

      [session_id] = get_resp_header(init_conn, "mcp-session-id")

      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized"
        })

      assert response(conn, 202)
      assert get_resp_header(conn, "mcp-protocol-version") == ["2025-11-25"]
    end

    test "included on session-required error response", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list"
        })

      assert json_response(conn, 400)
      assert get_resp_header(conn, "mcp-protocol-version") == ["2025-11-25"]
    end

    test "included on error responses", %{conn: conn} do
      # Initialize first
      init_conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-11-25"}
        })

      [session_id] = get_resp_header(init_conn, "mcp-session-id")

      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{
            "name" => "nonexistent/tool",
            "arguments" => %{}
          }
        })

      assert json_response(conn, 400)
      assert get_resp_header(conn, "mcp-protocol-version") == ["2025-11-25"]
    end

    test "included on batch rejection response", %{conn: conn} do
      # Send a batch (array) which should be rejected
      # Must encode manually since Phoenix ConnTest.post/3 expects a map
      batch_body = Jason.encode!([
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"},
        %{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"}
      ])

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Phoenix.ConnTest.dispatch(EmissaryWeb.Endpoint, :post, "/mcp", batch_body)

      assert json_response(conn, 400)
      assert get_resp_header(conn, "mcp-protocol-version") == ["2025-11-25"]
    end
  end
end
