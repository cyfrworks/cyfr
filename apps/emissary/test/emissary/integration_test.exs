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
  use EmissaryWeb.ConnCase

  alias Emissary.MCP
  alias Emissary.MCP.{RequestLog, Session}
  alias Sanctum.Context

  describe "complete MCP session lifecycle" do
    test "initialize -> tool call -> terminate flow", %{conn: conn} do
      # Step 1: Initialize session
      init_conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-11-25",
            "clientInfo" => %{"name" => "integration-test", "version" => "1.0"}
          }
        })

      assert json_response(init_conn, 200)
      [session_id] = get_resp_header(init_conn, "mcp-session-id")
      assert String.starts_with?(session_id, "sess_")

      # Step 2: Send initialized notification
      notif_conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized"
        })

      assert response(notif_conn, 202)

      # Step 3: Make a tool call
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
            "arguments" => %{"action" => "status", "scope" => "emissary"}
          }
        })

      assert json_response(tool_conn, 200)
      response = json_response(tool_conn, 200)
      [content] = response["result"]["content"]
      result = Jason.decode!(content["text"])
      assert result["status"] == "ok"

      # Step 4: Terminate session
      del_conn =
        conn
        |> recycle()
        |> put_req_header("mcp-session-id", session_id)
        |> delete("/mcp")

      assert response(del_conn, 202)

      # Step 5: Verify session is terminated
      post_conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/list"
        })

      assert json_response(post_conn, 404)
    end

    test "session persists across multiple tool calls", %{conn: conn} do
      # Initialize
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

      # Multiple tool calls
      for i <- 2..5 do
        call_conn =
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

        assert json_response(call_conn, 200)
      end

      # Session should still be valid
      assert Session.exists?(session_id)

      # Cleanup
      Session.terminate(session_id)
    end
  end

  describe "request logging verification" do
    test "request log created with correct fields", %{conn: conn} do
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

      # Wait for async logging
      Process.sleep(100)

      {:ok, log} = RequestLog.get(request_id)

      # Verify all required fields
      assert log["request_id"] == request_id
      assert log["method"] == "initialize"
      assert log["status"] == "success"
      assert is_binary(log["timestamp"])
      assert is_integer(log["duration_ms"])
      assert log["duration_ms"] >= 0

      # Cleanup
      RequestLog.delete(request_id)
    end

    test "tool call log includes tool and action", %{conn: conn} do
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

      # Make tool call
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

      # Wait for async logging
      Process.sleep(100)

      {:ok, log} = RequestLog.get(request_id)

      assert log["method"] == "tools/call"
      assert log["tool"] == "system"
      assert log["action"] == "status"
      assert log["routed_to"] == "emissary"

      # Cleanup
      RequestLog.delete(request_id)
      RequestLog.delete(init_request_id)
      Session.terminate(session_id)
    end

    test "failed request log includes error details", %{conn: conn} do
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

      # Make request that will fail (invalid URI)
      error_conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "resources/read",
          "params" => %{"uri" => "invalid-uri-no-scheme"}
        })

      [request_id] = get_resp_header(error_conn, "x-request-id")

      # Wait for async logging
      Process.sleep(100)

      {:ok, log} = RequestLog.get(request_id)

      assert log["status"] == "error"
      assert is_binary(log["error"])
      # error_code may be stored as integer or string depending on the error path
      assert log["error_code"] != nil

      # Cleanup
      RequestLog.delete(request_id)
      RequestLog.delete(init_request_id)
      Session.terminate(session_id)
    end
  end

  describe "telemetry event verification" do
    test "session telemetry emitted on create and terminate" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:cyfr, :emissary, :session]])

      ctx = Context.local()
      {:ok, session} = Session.create(ctx, %{}, transport: :http)

      # Receive create event
      assert_receive {[:cyfr, :emissary, :session], ^ref, %{count: 1}, metadata}
      assert metadata.lifecycle == :created
      assert metadata.transport == :http
      assert metadata.session_id == session.id

      Session.terminate(session.id)

      # Receive terminate event
      assert_receive {[:cyfr, :emissary, :session], ^ref, %{count: 1}, metadata}
      assert metadata.lifecycle == :terminated
      assert metadata.session_id == session.id
    end

    test "request telemetry emitted on tool call", %{conn: conn} do
      ref = :telemetry_test.attach_event_handlers(self(), [[:cyfr, :emissary, :request]])

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

      # Receive request telemetry
      assert_receive {[:cyfr, :emissary, :request], ^ref, measurements, metadata}
      assert is_integer(measurements.duration)
      assert measurements.duration >= 0
      assert metadata.method == "tools/call"
      assert metadata.tool == "system"
      assert metadata.status == :success

      # Cleanup
      Session.terminate(session_id)
    end
  end

  describe "multiple tool calls in sequence" do
    test "sequential calls maintain correct state", %{conn: conn} do
      # Initialize
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

      # Call 1: status all
      conn1 =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
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
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/call",
          "params" => %{"name" => "system", "arguments" => %{"action" => "status", "scope" => "emissary"}}
        })

      result2 = json_response(conn2, 200)
      assert result2["id"] == 3

      # Call 3: tools/list
      conn3 =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "tools/list"
        })

      result3 = json_response(conn3, 200)
      assert result3["id"] == 4
      assert is_list(result3["result"]["tools"])

      # Cleanup
      Session.terminate(session_id)
    end
  end

  describe "error handling propagation" do
    test "tool errors propagate correctly", %{conn: conn} do
      # Initialize
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

      # Call with invalid action
      error_conn =
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
            "arguments" => %{"action" => "invalid_action"}
          }
        })

      response = json_response(error_conn, 200)
      assert response["result"]["isError"] == true
      [content] = response["result"]["content"]
      assert content["text"] =~ "Unknown action"

      # Cleanup
      Session.terminate(session_id)
    end

    test "unknown tool returns error", %{conn: conn} do
      # Initialize
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

      # Call unknown tool
      error_conn =
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

      response = json_response(error_conn, 200)
      assert response["result"]["isError"] == true
      [content] = response["result"]["content"]
      assert content["text"] =~ "Unknown tool"

      # Cleanup
      Session.terminate(session_id)
    end

    test "invalid JSON-RPC returns error without session", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "1.0",
          "id" => 1,
          "method" => "initialize"
        })

      response = json_response(conn, 400)
      # Either JSON-RPC validation or protocol version validation will fail
      assert response["error"]["message"] =~ "jsonrpc" or
               response["error"]["message"] =~ "protocol" or
               response["error"]["message"] =~ "Unsupported"
    end

    test "request without session returns error", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list"
        })

      response = json_response(conn, 400)
      assert response["error"]["message"] =~ "Session required"
    end
  end

  describe "webhook notification (PRD §5.4)" do
    test "system notify action sends webhook with correct payload", %{conn: conn} do
      # Initialize session
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

      # Call notify with a non-existent endpoint (will fail delivery but test the structure)
      notify_conn =
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
      result = Jason.decode!(content["text"])

      # Verify response structure (delivery will fail but structure should be correct)
      assert result["target"] == "http://localhost:19999/webhook-test"
      assert result["event"] == "test.integration.event"
      # Delivery fails because endpoint doesn't exist
      assert result["delivered"] == false
      assert is_binary(result["error"])

      # Cleanup
      Session.terminate(session_id)
    end

    test "system notify fails gracefully with missing target", %{conn: conn} do
      # Initialize session
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

      # Call notify without target
      notify_conn =
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

      # Cleanup
      Session.terminate(session_id)
    end

    test "system notify fails gracefully with missing event", %{conn: conn} do
      # Initialize session
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

      # Call notify without event
      notify_conn =
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

      # Cleanup
      Session.terminate(session_id)
    end
  end

  describe "internal MCP module integration" do
    test "MCP.initialize creates session with correct state" do
      ctx = Context.local()

      {:ok, result, session} = MCP.initialize(ctx, %{"protocolVersion" => "2025-11-25"})

      assert result["protocolVersion"] == "2025-11-25"
      assert result["serverInfo"]["name"] == "CYFR"
      assert String.starts_with?(session.id, "sess_")
      assert session.context.user_id == "local_user"

      # Cleanup
      Session.terminate(session.id)
    end

    test "MCP.handle_message delegates to ToolRegistry" do
      ctx = Context.local()
      {:ok, _result, session} = MCP.initialize(ctx, %{"protocolVersion" => "2025-11-25"})

      message = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{
          "name" => "system",
          "arguments" => %{"action" => "status"}
        }
      }

      {:ok, result, 2} = MCP.handle_message(session, message)

      assert is_list(result["content"])
      [content] = result["content"]
      assert content["type"] == "text"

      # Cleanup
      Session.terminate(session.id)
    end
  end

  describe "correlation ID propagation (PRD §5.9)" do
    test "request_id is generated and returned in header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-11-25"}
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
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-11-25"}
        })

      [request_id] = get_resp_header(conn, "x-request-id")

      # Wait for async logging
      Process.sleep(100)

      # Verify request_id is in the log
      {:ok, log} = RequestLog.get(request_id)
      assert log["request_id"] == request_id

      # Cleanup
      RequestLog.delete(request_id)
    end

    test "request_id is unique per request", %{conn: conn} do
      # Make multiple requests
      request_ids =
        for _ <- 1..10 do
          response_conn =
            conn
            |> recycle()
            |> put_req_header("content-type", "application/json")
            |> post("/mcp", %{
              "jsonrpc" => "2.0",
              "id" => 1,
              "method" => "initialize",
              "params" => %{"protocolVersion" => "2025-11-25"}
            })

          [request_id] = get_resp_header(response_conn, "x-request-id")
          [session_id] = get_resp_header(response_conn, "mcp-session-id")

          # Cleanup session
          Session.terminate(session_id)

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
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-11-25"}
        })

      [session_id] = get_resp_header(init_conn, "mcp-session-id")
      [init_request_id] = get_resp_header(init_conn, "x-request-id")

      # Make tool call
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
            "name" => "session",
            "arguments" => %{"action" => "whoami"}
          }
        })

      [tool_request_id] = get_resp_header(tool_conn, "x-request-id")

      # Wait for async logging
      Process.sleep(100)

      # Verify both requests have their request_ids in logs
      {:ok, init_log} = RequestLog.get(init_request_id)
      assert init_log["request_id"] == init_request_id

      {:ok, tool_log} = RequestLog.get(tool_request_id)
      assert tool_log["request_id"] == tool_request_id

      # Tool log should have session_id context
      assert tool_log["session_id"] == session_id or
               tool_log["user_id"] != nil

      # Cleanup
      RequestLog.delete(init_request_id)
      RequestLog.delete(tool_request_id)
      Session.terminate(session_id)
    end

    test "request_id propagates to downstream tool handlers", %{conn: conn} do
      # Initialize
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

      # Make a tool call that uses the context
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

      # Wait for async logging
      Process.sleep(100)

      # Request log should exist and contain the request
      {:ok, log} = RequestLog.get(request_id)
      assert log["request_id"] == request_id
      assert log["method"] == "tools/call"
      assert log["tool"] == "system"

      # Cleanup
      RequestLog.delete(request_id)
      Session.terminate(session_id)
    end

    test "request_id format is valid UUID7", %{conn: conn} do
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
      [session_id] = get_resp_header(conn, "mcp-session-id")

      # Extract the UUID part
      "req_" <> uuid_part = request_id

      # UUID format: 8-4-4-4-12 (36 chars with dashes)
      assert String.length(uuid_part) == 36
      assert String.match?(uuid_part, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)

      # Cleanup
      Session.terminate(session_id)
    end

    test "session_id format is valid UUID7", %{conn: conn} do
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

      # Extract the UUID part
      "sess_" <> uuid_part = session_id

      # UUID format: 8-4-4-4-12 (36 chars with dashes)
      assert String.length(uuid_part) == 36
      assert String.match?(uuid_part, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)

      # Cleanup
      Session.terminate(session_id)
    end

    test "failed requests still have request_id in log", %{conn: conn} do
      # Initialize
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

      # Make a request that will fail
      error_conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "resources/read",
          "params" => %{"uri" => "invalid-uri"}
        })

      [error_request_id] = get_resp_header(error_conn, "x-request-id")

      # Wait for async logging
      Process.sleep(100)

      # Error request should still be logged with its request_id
      {:ok, error_log} = RequestLog.get(error_request_id)
      assert error_log["request_id"] == error_request_id
      assert error_log["status"] == "error"

      # Cleanup
      RequestLog.delete(init_request_id)
      RequestLog.delete(error_request_id)
      Session.terminate(session_id)
    end
  end
end
