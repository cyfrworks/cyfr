defmodule Locus.MCPTest do
  use ExUnit.Case, async: true

  alias Locus.MCP

  # Minimal WASM binary (valid magic + version, empty module)
  @valid_wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>>

  defp local_ctx do
    Sanctum.Context.local()
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
      assert schema["properties"]["action"]["enum"] == ["compile", "compile_and_save", "compile_and_publish", "validate", "toolchains"]
      assert schema["properties"]["source"]["type"] == "string"
      assert schema["properties"]["language"]["enum"] == ["go", "js"]
      assert schema["properties"]["target_type"]["enum"] == ["reagent", "catalyst", "formula"]
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
      assert Map.has_key?(result.toolchains, :go)
      assert Map.has_key?(result.toolchains, :js)
      assert is_boolean(result.toolchains.go.available)
      assert is_boolean(result.toolchains.js.available)
    end
  end

  # ============================================================================
  # build.validate
  # ============================================================================

  describe "handle build.validate" do
    test "validates valid WASM bytes" do
      wasm_b64 = Base.encode64(@valid_wasm)

      assert {:ok, result} = MCP.handle("build", local_ctx(), %{"action" => "validate", "wasm_base64" => wasm_b64})
      assert result.valid == true
      assert String.starts_with?(result.digest, "sha256:")
      assert result.size == 8
      assert is_list(result.exports)
      assert is_binary(result.suggested_type)
    end

    test "rejects invalid bytes" do
      bad_b64 = Base.encode64("not wasm")

      assert {:ok, result} = MCP.handle("build", local_ctx(), %{"action" => "validate", "wasm_base64" => bad_b64})
      assert result.valid == false
      assert is_binary(result.reason)
    end

    test "returns error for invalid base64" do
      assert {:error, msg} = MCP.handle("build", local_ctx(), %{"action" => "validate", "wasm_base64" => "!!!notbase64!!!"})
      assert msg =~ "base64"
    end

    test "returns error when wasm_base64 missing" do
      assert {:error, msg} = MCP.handle("build", local_ctx(), %{"action" => "validate"})
      assert msg =~ "wasm_base64"
    end
  end

  # ============================================================================
  # build.compile
  # ============================================================================

  describe "handle build.compile" do
    test "returns error when source is missing" do
      assert {:error, msg} = MCP.handle("build", local_ctx(), %{"action" => "compile", "language" => "go"})
      assert msg =~ "source"
    end

    test "returns error when language is missing" do
      assert {:error, msg} = MCP.handle("build", local_ctx(), %{"action" => "compile", "source" => "code"})
      assert msg =~ "language"
    end

    test "returns error for unsupported language" do
      assert {:error, msg} = MCP.handle("build", local_ctx(), %{"action" => "compile", "source" => "code", "language" => "python"})
      assert msg =~ "Unsupported language"
    end

    test "returns error when toolchain not available" do
      # Only run if the toolchain is NOT installed
      unless Locus.Builder.toolchain_available?(:go) do
        args = %{"action" => "compile", "source" => "package main\nfunc main() {}", "language" => "go"}
        assert {:error, msg} = MCP.handle("build", local_ctx(), args)
        assert msg =~ "Toolchain not found"
      end
    end

    @tag :requires_tinygo
    test "compiles Go source and returns wasm_base64" do
      if Locus.Builder.toolchain_available?(:go) do
        source = """
        package main

        //export compute
        func compute(input int32) int32 { return input * 2 }

        func main() {}
        """

        args = %{"action" => "compile", "source" => source, "language" => "go", "target_type" => "reagent"}
        assert {:ok, result} = MCP.handle("build", local_ctx(), args)
        assert result.status == "compiled"
        assert is_binary(result.wasm_base64)
        assert String.starts_with?(result.digest, "sha256:")
        assert result.size > 0
        assert result.language == "go"
        assert result.target_type == "reagent"

        # Verify the base64 decodes to valid WASM
        {:ok, bytes} = Base.decode64(result.wasm_base64)
        assert <<0x00, 0x61, 0x73, 0x6D, _rest::binary>> = bytes
      end
    end
  end

  # ============================================================================
  # build.compile_and_save
  # ============================================================================

  describe "handle build.compile_and_save" do
    test "returns error when source is missing" do
      assert {:error, msg} = MCP.handle("build", local_ctx(), %{"action" => "compile_and_save", "language" => "go"})
      assert msg =~ "source"
    end

    test "returns error when language is missing" do
      assert {:error, msg} = MCP.handle("build", local_ctx(), %{"action" => "compile_and_save", "source" => "code"})
      assert msg =~ "language"
    end

    @tag :requires_tinygo
    test "compiles Go source and saves WASM to local components directory" do
      if Locus.Builder.toolchain_available?(:go) do
        source = """
        package main

        //export compute
        func compute(input int32) int32 { return input * 2 }

        func main() {}
        """

        args = %{"action" => "compile_and_save", "source" => source, "language" => "go", "target_type" => "reagent"}
        assert {:ok, result} = MCP.handle("build", local_ctx(), args)
        assert result.status == "saved"
        assert %{"local" => path} = result.reference
        assert String.starts_with?(path, "components/reagents/agent/gen-")
        assert String.ends_with?(path, "/0.1.0/reagent.wasm")
        assert String.starts_with?(result.digest, "sha256:")
        assert result.size > 0
        assert result.language == "go"
        assert result.target_type == "reagent"

        # Verify file was written to disk
        absolute_path = Path.join(File.cwd!(), path)
        assert File.exists?(absolute_path)
        {:ok, bytes} = File.read(absolute_path)
        assert <<0x00, 0x61, 0x73, 0x6D, _rest::binary>> = bytes

        # Cleanup
        agent_dir = Path.join(File.cwd!(), Path.dirname(Path.dirname(path)))
        File.rm_rf!(agent_dir)
      end
    end
  end

  # ============================================================================
  # build.compile_and_publish
  # ============================================================================

  describe "handle build.compile_and_publish" do
    test "returns error when source is missing" do
      assert {:error, msg} = MCP.handle("build", local_ctx(), %{"action" => "compile_and_publish", "language" => "go"})
      assert msg =~ "source"
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
