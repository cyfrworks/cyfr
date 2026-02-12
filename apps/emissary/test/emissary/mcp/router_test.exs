defmodule Emissary.MCP.RouterTest do
  use ExUnit.Case, async: true

  alias Emissary.MCP.{Message, Router, Session}
  alias Sanctum.Context

  setup do
    ctx = Context.local()
    {:ok, session} = Session.create(ctx)

    on_exit(fn ->
      Session.terminate(session.id)
    end)

    {:ok, session: session, context: ctx}
  end

  describe "protocol_version/0" do
    test "returns the supported protocol version" do
      assert Router.protocol_version() == "2025-11-25"
    end
  end

  describe "dispatch/2 with initialize" do
    test "returns success for compatible version", %{session: session} do
      msg = %Message{
        type: :request,
        id: 1,
        method: "initialize",
        params: %{"protocolVersion" => "2025-11-25"}
      }

      assert {:ok, result} = Router.dispatch(session, msg)
      assert result["protocolVersion"] == "2025-11-25"
      assert result["serverInfo"]["name"] == "CYFR"
      assert is_map(result["capabilities"])
      assert is_binary(result["instructions"])
    end

    test "returns error for incompatible version", %{session: session} do
      msg = %Message{
        type: :request,
        id: 1,
        method: "initialize",
        params: %{"protocolVersion" => "1999-01-01"}
      }

      assert {:error, :invalid_protocol, message} = Router.dispatch(session, msg)
      assert message =~ "Unsupported protocol version"
    end
  end

  describe "dispatch/2 with ping" do
    test "returns empty object", %{session: session} do
      msg = %Message{
        type: :request,
        id: 2,
        method: "ping",
        params: nil
      }

      assert {:ok, result} = Router.dispatch(session, msg)
      assert result == %{}
    end
  end

  describe "dispatch/2 with tools/list" do
    test "delegates to ToolRegistry and returns tools list", %{session: session} do
      msg = %Message{
        type: :request,
        id: 3,
        method: "tools/list",
        params: nil
      }

      assert {:ok, result} = Router.dispatch(session, msg)
      assert is_list(result["tools"])
    end
  end

  describe "dispatch/2 with tools/call" do
    test "delegates to ToolRegistry for valid tool", %{session: session} do
      msg = %Message{
        type: :request,
        id: 4,
        method: "tools/call",
        params: %{
          "name" => "system",
          "arguments" => %{"action" => "status"}
        }
      }

      assert {:ok, result} = Router.dispatch(session, msg)
      assert is_list(result["content"])
      [content] = result["content"]
      assert content["type"] == "text"
    end

    test "returns error result for unknown tool", %{session: session} do
      msg = %Message{
        type: :request,
        id: 5,
        method: "tools/call",
        params: %{
          "name" => "nonexistent/tool",
          "arguments" => %{}
        }
      }

      assert {:ok, result} = Router.dispatch(session, msg)
      assert result["isError"] == true
      [content] = result["content"]
      assert content["text"] =~ "Unknown tool"
    end

    test "handles missing arguments as empty map", %{session: session} do
      msg = %Message{
        type: :request,
        id: 6,
        method: "tools/call",
        params: %{
          "name" => "session",
          "arguments" => nil
        }
      }

      # Should not crash, but might return error depending on tool
      result = Router.dispatch(session, msg)
      assert match?({:ok, _}, result)
    end
  end

  describe "dispatch/2 with resources/list" do
    test "delegates to ResourceRegistry and returns resources list", %{session: session} do
      msg = %Message{
        type: :request,
        id: 7,
        method: "resources/list",
        params: nil
      }

      assert {:ok, result} = Router.dispatch(session, msg)
      assert is_list(result["resources"])
    end
  end

  describe "dispatch/2 with resources/read" do
    test "returns error for unknown URI scheme", %{session: session} do
      msg = %Message{
        type: :request,
        id: 8,
        method: "resources/read",
        params: %{"uri" => "unknown://resource/path"}
      }

      assert {:error, :invalid_params, message} = Router.dispatch(session, msg)
      assert message =~ "Failed to read resource"
    end
  end

  describe "dispatch/2 with unknown method" do
    test "returns method_not_found error", %{session: session} do
      msg = %Message{
        type: :request,
        id: 9,
        method: "unknown/method",
        params: nil
      }

      assert {:error, :method_not_found, message} = Router.dispatch(session, msg)
      assert message =~ "Unknown method"
    end
  end

  describe "dispatch/2 with notifications" do
    test "handles notifications/initialized", %{session: session} do
      msg = %Message{
        type: :notification,
        method: "notifications/initialized",
        params: nil
      }

      assert :ok = Router.dispatch(session, msg)
    end

    test "handles notifications/cancelled", %{session: session} do
      msg = %Message{
        type: :notification,
        method: "notifications/cancelled",
        params: %{"requestId" => 123}
      }

      assert :ok = Router.dispatch(session, msg)
    end

    test "handles unknown notification gracefully", %{session: session} do
      msg = %Message{
        type: :notification,
        method: "notifications/unknown",
        params: nil
      }

      # Should not crash, just logs warning
      assert :ok = Router.dispatch(session, msg)
    end
  end

  describe "dispatch/2 with unexpected message type" do
    test "returns error for response type", %{session: session} do
      msg = %Message{
        type: :response,
        id: 10,
        result: %{}
      }

      assert {:error, :invalid_request, message} = Router.dispatch(session, msg)
      assert message =~ "Unexpected message type"
    end

    test "returns error for error type", %{session: session} do
      msg = %Message{
        type: :error,
        id: 11,
        error: %{"code" => -32600, "message" => "Error"}
      }

      assert {:error, :invalid_request, message} = Router.dispatch(session, msg)
      assert message =~ "Unexpected message type"
    end
  end

  describe "handle_initialize/2" do
    test "creates session and returns result for compatible version", %{context: ctx} do
      params = %{"protocolVersion" => "2025-11-25"}

      assert {:ok, result, session} = Router.handle_initialize(ctx, params)
      assert result["protocolVersion"] == "2025-11-25"
      assert result["serverInfo"]["name"] == "CYFR"
      assert is_binary(session.id)
      assert String.starts_with?(session.id, "sess_")

      # Cleanup
      Session.terminate(session.id)
    end

    test "returns error for incompatible version", %{context: ctx} do
      params = %{"protocolVersion" => "1999-01-01"}

      assert {:error, :invalid_protocol, message} = Router.handle_initialize(ctx, params)
      assert message =~ "Unsupported protocol version"
    end
  end
end
