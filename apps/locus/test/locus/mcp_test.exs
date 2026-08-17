# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.MCPTest do
  use ExUnit.Case, async: true

  alias Locus.MCP

  # Minimal WASM binary (valid magic + version, empty module)
  @valid_wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>>

  defp local_ctx do
    Sanctum.TestContext.local()
  end

  # ============================================================================
  # Tools
  # ============================================================================

  describe "tools/0" do
    test "returns build tool with correct schema" do
      [tool] = MCP.tools()

      assert tool.name == "build"
      assert tool.title == "Build"
      assert is_binary(tool.description)

      schema = tool.input_schema

      assert schema["properties"]["action"]["enum"] == [
               "compile",
               "validate",
               "toolchains",
               "status"
             ]

      assert schema["properties"]["reference"]["type"] == "string"
      assert schema["properties"]["wasm_base64"]["type"] == "string"
      assert schema["required"] == ["action"]
    end
  end

  describe "resources/0" do
    test "returns empty list" do
      assert MCP.resources() == []
    end
  end

  # ============================================================================
  # build.toolchains
  # ============================================================================

  describe "handle build.toolchains" do
    test "returns available toolchain info" do
      assert {:ok, result} = MCP.handle("build", local_ctx(), %{"action" => "toolchains"})
      assert is_map(result.toolchains)
      assert Map.has_key?(result.toolchains, :rust)
      assert is_boolean(result.toolchains.rust.available)
    end

    test "includes javascript toolchain" do
      assert {:ok, result} = MCP.handle("build", local_ctx(), %{"action" => "toolchains"})
      assert Map.has_key?(result.toolchains, :javascript)
      assert is_boolean(result.toolchains.javascript.available)
      assert result.toolchains.javascript.command == "npm"
    end
  end

  # ============================================================================
  # build.validate
  # ============================================================================

  describe "handle build.validate" do
    test "validates valid WASM bytes" do
      wasm_b64 = Base.encode64(@valid_wasm)

      assert {:ok, result} =
               MCP.handle("build", local_ctx(), %{
                 "action" => "validate",
                 "wasm_base64" => wasm_b64
               })

      assert result.valid == true
      assert String.starts_with?(result.digest, "sha256:")
      assert result.size == 8
      assert is_list(result.exports)
      assert is_binary(result.suggested_type)
    end

    test "rejects invalid bytes" do
      bad_b64 = Base.encode64("not wasm")

      assert {:ok, result} =
               MCP.handle("build", local_ctx(), %{
                 "action" => "validate",
                 "wasm_base64" => bad_b64
               })

      assert result.valid == false
      assert is_binary(result.reason)
    end

    test "returns error for invalid base64" do
      assert {:error, msg} =
               MCP.handle("build", local_ctx(), %{
                 "action" => "validate",
                 "wasm_base64" => "!!!notbase64!!!"
               })

      assert msg =~ "base64"
    end

    test "returns error when wasm_base64 missing" do
      assert {:error, msg} = MCP.handle("build", local_ctx(), %{"action" => "validate"})
      assert msg =~ "wasm_base64"
    end
  end

  # ============================================================================
  # build.compile (reference-based)
  # ============================================================================

  describe "handle build.compile" do
    test "returns error when reference is missing" do
      assert {:error, msg} = MCP.handle("build", local_ctx(), %{"action" => "compile"})
      assert msg =~ "reference"
    end

    test "returns error for invalid reference format" do
      assert {:error, msg} =
               MCP.handle("build", local_ctx(), %{
                 "action" => "compile",
                 "reference" => "not-a-ref"
               })

      assert msg =~ "Invalid" or msg =~ "Source not found"
    end

    test "returns error when source file doesn't exist" do
      assert {:error, msg} =
               MCP.handle("build", local_ctx(), %{
                 "action" => "compile",
                 "reference" => "reagent:local.nonexistent:0.1.0"
               })

      assert msg =~ "Source not found" or msg =~ "lib.rs"
    end

    test "returns error for tincture without package.json" do
      assert {:error, msg} =
               MCP.handle("build", local_ctx(), %{
                 "action" => "compile",
                 "reference" => "tincture:local.nonexistent:0.1.0"
               })

      assert msg =~ "package.json" or msg =~ "Vanilla tinctures"
    end

    test "accepts tincture type in reference" do
      # Should fail at source lookup, not at type validation
      assert {:error, msg} =
               MCP.handle("build", local_ctx(), %{
                 "action" => "compile",
                 "reference" => "tincture:local.test:0.1.0"
               })

      refute msg =~ "Invalid component type"
    end
  end

  # ============================================================================
  # Invalid / Unknown
  # ============================================================================

  describe "handle - invalid action" do
    test "returns error for unknown action" do
      assert {:error, msg} = MCP.handle("build", local_ctx(), %{"action" => "destroy"})
      assert msg =~ "Invalid build action"
    end

    test "returns error for missing action" do
      assert {:error, msg} = MCP.handle("build", local_ctx(), %{})
      assert msg =~ "action"
    end

    test "returns error for unknown tool" do
      assert {:error, msg} = MCP.handle("unknown", local_ctx(), %{"action" => "list"})
      assert msg =~ "Unknown tool"
    end
  end
end
