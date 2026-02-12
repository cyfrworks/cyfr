defmodule Emissary.MCP.MessageTest do
  use ExUnit.Case, async: true

  alias Emissary.MCP.Message

  describe "decode/1" do
    test "decodes a valid request" do
      msg = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{"cursor" => nil}
      }

      assert {:ok, decoded} = Message.decode(msg)
      assert decoded.type == :request
      assert decoded.id == 1
      assert decoded.method == "tools/list"
      assert decoded.params == %{"cursor" => nil}
    end

    test "decodes a notification (no id)" do
      msg = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      }

      assert {:ok, decoded} = Message.decode(msg)
      assert decoded.type == :notification
      assert decoded.id == nil
      assert decoded.method == "notifications/initialized"
    end

    test "decodes a result response" do
      msg = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "result" => %{"tools" => []}
      }

      assert {:ok, decoded} = Message.decode(msg)
      assert decoded.type == :response
      assert decoded.id == 1
      assert decoded.result == %{"tools" => []}
    end

    test "decodes an error response" do
      msg = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "error" => %{"code" => -32600, "message" => "Invalid request"}
      }

      assert {:ok, decoded} = Message.decode(msg)
      assert decoded.type == :error
      assert decoded.id == 1
      assert decoded.error["code"] == -32600
    end

    test "decodes a batch of messages" do
      msgs = [
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"},
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      ]

      assert {:ok, decoded} = Message.decode(msgs)
      assert length(decoded) == 2
      assert Enum.at(decoded, 0).type == :request
      assert Enum.at(decoded, 1).type == :notification
    end

    test "returns error for missing jsonrpc field" do
      msg = %{"id" => 1, "method" => "test"}

      assert {:error, :invalid_request, _} = Message.decode(msg)
    end

    test "returns error for unsupported version" do
      msg = %{"jsonrpc" => "1.0", "id" => 1, "method" => "test"}

      assert {:error, :invalid_request, message} = Message.decode(msg)
      assert message =~ "Unsupported jsonrpc version"
    end
  end

  describe "encode_result/2" do
    test "encodes a successful response" do
      result = Message.encode_result(1, %{"tools" => []})

      assert result["jsonrpc"] == "2.0"
      assert result["id"] == 1
      assert result["result"] == %{"tools" => []}
      refute Map.has_key?(result, "error")
    end
  end

  describe "encode_error/4" do
    test "encodes an error with atom code" do
      result = Message.encode_error(1, :method_not_found, "Unknown method")

      assert result["jsonrpc"] == "2.0"
      assert result["id"] == 1
      assert result["error"]["code"] == -32601
      assert result["error"]["message"] == "Unknown method"
    end

    test "encodes an error with integer code" do
      result = Message.encode_error(1, -33000, "Auth error")

      assert result["error"]["code"] == -33000
      assert result["error"]["message"] == "Auth error"
    end

    test "includes data when provided" do
      result = Message.encode_error(1, :internal_error, "Oops", %{detail: "stack trace"})

      assert result["error"]["data"] == %{detail: "stack trace"}
    end
  end

  describe "encode_notification/2" do
    test "encodes a notification without params" do
      result = Message.encode_notification("notifications/progress")

      assert result["jsonrpc"] == "2.0"
      assert result["method"] == "notifications/progress"
      refute Map.has_key?(result, "id")
      refute Map.has_key?(result, "params")
    end

    test "encodes a notification with params" do
      result = Message.encode_notification("notifications/progress", %{progress: 50})

      assert result["params"] == %{progress: 50}
    end
  end
end
