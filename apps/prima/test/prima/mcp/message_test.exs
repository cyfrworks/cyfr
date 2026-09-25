# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.MCP.MessageTest do
  @moduledoc """
  The MCP message codec: the four message types and the shapes it
  refuses, the encoders' envelopes, the code tables, and the code a
  refusal answers with over its data. A message carrying `method` is a
  request or a notification whatever else it carries, and a response
  carries a result or an error, never both — so no side reads a peer's
  request as the answer to its own.
  """
  use ExUnit.Case, async: true

  alias Prima.MCP.{Message, Protocol}

  doctest Prima.MCP.Message

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

    test "a message carrying method and id is a request, never a response" do
      msg = %{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => "sampling/createMessage",
        "result" => %{}
      }

      assert {:ok, %Message{type: :request, id: 7, result: nil}} = Message.decode(msg)
    end

    test "a message carrying method and no id is a notification, never a response" do
      msg = %{"jsonrpc" => "2.0", "method" => "notifications/message", "error" => %{}}

      assert {:ok, %Message{type: :notification, id: nil, error: nil}} = Message.decode(msg)
    end

    test "a response carrying both result and error is refused" do
      msg = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "result" => %{},
        "error" => %{"code" => -32603, "message" => "x"}
      }

      assert {:error, :invalid_request, message} = Message.decode(msg)
      assert message =~ "both result and error"
    end

    test "a response without an id is refused" do
      assert {:error, :invalid_request, "Missing required fields"} =
               Message.decode(%{"jsonrpc" => "2.0", "result" => %{}})
    end
  end

  describe "decode_json/1" do
    test "decodes one message from its text" do
      assert {:ok, %Message{type: :response, id: "a", result: %{"tools" => []}}} =
               Message.decode_json(~s({"jsonrpc":"2.0","id":"a","result":{"tools":[]}}))
    end

    test "text that is not JSON is a parse error" do
      assert {:error, :parse_error, _} = Message.decode_json(~s({"jsonrpc":))
      assert {:error, :parse_error, _} = Message.decode_json("")
    end

    test "JSON that is not one message object is an invalid request" do
      for text <- [~s([{"jsonrpc":"2.0","id":1,"method":"ping"}]), "1", ~s("x"), "null"],
          do: assert({:error, :invalid_request, _} = Message.decode_json(text))
    end

    test "a shape decode/1 refuses is refused the same way" do
      assert {:error, :invalid_request, message} =
               Message.decode_json(~s({"jsonrpc":"2.0","id":null,"method":"ping"}))

      assert message =~ "Request ID must not be null"
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

      assert result["_meta"][Protocol.meta_server_info_key()]["name"] == "CYFR"
    end

    test "merges into a handler's own _meta rather than replacing it" do
      result =
        Message.encode_result(1, %{"tools" => [], "_meta" => %{"run.cyfr/filtered" => true}})[
          "result"
        ]

      assert result["_meta"]["run.cyfr/filtered"] == true
      assert result["_meta"][Protocol.meta_server_info_key()]["name"] == "CYFR"
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

  describe "encode_request/3" do
    test "encodes a plain JSON-RPC request, no envelope stamping" do
      assert Message.encode_request(3, "tools/list") ==
               %{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/list"}

      assert Message.encode_request(4, "tools/call", %{"name" => "x"})["params"] ==
               %{"name" => "x"}
    end

    test "what it encodes decodes back as a request" do
      encoded = Message.encode_request("r1", "tools/call", %{"name" => "x"})

      assert {:ok, %Message{type: :request, id: "r1", method: "tools/call"}} =
               Message.decode(encoded)
    end
  end

  describe "error codes" do
    test "names resolve to their codes, standard and CYFR alike" do
      assert Message.error_code(:parse_error) == -32700
      assert Message.error_code(:header_mismatch) == -32020
      assert Message.error_code(:unsupported_protocol_version) == -32022
      assert Message.error_code(:auth_required) == -33001
      assert Message.error_code(:not_owner) == -33102
    end

    test "an unknown name is an internal error" do
      assert Message.error_code(:no_such_code) == -32603
      assert Message.encode_error(1, :no_such_code, "x")["error"]["code"] == -32603
    end

    test "code?/1 knows exactly the table names" do
      assert Message.code?(:invalid_params)
      assert Message.code?(:consent_conflict)
      refute Message.code?(:no_such_code)
      refute Message.code?("invalid_params")
    end

    test "the CYFR codes sit outside the JSON-RPC and MCP reserved ranges" do
      for {_name, code} <- Message.cyfr_error_codes(),
          do: assert(code in -33_999..-33_000//1)
    end
  end

  describe "refusal_code/3 over data" do
    defp refusal(class, reason), do: %Prima.Refusal{class: class, reason: reason, message: "m"}

    test "every refusal class answers with a code from the tables" do
      for class <- Prima.Refusal.classes(), where <- [:tools_call, :resources_read, :transport] do
        code = Message.refusal_code(refusal(class, :x), where, nil)
        assert Message.code?(code), "#{class} at #{where} answers #{inspect(code)}"
      end
    end

    test "an absent resource answers with the MCP resource code only on resources/read" do
      assert Message.class_code(:not_found, :resources_read) == :resource_not_found
      assert Message.class_code(:not_found, :tools_call) == :invalid_params
      assert Message.class_code(:not_found, :transport) == :invalid_params
    end

    test "the override outranks the consent signal and the class" do
      signal = refusal(:consent_required, {:consent_conflict, %{}})
      assert Message.refusal_code(signal, :tools_call, :auth_required) == :auth_required

      assert Message.refusal_code(refusal(:forbidden, :x), :tools_call, :auth_invalid) ==
               :auth_invalid
    end

    test "a consent signal answers with its own tag" do
      for tag <- Prima.ConsentSignal.tags() do
        assert Message.refusal_code(refusal(:consent_required, {tag, %{}}), :tools_call, nil) ==
                 tag
      end
    end

    test "without an override the class answers" do
      assert Message.refusal_code(refusal(:forbidden, :x), :tools_call, nil) ==
               :insufficient_permissions
    end
  end
end
