# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

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
      assert {:error, :empty_source} = Builder.compile(%{}, :rust)
    end

    test "rejects source map without src/lib.rs" do
      assert {:error, :missing_lib_rs} =
               Builder.compile(%{"src/utils.rs" => "pub fn hello() {}"}, :rust)
    end

    test "rejects oversized source (total > 1MB)" do
      big = String.duplicate("x", 600_000)

      assert {:error, {:source_too_large, _, _}} =
               Builder.compile(%{"src/lib.rs" => big, "src/utils.rs" => big}, :rust)
    end

    test "returns toolchain_not_found for unavailable language" do
      # :python is never available
      assert {:error, {:toolchain_not_found, :python}} =
               Builder.compile(%{"src/lib.rs" => "some code"}, :python)
    end

    test "rejects a source key that traverses out of the build directory" do
      # Path.join neutralizes a leading `/` on the key; `..` is the live
      # escape — a key like this used to land the write outside the tmp dir.
      sources = %{
        "src/lib.rs" => "pub fn hello() {}",
        "../../../../tmp/escape.rs" => "pwned"
      }

      assert {:error, {:invalid_source_path, "../../../../tmp/escape.rs", reason}} =
               Builder.compile(sources, :rust)

      assert reason =~ "traversal"
    end

    test "nested relative keys are still accepted" do
      # The refusal is about `..`, not depth: validation must pass so the
      # (toolchain-gated) compile proceeds to its next check.
      sources = %{
        "src/lib.rs" => "pub fn hello() {}",
        "src/nested/deep/util.rs" => "pub fn util() {}"
      }

      result = Builder.compile(sources, :python)
      assert result == {:error, {:toolchain_not_found, :python}}
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
        source_files = %{
          "src/lib.rs" => """
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
        }

        assert {:ok, result} = Builder.compile(source_files, :rust, target_type: :reagent)
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
    test "compiles multi-file Rust reagent to valid WASM" do
      if not Builder.toolchain_available?(:rust) do
        IO.puts("Skipping: cargo-component not installed")
      else
        lib_rs = """
        #[allow(warnings)]
        mod bindings;
        mod utils;

        use bindings::exports::cyfr::reagent::compute::Guest;

        struct MyReagent;
        bindings::export!(MyReagent with_types_in bindings);

        impl Guest for MyReagent {
            fn compute(input: String) -> String {
                utils::echo(&input).to_string()
            }
        }
        """

        utils_rs = """
        pub fn echo(s: &str) -> &str {
            s
        }
        """

        source_files = %{
          "src/lib.rs" => lib_rs,
          "src/utils.rs" => utils_rs
        }

        assert {:ok, result} = Builder.compile(source_files, :rust, target_type: :reagent)
        assert is_binary(result.wasm_bytes)
        assert byte_size(result.wasm_bytes) > 8
        assert result.language == "rust"
        assert result.target_type == "reagent"
      end
    end

    @tag :requires_cargo_component
    test "returns compilation error for invalid Rust source" do
      if not Builder.toolchain_available?(:rust) do
        IO.puts("Skipping: cargo-component not installed")
      else
        source_files = %{"src/lib.rs" => "this is not valid rust code at all!!"}

        assert {:error, {:compilation_failed, _exit_code, _output}} =
                 Builder.compile(source_files, :rust)
      end
    end
  end

  # ============================================================================
  # JavaScript Toolchain
  # ============================================================================

  describe "toolchain_available?/1 - javascript" do
    test "returns boolean for :javascript" do
      assert is_boolean(Builder.toolchain_available?(:javascript))
    end
  end

  describe "available_toolchains/0 - javascript" do
    test "includes javascript key" do
      toolchains = Builder.available_toolchains()

      assert Map.has_key?(toolchains, :javascript)
      assert is_boolean(toolchains.javascript.available)
      assert toolchains.javascript.command == "npm"
    end
  end

  describe "compile/3 - javascript validation" do
    test "rejects empty source" do
      assert {:error, :empty_source} = Builder.compile(%{}, :javascript)
    end

    test "rejects source without package.json" do
      assert {:error, :missing_package_json} =
               Builder.compile(%{"src/main.jsx" => "export default function() {}"}, :javascript)
    end

    test "rejects oversized source" do
      big = String.duplicate("x", 600_000)

      assert {:error, {:source_too_large, _, _}} =
               Builder.compile(%{"package.json" => big, "src/app.jsx" => big}, :javascript)
    end
  end

  # ============================================================================
  # JavaScript Compilation
  # ============================================================================

  describe "compile/3 - JavaScript compilation" do
    @tag :requires_node
    test "compiles minimal React project" do
      if not Builder.toolchain_available?(:javascript) do
        IO.puts("Skipping: Node.js/npm not installed")
      else
        source_files = %{
          "package.json" =>
            Jason.encode!(%{
              name: "test-tincture",
              private: true,
              type: "module",
              scripts: %{build: "vite build"},
              dependencies: %{react: "^19.1.0", "react-dom": "^19.1.0"},
              devDependencies: %{"@vitejs/plugin-react": "^4.4.1", vite: "^6.3.5"}
            }),
          "vite.config.js" => """
          import { defineConfig } from "vite";
          import react from "@vitejs/plugin-react";
          export default defineConfig({ plugins: [react()], base: "./" });
          """,
          "index.html" => """
          <!DOCTYPE html>
          <html><body><div id="root"></div>
          <script type="module" src="/src/main.jsx"></script>
          </body></html>
          """,
          "src/main.jsx" => """
          import { createRoot } from "react-dom/client";
          createRoot(document.getElementById("root")).render(<div>test</div>);
          """
        }

        assert {:ok, result} =
                 Builder.compile(source_files, :javascript, target_type: :tincture)

        assert is_map(result.output_files)
        assert Map.has_key?(result.output_files, "index.html")
        assert String.starts_with?(result.digest, "sha256:")
        assert result.size > 0
        assert result.exports == []
        assert result.language == "javascript"
        assert result.target_type == "tincture"
      end
    end

    @tag :requires_node
    test "returns compilation error for invalid package.json" do
      if not Builder.toolchain_available?(:javascript) do
        IO.puts("Skipping: Node.js/npm not installed")
      else
        source_files = %{
          "package.json" =>
            Jason.encode!(%{
              name: "broken",
              private: true,
              scripts: %{build: "nonexistent-command-xyz"}
            })
        }

        assert {:error, {:compilation_failed, _exit_code, _output}} =
                 Builder.compile(source_files, :javascript, target_type: :tincture)
      end
    end
  end
end
