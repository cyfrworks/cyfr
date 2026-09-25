# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

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

    test "returns error for missing jsonrpc field" do
      msg = %{"id" => 1, "method" => "test"}

      assert {:error, :invalid_request, _} = Message.decode(msg)
    end

    test "returns error for unsupported version" do
      msg = %{"jsonrpc" => "1.0", "id" => 1, "method" => "test"}

      assert {:error, :invalid_request, message} = Message.decode(msg)
      assert message =~ "Unsupported jsonrpc version"
    end

    test "rejects null request ID" do
      msg = %{"jsonrpc" => "2.0", "id" => nil, "method" => "ping"}

      assert {:error, :invalid_request, message} = Message.decode(msg)
      assert message =~ "Request ID must not be null"
    end

    test "rejects null response ID" do
      msg = %{"jsonrpc" => "2.0", "id" => nil, "result" => %{}}

      assert {:error, :invalid_request, message} = Message.decode(msg)
      assert message =~ "Response ID must not be null"
    end

    test "rejects null error response ID" do
      msg = %{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => -32600, "message" => "err"}}

      assert {:error, :invalid_request, message} = Message.decode(msg)
      assert message =~ "Error response ID must not be null"
    end

    test "accepts string request ID" do
      msg = %{"jsonrpc" => "2.0", "id" => "abc-123", "method" => "ping"}

      assert {:ok, decoded} = Message.decode(msg)
      assert decoded.type == :request
      assert decoded.id == "abc-123"
    end

    test "rejects non-string method (integer)" do
      msg = %{"jsonrpc" => "2.0", "id" => 1, "method" => 42}

      assert {:error, :invalid_request, message} = Message.decode(msg)
      assert message =~ "Method must be a string"
    end

    test "rejects non-string method (list)" do
      msg = %{"jsonrpc" => "2.0", "id" => 1, "method" => ["tools", "list"]}

      assert {:error, :invalid_request, message} = Message.decode(msg)
      assert message =~ "Method must be a string"
    end

    test "rejects non-string method in notification" do
      msg = %{"jsonrpc" => "2.0", "method" => 123}

      assert {:error, :invalid_request, message} = Message.decode(msg)
      assert message =~ "Method must be a string"
    end
  end

  describe "encode_result/3" do
    test "encodes a successful response" do
      result = Message.encode_result(1, %{"tools" => []})

      assert result["jsonrpc"] == "2.0"
      assert result["id"] == 1
      assert result["result"]["tools"] == []
      refute Map.has_key?(result, "error")
    end

    # Two things every result must carry. They are stamped here rather than in
    # each handler because a result that reaches the wire without a `resultType`
    # is invalid to a conforming client, and no handler should have to remember.
    test "stamps resultType and the server identity" do
      result = Message.encode_result(1, %{"tools" => []})["result"]

      assert result["resultType"] == "complete"

      assert result["_meta"][Emissary.MCP.Protocol.meta_server_info_key()]["name"] == "CYFR"
    end

    test "merges into a handler's own _meta rather than replacing it" do
      result =
        Message.encode_result(1, %{"tools" => [], "_meta" => %{"run.cyfr/filtered" => true}})[
          "result"
        ]

      assert result["_meta"]["run.cyfr/filtered"] == true
      assert result["_meta"][Emissary.MCP.Protocol.meta_server_info_key()]["name"] == "CYFR"
    end

    test "input_required is expressible — the multi-round-trip half of the vocabulary" do
      result = Message.encode_result(1, %{}, :input_required)["result"]

      assert result["resultType"] == "input_required"
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

  describe "refusal_code/2" do
    defp code(reason, where \\ :tools_call),
      do:
        reason |> Grimoire.Error.classify() |> Message.refusal_code(where) |> Message.error_code()

    test "each class answers with its code" do
      assert code({:invalid_argument, "x"}) == -32602
      assert code({:not_found, "component", "x"}, :resources_read) == -32002
      assert code({:not_found, "component", "x"}, :tools_call) == -32602
      assert code(:unauthenticated) == -33001
      assert code({:missing_permission, :execute}) == -33004
      assert code(:no_agent) == -33501
      assert code({:consent_required, %{}}) == -33502
      assert code(:rate_limited) == -33304
      assert code({:cancelled, "stopped"}) == -33305
      assert code({:conflict, "moved"}) == -33101
      assert code(:control_plane_lost) == -33102
      assert code(:database_error) == -33103
      assert code({:corrupt, {:digest, "The artifact"}}) == -33104
      assert code({:timeout, "slow"}) == -33105
      assert code(:outcome_unknown) == -33106
      assert code({:exit, "Tool x exited unexpectedly"}) == -33100
    end

    test "a store the authentication provider could not reach is unavailable, never auth_invalid" do
      assert code(:auth_provider_error) == -33103
    end

    test "the rows that answered with another code keep it" do
      for reason <- [:invalid_bearer, :invalid_api_key, :api_key_revoked],
          do: assert(code(reason) == -33002)

      assert code({:authorization_required, "grant expired"}) == -33001
    end

    test "the authorization rows without an override answer with their class's code" do
      # internal
      assert code(:malformed_record) == -33100
      assert code(:untagged_tenant_resource) == -33100
      assert code({:malformed_resource, :execution}) == -33100
      # unauthenticated
      assert code({:consent_class_required, :not_authenticated}) == -33001
      assert code(:missing_token) == -33001
    end

    test "a consent signal answers with its own tag's code" do
      assert code({:consent_conflict, %{}}) == -33503
      assert code({:restart_required, %{}}) == -33504
      assert code({:setup_required, %{}}) == -33501
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
