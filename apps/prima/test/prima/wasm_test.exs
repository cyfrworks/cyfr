# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.WasmTest do
  use ExUnit.Case, async: true

  alias Prima.Wasm

  # The smallest core module: the magic and version 1, and no section.
  @core_module <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>>

  # Valid Component Model binary (magic + component preamble)
  @valid_component <<0x00, 0x61, 0x73, 0x6D, 0x0D, 0x00, 0x01, 0x00>>

  # Tracked cargo-component output — the realest component fixtures there
  # are. The list-models formula is found at its newest shipped version
  # rather than pinned, so a release bump cannot leave this pointing at a
  # directory that no longer ships.
  @seed_formula [__DIR__, "../../../../seed/components/formulas/local/list-models/*/formula.wasm"]
                |> Path.join()
                |> Path.wildcard()
                |> Enum.sort_by(fn path ->
                  path
                  |> Path.split()
                  |> Enum.at(-2)
                  |> String.split(".")
                  |> Enum.map(&String.to_integer/1)
                end)
                |> List.last()
  @seed_catalyst Path.expand(
                   "../../../../seed/components/catalysts/local/http/1.1.3/catalyst.wasm",
                   __DIR__
                 )

  # A core module exporting a function named "run": the magic and
  # version 1, a type section of one () -> (), a function section of one
  # function of type 0, an export section naming it "run", and its empty
  # body.
  @core_module_with_export <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
                             <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
                             <<0x03, 0x02, 0x01, 0x00>> <>
                             <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
                             <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

  describe "validate/1" do
    test "validates Component Model binary" do
      {:ok, result} = Wasm.validate(@valid_component)

      assert result.valid == true
      assert result.size == 8
      assert String.starts_with?(result.digest, "sha256:")
      assert result.exports == []
      assert result.exports_complete == true
      assert result.suggested_type == :reagent
    end

    test "parses a real component's world exports and suggests its type" do
      # The seed binaries are tracked source and the realest fixtures there
      # are: cargo-component output, one world export each.
      for {path, export, type} <- [
            {@seed_formula, "cyfr:formula/run@0.1.0", :formula},
            {@seed_catalyst, "cyfr:catalyst/run@0.1.0", :catalyst}
          ] do
        {:ok, result} = Wasm.validate(File.read!(path))

        assert result.exports == [export]
        assert result.exports_complete == true
        assert result.suggested_type == type
      end
    end

    test "refuses a core module as one, whatever it exports, in a sentence the refusal answers" do
      for core <- [@core_module, @core_module_with_export] do
        assert {:error, {:core_module, message} = reason} = Wasm.validate(core)
        assert message =~ "core WebAssembly module, not a component"

        assert %Prima.Refusal{class: :invalid_argument, message: ^message} =
                 Prima.Refusal.classify(reason)
      end
    end

    test "rejects non-binary input" do
      assert {:error, :not_binary} = Wasm.validate(nil)
      assert {:error, :not_binary} = Wasm.validate(123)
      assert {:error, :not_binary} = Wasm.validate(%{})
    end

    test "rejects too small binary" do
      assert {:error, :too_small} = Wasm.validate(<<0, 1, 2, 3>>)
    end

    test "rejects invalid magic bytes" do
      invalid = <<0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00>>
      assert {:error, :invalid_magic_bytes} = Wasm.validate(invalid)
    end

    test "rejects unsupported version" do
      invalid = <<0x00, 0x61, 0x73, 0x6D, 0x02, 0x00, 0x00, 0x00>>
      assert {:error, {:unsupported_version, _}} = Wasm.validate(invalid)
    end

    test "rejects oversized binary" do
      result = Wasm.validate(String.duplicate("x", 100))
      assert {:error, :invalid_magic_bytes} = result
    end
  end

  describe "validate/2 — the declared type's world" do
    test "accepts a component that exports its declared world" do
      assert {:ok, _} = Wasm.validate(File.read!(@seed_catalyst), "catalyst")
      assert {:ok, _} = Wasm.validate(File.read!(@seed_formula), "formula")
    end

    test "refuses a component declared as a type whose world it does not export" do
      # The whole point: a mistyped artifact must be refused at
      # registration, before the executor resolves vault material and
      # builds a catalyst host surface around it.
      assert {:error, {:wrong_world, message}} =
               Wasm.validate(File.read!(@seed_formula), "catalyst")

      assert message =~ "cyfr:catalyst/run@0.1.0"
      assert message =~ "cyfr:formula/run@0.1.0"

      assert {:error, {:wrong_world, _}} =
               Wasm.validate(File.read!(@seed_catalyst), "reagent")
    end

    test "a component exporting nothing is refused for every executable type" do
      for type <- ~w(catalyst reagent formula) do
        assert {:error, {:wrong_world, message}} =
                 Wasm.validate(@valid_component, type)

        assert message =~ "exports nothing"
      end
    end

    test "an export section the parser cannot walk refuses, fail-closed" do
      # A component whose export section carries an ascribed extern type
      # (option byte 0x01) — this parser does not walk externdesc, so the
      # world cannot be verified and registration must refuse rather than
      # trust a partial answer.
      name = "cyfr:catalyst/run@0.1.0"

      # vec count 1, tag 0x00, name, sort instance (0x05), idx 0, opt 0x01
      export_section_body =
        <<1, 0x00, byte_size(name), name::binary, 0x05, 0, 0x01, 0xFF>>

      binary =
        @valid_component <>
          <<11, byte_size(export_section_body), export_section_body::binary>>

      # The world is asked before the features, so the refusal is the
      # world's; alone, the validator refuses the binary as no valid
      # component (its export names an instance that does not exist).
      assert {:error, {:unverifiable_exports, message}} =
               Wasm.validate(binary, "catalyst")

      assert {:error, {:component_invalid, _digest}} = Wasm.validate(binary)

      assert message =~ "could not be fully parsed"
    end

    test "a core module is refused as one for every type, before its world is asked" do
      for type <- ~w(catalyst reagent formula tincture) do
        assert {:error, {:core_module, _message}} =
                 Wasm.validate(@core_module_with_export, type)
      end
    end
  end
end
