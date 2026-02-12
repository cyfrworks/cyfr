defmodule Emissary.MCPTest do
  @moduledoc """
  Tests for the internal MCP API (direct Elixir calls).

  These tests verify that MCP functionality works without HTTP transport,
  enabling internal usage from Prism/LiveView components.
  """
  use ExUnit.Case, async: true

  alias Emissary.MCP
  alias Emissary.MCP.Session
  alias Sanctum.Context

  setup do
    Arca.Cache.init()
    :ok
  end

  describe "initialize/2 - internal session creation" do
    test "creates session without HTTP context" do
      ctx = Context.local()
      params = %{"protocolVersion" => "2025-11-25"}

      {:ok, result, session} = MCP.initialize(ctx, params)

      assert result["protocolVersion"] == "2025-11-25"
      assert result["serverInfo"]["name"] == "CYFR"
      assert result["capabilities"]["tools"]
      assert String.starts_with?(session.id, "sess_")
      assert session.context == ctx

      Session.terminate(session.id)
    end

    test "rejects unsupported protocol version" do
      ctx = Context.local()
      params = %{"protocolVersion" => "1999-01-01"}

      result = MCP.initialize(ctx, params)

      assert {:error, :invalid_protocol, message} = result
      assert message =~ "Unsupported protocol version"
    end

    test "session inherits context permissions" do
      ctx = %Context{
        user_id: "test_user",
        org_id: "test_org",
        permissions: MapSet.new(["read:files", "write:files"]),
        scope: :organization
      }

      params = %{"protocolVersion" => "2025-11-25"}
      {:ok, _result, session} = MCP.initialize(ctx, params)

      assert session.context.user_id == "test_user"
      assert session.context.org_id == "test_org"
      assert MapSet.member?(session.context.permissions, "read:files")
      assert session.context.scope == :organization

      Session.terminate(session.id)
    end
  end

  describe "handle_message/2 - request processing" do
    setup do
      ctx = Context.local()
      {:ok, _result, session} = MCP.initialize(ctx, %{"protocolVersion" => "2025-11-25"})

      on_exit(fn -> Session.terminate(session.id) end)

      {:ok, session: session}
    end

    test "handles tools/list request", %{session: session} do
      params = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list"
      }

      {:ok, result, 1} = MCP.handle_message(session, params)

      assert is_list(result["tools"])
      tool_names = Enum.map(result["tools"], & &1["name"])
      assert "system" in tool_names
    end

    test "handles tools/call request", %{session: session} do
      params = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{
          "name" => "system",
          "arguments" => %{"action" => "status"}
        }
      }

      {:ok, result, 2} = MCP.handle_message(session, params)

      assert result["content"]
      [content] = result["content"]
      assert content["type"] == "text"

      decoded = Jason.decode!(content["text"])
      # Status may be "ok" or "degraded" depending on which services are available
      assert decoded["status"] in ["ok", "degraded"]
    end

    test "handles ping request", %{session: session} do
      params = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "ping"
      }

      {:ok, result, 3} = MCP.handle_message(session, params)
      assert result == %{}
    end

    test "handles resources/list request", %{session: session} do
      params = %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "resources/list"
      }

      {:ok, result, 4} = MCP.handle_message(session, params)
      assert is_list(result["resources"])
    end

    test "returns error for unknown method", %{session: session} do
      params = %{
        "jsonrpc" => "2.0",
        "id" => 5,
        "method" => "unknown/method"
      }

      {:error, :method_not_found, message, 5} = MCP.handle_message(session, params)
      assert message =~ "Unknown method"
    end

    test "returns error for invalid JSON-RPC", %{session: session} do
      params = %{
        "jsonrpc" => "1.0",
        "id" => 6,
        "method" => "tools/list"
      }

      {:error, :invalid_request, message} = MCP.handle_message(session, params)
      assert message =~ "jsonrpc version"
    end
  end

  describe "handle_message/2 - notification processing" do
    setup do
      ctx = Context.local()
      {:ok, _result, session} = MCP.initialize(ctx, %{"protocolVersion" => "2025-11-25"})

      on_exit(fn -> Session.terminate(session.id) end)

      {:ok, session: session}
    end

    test "handles notifications/initialized", %{session: session} do
      params = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      }

      result = MCP.handle_message(session, params)
      assert result == :ok
    end

    test "handles notifications/cancelled", %{session: session} do
      params = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => 123}
      }

      result = MCP.handle_message(session, params)
      assert result == :ok
    end

    test "unknown notifications return :ok", %{session: session} do
      params = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/unknown"
      }

      result = MCP.handle_message(session, params)
      assert result == :ok
    end
  end

  describe "handle_message/2 - batch requests" do
    setup do
      ctx = Context.local()
      {:ok, _result, session} = MCP.initialize(ctx, %{"protocolVersion" => "2025-11-25"})

      on_exit(fn -> Session.terminate(session.id) end)

      {:ok, session: session}
    end

    test "handles batch of requests", %{session: session} do
      params = [
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "ping"
        },
        %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/list"
        }
      ]

      {:ok, responses} = MCP.handle_message(session, params)

      assert length(responses) == 2

      ping_response = Enum.find(responses, &(&1["id"] == 1))
      assert ping_response["result"] == %{}

      list_response = Enum.find(responses, &(&1["id"] == 2))
      assert is_list(list_response["result"]["tools"])
    end

    test "batch with mixed requests and notifications", %{session: session} do
      params = [
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "ping"
        },
        %{
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized"
        }
      ]

      {:ok, responses} = MCP.handle_message(session, params)

      # Only requests generate responses, not notifications
      assert length(responses) == 1
      assert hd(responses)["id"] == 1
    end

    test "batch with error in one request", %{session: session} do
      params = [
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "ping"
        },
        %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "unknown/method"
        }
      ]

      {:ok, responses} = MCP.handle_message(session, params)

      assert length(responses) == 2

      ping_response = Enum.find(responses, &(&1["id"] == 1))
      assert ping_response["result"] == %{}

      error_response = Enum.find(responses, &(&1["id"] == 2))
      assert error_response["error"]["message"] =~ "Unknown method"
    end
  end

  describe "encode_result/2 and encode_error/3" do
    test "encode_result creates valid JSON-RPC response" do
      result = MCP.encode_result(42, %{"tools" => []})

      assert result["jsonrpc"] == "2.0"
      assert result["id"] == 42
      assert result["result"] == %{"tools" => []}
    end

    test "encode_error creates valid JSON-RPC error" do
      result = MCP.encode_error(42, :method_not_found, "Method not found")

      assert result["jsonrpc"] == "2.0"
      assert result["id"] == 42
      assert result["error"]["code"] == -32601
      assert result["error"]["message"] == "Method not found"
    end

    test "encode_error accepts numeric codes" do
      result = MCP.encode_error(42, -32000, "Custom error")

      assert result["error"]["code"] == -32000
    end
  end

  describe "protocol_version/0" do
    test "returns the supported protocol version" do
      assert MCP.protocol_version() == "2025-11-25"
    end
  end
end
