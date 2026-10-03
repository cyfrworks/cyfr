# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.MCP.ProtocolTest do
  @moduledoc """
  The MCP protocol vocabulary: the revision and its acceptance, the
  headers a request carries and a response exposes, the `_meta` keys,
  the named subject a request's `Mcp-Name` mirrors, and the Base64
  sentinel a header value travels in when it cannot travel plain —
  encoded by one side and decoded by the other to the same value.
  """
  use ExUnit.Case, async: true

  alias Prima.MCP.Protocol

  describe "the revision" do
    test "the announced revision is the one supported" do
      assert Protocol.supported() == [Protocol.version()]
      assert Protocol.supported?(Protocol.version())
      refute Protocol.supported?("2025-03-26")
      refute Protocol.supported?(nil)
    end

    test "a request declares its revision in params._meta" do
      key = Protocol.meta_protocol_version_key()

      assert Protocol.declared_version(%{"params" => %{"_meta" => %{key => "v"}}}) == "v"
      assert Protocol.declared_version(%{"params" => %{"_meta" => %{key => 1}}}) == nil
      assert Protocol.declared_version(%{"params" => %{}}) == nil
    end

    test "the server identity names CYFR and its version" do
      assert Protocol.server_info() == %{"name" => "CYFR", "version" => Prima.Version.current()}
    end
  end

  describe "headers" do
    test "every request header is lower-cased and the version header is exposed" do
      headers = Protocol.request_headers()

      assert Protocol.protocol_version_header() in headers
      assert Protocol.method_header() in headers
      assert Protocol.name_header() in headers
      assert Enum.all?(headers, &(&1 == String.downcase(&1)))
      assert Protocol.protocol_version_header() in Protocol.exposed_headers()
    end

    test "the named subject is a tool's name or a resource's uri" do
      assert Protocol.named_subject(%{"method" => "tools/call", "params" => %{"name" => "t"}}) ==
               "t"

      assert Protocol.named_subject(%{"method" => "resources/read", "params" => %{"uri" => "u"}}) ==
               "u"

      assert Protocol.named_subject(%{"method" => "tools/list"}) == nil

      assert Protocol.named_subject(%{"method" => "tools/call", "params" => %{"name" => 1}}) ==
               nil
    end
  end

  describe "result types" do
    test "the vocabulary is closed" do
      assert Protocol.result_type(:complete) == "complete"
      assert Protocol.result_type(:input_required) == "input_required"
      assert_raise FunctionClauseError, fn -> Protocol.result_type(:partial) end
    end
  end

  describe "header values" do
    test "a plain visible-ASCII value travels as itself" do
      assert Protocol.encode_header_value("tools.fetch") == "tools.fetch"
      assert Protocol.decode_header_value("tools.fetch") == {:ok, "tools.fetch"}
    end

    test "a value that cannot travel plain goes in the Base64 sentinel and reads back" do
      for value <- ["", " padded ", "naïve", "line\nbreak", "tab\there", "=?base64?abc?="] do
        encoded = Protocol.encode_header_value(value)

        assert String.starts_with?(encoded, "=?base64?") and String.ends_with?(encoded, "?="),
               "#{inspect(value)} travelled as #{inspect(encoded)}"

        assert Protocol.decode_header_value(encoded) == {:ok, value}
      end
    end

    test "a sentinel whose payload is not Base64, or that does not close, is refused" do
      assert Protocol.decode_header_value("=?base64?***?=") == :error
      assert Protocol.decode_header_value("=?base64?YWJj") == :error
      assert Protocol.decode_header_value("=?base64?YWJj?=trailing") == :error
    end
  end
end
