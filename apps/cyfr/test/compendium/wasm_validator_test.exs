# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.WasmValidatorTest do
  use ExUnit.Case, async: true

  alias Compendium.WasmValidator

  # Valid minimal WASM binary (magic + version + empty sections)
  # \0asm followed by version 1
  @valid_wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>>

  # Valid Component Model binary (magic + component preamble)
  @valid_component <<0x00, 0x61, 0x73, 0x6D, 0x0D, 0x00, 0x01, 0x00>>

  # Valid WASM with export section
  # This is a minimal WASM module that exports a function named "run"
  # magic + version
  # type section: 1 func type () -> ()
  # function section: 1 function, type 0
  # export section: "run" as func 0
  # code section: empty function body
  @wasm_with_export <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
                      <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
                      <<0x03, 0x02, 0x01, 0x00>> <>
                      <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
                      <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

  describe "validate/1" do
    test "validates minimal WASM binary" do
      {:ok, result} = WasmValidator.validate(@valid_wasm)

      assert result.valid == true
      assert result.size == 8
      assert String.starts_with?(result.digest, "sha256:")
      assert result.version == 1
      assert result.format == :core_module
    end

    test "validates Component Model binary" do
      {:ok, result} = WasmValidator.validate(@valid_component)

      assert result.valid == true
      assert result.size == 8
      assert String.starts_with?(result.digest, "sha256:")
      assert result.format == :component
      assert result.exports == []
      assert result.suggested_type == :reagent
    end

    test "validates WASM with exports" do
      {:ok, result} = WasmValidator.validate(@wasm_with_export)

      assert result.valid == true
      assert "run" in result.exports
    end

    test "detects reagent type for simple exports" do
      {:ok, result} = WasmValidator.validate(@wasm_with_export)

      assert result.suggested_type == :reagent
    end

    test "rejects non-binary input" do
      assert {:error, :not_binary} = WasmValidator.validate(nil)
      assert {:error, :not_binary} = WasmValidator.validate(123)
      assert {:error, :not_binary} = WasmValidator.validate(%{})
    end

    test "rejects too small binary" do
      assert {:error, :too_small} = WasmValidator.validate(<<0, 1, 2, 3>>)
    end

    test "rejects invalid magic bytes" do
      invalid = <<0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00>>
      assert {:error, :invalid_magic_bytes} = WasmValidator.validate(invalid)
    end

    test "rejects unsupported version" do
      invalid = <<0x00, 0x61, 0x73, 0x6D, 0x02, 0x00, 0x00, 0x00>>
      assert {:error, {:unsupported_version, _}} = WasmValidator.validate(invalid)
    end

    test "rejects oversized binary" do
      result = WasmValidator.validate(String.duplicate("x", 100))
      assert {:error, :invalid_magic_bytes} = result
    end
  end

  describe "quick_check/1" do
    test "passes valid WASM" do
      assert :ok = WasmValidator.quick_check(@valid_wasm)
    end

    test "rejects invalid magic bytes" do
      invalid = <<0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00>>
      assert {:error, :invalid_magic_bytes} = WasmValidator.quick_check(invalid)
    end

    test "rejects non-binary" do
      assert {:error, :not_binary} = WasmValidator.quick_check(nil)
    end
  end

  describe "compute_digest/1" do
    test "computes SHA-256 digest" do
      digest = WasmValidator.compute_digest(@valid_wasm)

      assert String.starts_with?(digest, "sha256:")
      # Hex encoded SHA-256 is 64 characters
      "sha256:" <> hash = digest
      assert byte_size(hash) == 64
    end

    test "produces consistent digest for same input" do
      digest1 = WasmValidator.compute_digest(@valid_wasm)
      digest2 = WasmValidator.compute_digest(@valid_wasm)

      assert digest1 == digest2
    end

    test "produces different digest for different input" do
      digest1 = WasmValidator.compute_digest(@valid_wasm)
      digest2 = WasmValidator.compute_digest(@wasm_with_export)

      assert digest1 != digest2
    end
  end

  describe "suggest_type/1" do
    test "suggests formula for execute export" do
      assert :formula = WasmValidator.suggest_type(["execute", "validate"])
    end

    test "suggests catalyst for http exports" do
      assert :catalyst = WasmValidator.suggest_type(["run", "http_request"])
      assert :catalyst = WasmValidator.suggest_type(["http_get"])
      assert :catalyst = WasmValidator.suggest_type(["socket_connect"])
    end

    test "suggests reagent for plain exports" do
      assert :reagent = WasmValidator.suggest_type(["run"])
      assert :reagent = WasmValidator.suggest_type(["run", "init"])
      assert :reagent = WasmValidator.suggest_type([])
    end
  end

  describe "extract_exports/1" do
    test "extracts exports from valid WASM" do
      {:ok, exports} = WasmValidator.extract_exports(@wasm_with_export)

      assert is_list(exports)
      assert "run" in exports
    end

    test "returns empty list for WASM without exports" do
      {:ok, exports} = WasmValidator.extract_exports(@valid_wasm)

      assert exports == []
    end

    test "handles malformed section headers gracefully" do
      malformed =
        <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
          <<0x07, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>

      assert {:error, :incomplete_leb128} = WasmValidator.extract_exports(malformed)
    end

    test "handles section with bad export entry gracefully" do
      malformed =
        <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
          <<0x07, 0x05, 0x01, 0xFF, 0xFF, 0xFF, 0xFF>>

      {:error, :export_entry_parse_failed} = WasmValidator.extract_exports(malformed)
    end

    test "handles truncated section gracefully" do
      truncated =
        <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
          <<0x07, 0x20>>

      {:error, {:section_truncated, 7, 32, 0}} = WasmValidator.extract_exports(truncated)
    end
  end
end
