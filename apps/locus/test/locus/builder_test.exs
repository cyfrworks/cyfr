defmodule Locus.BuilderTest do
  use ExUnit.Case, async: true

  alias Locus.Builder

  # ============================================================================
  # Toolchain Detection
  # ============================================================================

  describe "toolchain_available?/1" do
    test "returns boolean for :rust" do
      assert is_boolean(Builder.toolchain_available?(:rust))
    end

    test "returns false for unknown language" do
      refute Builder.toolchain_available?(:python)
      refute Builder.toolchain_available?(:go)
      refute Builder.toolchain_available?(:js)
    end
  end

  describe "available_toolchains/0" do
    test "returns map with rust key" do
      toolchains = Builder.available_toolchains()

      assert is_map(toolchains)
      assert Map.has_key?(toolchains, :rust)

      assert is_boolean(toolchains.rust.available)
      assert is_binary(toolchains.rust.command)
      assert toolchains.rust.command == "cargo-component"
    end
  end

  # ============================================================================
  # Compile Validation
  # ============================================================================

  describe "compile/3 - validation" do
    test "rejects empty source" do
      assert {:error, :empty_source} = Builder.compile("", :rust)
      assert {:error, :empty_source} = Builder.compile(nil, :rust)
    end

    test "rejects oversized source (> 1MB)" do
      big_source = String.duplicate("x", 1_024 * 1_024 + 1)
      assert {:error, {:source_too_large, _, _}} = Builder.compile(big_source, :rust)
    end

    test "returns toolchain_not_found for unavailable language" do
      # :python is never available
      assert {:error, {:toolchain_not_found, :python}} = Builder.compile("some code", :python)
    end
  end

  # ============================================================================
  # Rust Compilation
  # ============================================================================

  describe "compile/3 - Rust compilation" do
    @tag :requires_cargo_component
    test "compiles simple Rust reagent to valid WASM" do
      if not Builder.toolchain_available?(:rust) do
        IO.puts("Skipping: cargo-component not installed")
      else
        source = """
        #[allow(warnings)]
        mod bindings;

        use bindings::exports::cyfr::reagent::compute::Guest;

        struct MyReagent;
        bindings::export!(MyReagent with_types_in bindings);

        impl Guest for MyReagent {
            fn compute(input: String) -> String {
                input
            }
        }
        """

        assert {:ok, result} = Builder.compile(source, :rust, target_type: :reagent)
        assert is_binary(result.wasm_bytes)
        assert byte_size(result.wasm_bytes) > 8
        assert String.starts_with?(result.digest, "sha256:")
        assert result.size > 0
        assert is_list(result.exports)
        assert result.language == "rust"
        assert result.target_type == "reagent"
      end
    end

    @tag :requires_cargo_component
    test "returns compilation error for invalid Rust source" do
      if not Builder.toolchain_available?(:rust) do
        IO.puts("Skipping: cargo-component not installed")
      else
        source = "this is not valid rust code at all!!"

        assert {:error, {:compilation_failed, _exit_code, _output}} =
                 Builder.compile(source, :rust)
      end
    end
  end
end
