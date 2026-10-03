# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Builds.ProviderTest do
  # The builds service is application configuration and the scripted
  # builder one named process.
  use ExUnit.Case, async: false

  alias Compendium.Builds.Provider
  alias Cyfr.Test.ScriptedBuilder

  # Minimal WASM binary (valid magic + version, empty module)
  @valid_wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>>

  # Builds are on, against a builder that would refuse any build it was
  # asked for: every refusal below is made here, before one is.
  setup do
    ScriptedBuilder.start!()
    :ok
  end

  defp local_ctx do
    Sanctum.TestContext.local()
  end

  # ============================================================================
  # Tools
  # ============================================================================

  describe "tools/0" do
    test "returns build tool with correct schema" do
      [tool] = Provider.tools()

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

      # One flat object: every action's arguments are properties, and an
      # argument only some actions declare says which.
      assert schema["properties"]["reference"]["type"] == "string"
      assert schema["properties"]["reference"]["description"] =~ "Actions: compile"
      assert schema["properties"]["wasm_base64"]["type"] == "string"
      assert schema["required"] == ["action"]
      refute Map.has_key?(schema, "oneOf")

      # Each action's own requirement lives on its declaration.
      compile = Enum.find(tool.operations, &(&1.action == "compile"))
      validate = Enum.find(tool.operations, &(&1.action == "validate"))
      assert Enum.any?(compile.args, &(&1.name == "reference" and &1.required))
      assert Enum.any?(validate.args, &(&1.name == "wasm_base64" and &1.required))
    end
  end

  # ============================================================================
  # build.toolchains
  # ============================================================================

  describe "handle build.toolchains" do
    test "returns available toolchain info" do
      assert {:ok, result} = Provider.handle("build", local_ctx(), %{"action" => "toolchains"})
      assert is_map(result.toolchains)
      assert Map.has_key?(result.toolchains, :rust)
      assert is_boolean(result.toolchains.rust.available)
    end

    test "includes javascript toolchain" do
      assert {:ok, result} = Provider.handle("build", local_ctx(), %{"action" => "toolchains"})
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
               Provider.handle("build", local_ctx(), %{
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
               Provider.handle("build", local_ctx(), %{
                 "action" => "validate",
                 "wasm_base64" => bad_b64
               })

      assert result.valid == false
      assert is_binary(result.reason)
    end

    test "returns error for invalid base64" do
      assert {:error, msg} =
               Provider.handle("build", local_ctx(), %{
                 "action" => "validate",
                 "wasm_base64" => "!!!notbase64!!!"
               })

      assert err_msg(msg) =~ "base64"
    end

    test "returns error when wasm_base64 missing" do
      assert {:error, msg} = Provider.handle("build", local_ctx(), %{"action" => "validate"})
      assert err_msg(msg) =~ "wasm_base64"
    end
  end

  # ============================================================================
  # build.compile (reference-based)
  # ============================================================================

  describe "handle build.compile" do
    test "returns error when reference is missing" do
      assert {:error, msg} = Provider.handle("build", local_ctx(), %{"action" => "compile"})
      assert err_msg(msg) =~ "reference"
    end

    test "returns error for invalid reference format" do
      assert {:error, msg} =
               Provider.handle("build", local_ctx(), %{
                 "action" => "compile",
                 "reference" => "not-a-ref"
               })

      assert err_msg(msg) =~ "Invalid" or err_msg(msg) =~ "Source not found"
    end

    test "returns error when source file doesn't exist" do
      assert {:error, msg} =
               Provider.handle("build", local_ctx(), %{
                 "action" => "compile",
                 "reference" => "reagent:local.nonexistent:0.1.0"
               })

      assert err_msg(msg) =~ "Source not found" or err_msg(msg) =~ "lib.rs"
    end

    test "returns error for tincture without package.json" do
      assert {:error, msg} =
               Provider.handle("build", local_ctx(), %{
                 "action" => "compile",
                 "reference" => "tincture:local.nonexistent:0.1.0"
               })

      assert err_msg(msg) =~ "package.json" or err_msg(msg) =~ "Vanilla tinctures"
    end

    test "refuses a non-local namespace instead of renamespacing it" do
      # `catalyst:acme.foo` would resolve acme's version and then compile
      # into local/foo — a different component. The namespace policy refuses.
      assert {:error, msg} =
               Provider.handle("build", local_ctx(), %{
                 "action" => "compile",
                 "reference" => "catalyst:acme.foo:1.0.0"
               })

      assert err_msg(msg) =~ "local namespace"
      assert err_msg(msg) =~ "acme"
    end

    test "a reference this server refuses is refused before the builder is asked for anything" do
      for reference <- [
            "not-a-ref",
            "reagent:local.nonexistent:0.1.0",
            "tincture:local.nonexistent:0.1.0",
            "catalyst:acme.foo:1.0.0"
          ] do
        assert {:error, _} =
                 Provider.handle("build", local_ctx(), %{
                   "action" => "compile",
                   "reference" => reference
                 })
      end

      assert ScriptedBuilder.requests() == []
    end

    test "accepts tincture type in reference" do
      # Should fail at source lookup, not at type validation
      assert {:error, msg} =
               Provider.handle("build", local_ctx(), %{
                 "action" => "compile",
                 "reference" => "tincture:local.test:0.1.0"
               })

      refute err_msg(msg) =~ "Invalid component type"
    end
  end

  # ============================================================================
  # Invalid / Unknown
  # ============================================================================

  describe "handle - invalid action" do
    test "returns error for unknown action" do
      assert {:error, msg} = Provider.handle("build", local_ctx(), %{"action" => "destroy"})
      assert err_msg(msg) =~ "Invalid build action"
    end

    test "returns error for missing action" do
      assert {:error, msg} = Provider.handle("build", local_ctx(), %{})
      assert err_msg(msg) =~ "action"
    end

    test "returns error for unknown tool" do
      assert {:error, msg} = Provider.handle("unknown", local_ctx(), %{"action" => "list"})
      assert err_msg(msg) =~ "Unknown tool"
    end
  end

  # Providers answer typed reasons now where the class is clear; the shared
  # renderer is the one spelling of every sentence, so tests assert through
  # it — a reason it cannot render is itself a failure. Plain strings pass
  # through unchanged.
  defp err_msg(reason) do
    Grimoire.Error.render(reason) ||
      flunk("unrenderable refusal: #{inspect(reason)}")
  end
end
