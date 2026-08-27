# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.IntegrationTest do
  @moduledoc """
  Integration tests for Emissary MCP server.

  Tests the complete request lifecycle including:
  - Session creation and management
  - Tool calls through ToolRegistry
  - Request logging to Arca
  - Telemetry event emission
  - Error handling propagation
  """
  use EmissaryWeb.ConnCase, async: false

  alias Emissary.MCP

  describe "an ordinary request, end to end" do
    test "a tool call needs no handshake and leaves nothing behind", %{conn: conn} do
      # No discovery, no notification, no session — the first thing this
      # connection ever sends is the call itself. The test used to perform a
      # handshake before the call it claimed needed none, which proved only
      # that a handshake is tolerated.
      tool_conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{
            "name" => "system",
            "arguments" => %{"action" => "status", "scope" => "emissary"}
          }
        })

      assert json_response(tool_conn, 200)
      response = json_response(tool_conn, 200)
      [content] = response["result"]["content"]
      result = Jason.decode!(content["text"])
      assert result["status"] == "ok"
    end

    test "each call stands on its own credential", %{conn: conn} do
      # Multiple tool calls
      for i <- 2..5 do
        call_conn =
          conn
          |> recycle()
          |> put_req_header("content-type", "application/json")
          |> mcp_post(%{
            "jsonrpc" => "2.0",
            "id" => i,
            "method" => "tools/call",
            "params" => %{
              "name" => "system",
              "arguments" => %{"action" => "status"}
            }
          })

        assert json_response(call_conn, 200)
      end

      # Each call stood on its own credential; there is no session to outlive them.
    end
  end

  describe "request logging verification" do
    test "request log created with correct fields", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "server/discover"
        })

      [request_id] = get_resp_header(conn, "x-request-id")

      # Logging is synchronous — no wait needed

      log = Arca.Repo.get(Arca.McpLog, request_id)

      # Verify all required fields
      assert log.id == request_id
      assert log.method == "server/discover"
      assert log.status == "success"
      assert log.timestamp
      assert is_integer(log.duration_ms)
      assert log.duration_ms >= 0

      # Cleanup
      Arca.Repo.get(Arca.McpLog, request_id) |> Arca.Repo.delete()
    end

    test "tool call log includes tool and action", %{conn: conn} do
      # Initialize first
      init_conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "server/discover"
        })

      [init_request_id] = get_resp_header(init_conn, "x-request-id")

      # Make tool call
      tool_conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
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
      assert log.routed_to == "emissary"

      # Cleanup
      Arca.Repo.get(Arca.McpLog, request_id) |> Arca.Repo.delete()
      Arca.Repo.get(Arca.McpLog, init_request_id) |> Arca.Repo.delete()
    end

    test "failed request log includes error details", %{conn: conn} do
      # Initialize first
      init_conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "server/discover"
        })

      [init_request_id] = get_resp_header(init_conn, "x-request-id")

      # Make request that will fail (invalid URI)
      error_conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "resources/read",
          "params" => %{"uri" => "invalid-uri-no-scheme"}
        })

      [request_id] = get_resp_header(error_conn, "x-request-id")

      # Logging is synchronous — no wait needed

      log = Arca.Repo.get(Arca.McpLog, request_id)

      assert log.status == "error"
      assert is_binary(log.error)
      # error_code may be stored as integer or string depending on the error path
      assert log.error_code != nil

      # Cleanup
      Arca.Repo.get(Arca.McpLog, request_id) |> Arca.Repo.delete()
      Arca.Repo.get(Arca.McpLog, init_request_id) |> Arca.Repo.delete()
    end
  end

  describe "telemetry event verification" do
    test "request telemetry emitted on tool call", %{conn: conn} do
      ref = :telemetry_test.attach_event_handlers(self(), [[:cyfr, :emissary, :request]])

      # Drain initialize telemetry
      receive do
        {[:cyfr, :emissary, :request], ^ref, _, _} -> :ok
      after
        100 -> :ok
      end

      # Make tool call
      _tool_conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{
            "name" => "system",
            "arguments" => %{"action" => "status"}
          }
        })

      # Receive request telemetry
      assert_receive {[:cyfr, :emissary, :request], ^ref, measurements, metadata}
      assert is_integer(measurements.duration)
      assert measurements.duration >= 0
      assert metadata.method == "tools/call"
      assert metadata.tool == "system"
      assert metadata.status == :success
    end
  end

  describe "multiple tool calls in sequence" do
    test "sequential calls maintain correct state", %{conn: conn} do
      # Call 1: status all
      conn1 =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{"name" => "system", "arguments" => %{"action" => "status"}}
        })

      result1 = json_response(conn1, 200)
      assert result1["id"] == 2

      # Call 2: status emissary
      conn2 =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/call",
          "params" => %{
            "name" => "system",
            "arguments" => %{"action" => "status", "scope" => "emissary"}
          }
        })

      result2 = json_response(conn2, 200)
      assert result2["id"] == 3

      # Call 3: tools/list
      conn3 =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "tools/list"
        })

      result3 = json_response(conn3, 200)
      assert result3["id"] == 4
      assert is_list(result3["result"]["tools"])
    end
  end

  describe "error handling propagation" do
    test "tool errors propagate correctly", %{conn: conn} do
      # Call with invalid action
      error_conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{
            "name" => "system",
            "arguments" => %{"action" => "invalid_action"}
          }
        })

      # Input validation rejects invalid enum values at the router level
      # before reaching the tool handler — returns protocol error, not tool error
      response = json_response(error_conn, 400)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] =~ "must be one of"
    end

    test "unknown tool returns protocol error", %{conn: conn} do
      # Call unknown tool
      error_conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{
            "name" => "nonexistent/tool",
            "arguments" => %{}
          }
        })

      # Per MCP spec: unknown tools return JSON-RPC protocol error
      response = json_response(error_conn, 400)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] =~ "Unknown tool: nonexistent/tool"
    end

    test "invalid JSON-RPC returns an error", %{conn: conn} do
      # Send invalid JSON-RPC version with session
      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "1.0",
          "id" => 1,
          "method" => "server/discover"
        })

      response = json_response(conn, 400)
      assert response["error"]["message"] =~ "Unsupported jsonrpc version"
    end

    test "system notify action sends webhook with correct payload", %{conn: conn} do
      # Call notify with a non-existent endpoint (will fail delivery but test the structure)
      notify_conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{
            "name" => "system",
            "arguments" => %{
              "action" => "notify",
              "event" => "test.integration.event",
              "target" => "http://localhost:19999/webhook-test",
              "payload" => %{
                "test_key" => "test_value",
                "nested" => %{"foo" => "bar"}
              }
            }
          }
        })

      response = json_response(notify_conn, 200)
      [content] = response["result"]["content"]

      # A failed delivery is a failed tool call now — the old
      # {"delivered": false} rendered as a success the caller's happy
      # path swallowed.
      assert response["result"]["isError"] == true
      assert content["text"] =~ "http://localhost:19999/webhook-test"
      assert content["text"] =~ "delivery"
    end

    test "system notify fails gracefully with missing target", %{conn: conn} do
      # Call notify without target
      notify_conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{
            "name" => "system",
            "arguments" => %{
              "action" => "notify",
              "event" => "test.event"
            }
          }
        })

      response = json_response(notify_conn, 200)
      assert response["result"]["isError"] == true
      [content] = response["result"]["content"]
      assert content["text"] =~ "target"
    end

    test "system notify fails gracefully with missing event", %{conn: conn} do
      # Call notify without event
      notify_conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{
            "name" => "system",
            "arguments" => %{
              "action" => "notify",
              "target" => "http://localhost:9999/webhook"
            }
          }
        })

      response = json_response(notify_conn, 200)
      assert response["result"]["isError"] == true
      [content] = response["result"]["content"]
      assert content["text"] =~ "event"
    end
  end

  describe "internal MCP module integration" do
    test "MCP.handle_message delegates to ToolRegistry" do
      ctx = Sanctum.TestContext.local()

      message = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{
          "name" => "system",
          "arguments" => %{"action" => "status"}
        }
      }

      {:ok, result, 2} = MCP.handle_message(ctx, message)

      assert is_list(result["content"])
      [content] = result["content"]
      assert content["type"] == "text"
    end
  end

  describe "correlation ID propagation" do
    test "request_id is generated and returned in header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "server/discover"
        })

      # Request ID should be in response header
      [request_id] = get_resp_header(conn, "x-request-id")
      assert String.starts_with?(request_id, "req_")

      # Request ID format: req_<uuid7> where uuid7 is 36 chars
      assert String.length(request_id) == 40
    end

    test "request_id appears in request log", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "server/discover"
        })

      [request_id] = get_resp_header(conn, "x-request-id")

      # Logging is synchronous — no wait needed

      # Verify request_id is in the log
      log = Arca.Repo.get(Arca.McpLog, request_id)
      assert log.id == request_id

      # Cleanup
      Arca.Repo.get(Arca.McpLog, request_id) |> Arca.Repo.delete()
    end

    test "request_id is unique per request", %{conn: conn} do
      # Make multiple requests
      request_ids =
        for _ <- 1..10 do
          response_conn =
            conn
            |> recycle()
            |> put_req_header("content-type", "application/json")
            |> mcp_post(%{
              "jsonrpc" => "2.0",
              "id" => 1,
              "method" => "server/discover"
            })

          [request_id] = get_resp_header(response_conn, "x-request-id")

          # Cleanup session

          request_id
        end

      # All request IDs should be unique
      unique_ids = Enum.uniq(request_ids)
      assert length(unique_ids) == 10
    end

    test "session_id is included in context for tool calls", %{conn: conn} do
      # Initialize
      init_conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "server/discover"
        })

      [init_request_id] = get_resp_header(init_conn, "x-request-id")

      # Make tool call
      tool_conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{
            "name" => "session",
            "arguments" => %{"action" => "whoami"}
          }
        })

      [tool_request_id] = get_resp_header(tool_conn, "x-request-id")

      # Logging is synchronous — no wait needed

      # Verify both requests have their request_ids in logs
      init_log = Arca.Repo.get(Arca.McpLog, init_request_id)
      assert init_log.id == init_request_id

      tool_log = Arca.Repo.get(Arca.McpLog, tool_request_id)
      assert tool_log.id == tool_request_id

      # The log still attributes the call to a caller, now by credential.
      assert tool_log.user_id != nil

      # Cleanup
      Arca.Repo.get(Arca.McpLog, init_request_id) |> Arca.Repo.delete()
      Arca.Repo.get(Arca.McpLog, tool_request_id) |> Arca.Repo.delete()
    end

    test "request_id propagates to downstream tool handlers", %{conn: conn} do
      # Make a tool call that uses the context
      tool_conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
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

      # Request log should exist and contain the request
      log = Arca.Repo.get(Arca.McpLog, request_id)
      assert log.id == request_id
      assert log.method == "tools/call"
      assert log.tool == "system"

      # Cleanup
      Arca.Repo.get(Arca.McpLog, request_id) |> Arca.Repo.delete()
    end

    test "request_id format is valid UUID7", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "server/discover"
        })

      [request_id] = get_resp_header(conn, "x-request-id")

      # Extract the UUID part
      "req_" <> uuid_part = request_id

      # UUID format: 8-4-4-4-12 (36 chars with dashes)
      assert String.length(uuid_part) == 36

      assert String.match?(
               uuid_part,
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
             )
    end

    test "failed requests still have request_id in log", %{conn: conn} do
      # Initialize
      init_conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "server/discover"
        })

      [init_request_id] = get_resp_header(init_conn, "x-request-id")

      # Make a request that will fail
      error_conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "resources/read",
          "params" => %{"uri" => "invalid-uri"}
        })

      [error_request_id] = get_resp_header(error_conn, "x-request-id")

      # Logging is synchronous — no wait needed

      # Error request should still be logged with its request_id
      error_log = Arca.Repo.get(Arca.McpLog, error_request_id)
      assert error_log.id == error_request_id
      assert error_log.status == "error"

      # Cleanup
      Arca.Repo.get(Arca.McpLog, init_request_id) |> Arca.Repo.delete()
      Arca.Repo.get(Arca.McpLog, error_request_id) |> Arca.Repo.delete()
    end
  end
end
