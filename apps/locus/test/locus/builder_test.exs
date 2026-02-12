defmodule Locus.BuilderTest do
  use ExUnit.Case, async: true

  alias Locus.Builder

  # ============================================================================
  # Toolchain Detection
  # ============================================================================

  describe "toolchain_available?/1" do
    test "returns boolean for :go" do
      assert is_boolean(Builder.toolchain_available?(:go))
    end

    test "returns boolean for :js" do
      assert is_boolean(Builder.toolchain_available?(:js))
    end

    test "returns false for unknown language" do
      refute Builder.toolchain_available?(:python)
      refute Builder.toolchain_available?(:rust)
    end
  end

  describe "available_toolchains/0" do
    test "returns map with go and js keys" do
      toolchains = Builder.available_toolchains()

      assert is_map(toolchains)
      assert Map.has_key?(toolchains, :go)
      assert Map.has_key?(toolchains, :js)

      assert is_boolean(toolchains.go.available)
      assert is_binary(toolchains.go.command)
      assert is_boolean(toolchains.js.available)
      assert is_binary(toolchains.js.command)
    end
  end

  # ============================================================================
  # Compile Validation
  # ============================================================================

  describe "compile/3 - validation" do
    test "rejects empty source" do
      assert {:error, :empty_source} = Builder.compile("", :go)
      assert {:error, :empty_source} = Builder.compile(nil, :go)
    end

    test "rejects oversized source (> 1MB)" do
      big_source = String.duplicate("x", 1_024 * 1_024 + 1)
      assert {:error, {:source_too_large, _, _}} = Builder.compile(big_source, :go)
    end

    test "returns toolchain_not_found for unavailable language" do
      # :python is never available
      assert {:error, {:toolchain_not_found, :python}} = Builder.compile("some code", :python)
    end
  end

  # ============================================================================
  # Go Compilation
  # ============================================================================

  describe "compile/3 - Go compilation" do
    @tag :requires_tinygo
    test "compiles simple Go program to valid WASM" do
      if not Builder.toolchain_available?(:go) do
        IO.puts("Skipping: tinygo not installed")
      else
        source = """
        package main

        //export compute
        func compute(input int32) int32 { return input * 2 }

        func main() {}
        """

        assert {:ok, result} = Builder.compile(source, :go, target_type: :reagent)
        assert is_binary(result.wasm_bytes)
        assert byte_size(result.wasm_bytes) > 8
        assert String.starts_with?(result.digest, "sha256:")
        assert result.size > 0
        assert is_list(result.exports)
        assert result.language == "go"
        assert result.target_type == "reagent"
      end
    end

    @tag :requires_tinygo
    test "returns compilation error for invalid Go source" do
      if not Builder.toolchain_available?(:go) do
        IO.puts("Skipping: tinygo not installed")
      else
        source = "this is not valid go code at all!!"

        assert {:error, {:compilation_failed, _exit_code, _output}} =
                 Builder.compile(source, :go)
      end
    end
  end

  # ============================================================================
  # JS Compilation
  # ============================================================================

  describe "compile/3 - JS compilation" do
    @tag :requires_javy
    test "compiles simple JS program to valid WASM" do
      if not Builder.toolchain_available?(:js) do
        IO.puts("Skipping: javy not installed")
      else
        source = """
        function compute(input) { return input * 2; }
        compute(21);
        """

        assert {:ok, result} = Builder.compile(source, :js, target_type: :reagent)
        assert is_binary(result.wasm_bytes)
        assert byte_size(result.wasm_bytes) > 8
        assert String.starts_with?(result.digest, "sha256:")
        assert result.language == "js"
      end
    end
  end
end
