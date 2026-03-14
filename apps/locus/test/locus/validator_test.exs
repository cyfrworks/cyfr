defmodule Locus.ValidatorTest do
  use ExUnit.Case, async: true

  alias Locus.Validator

  # Valid minimal WASM binary (magic + version)
  @valid_wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>>

  describe "delegation smoke test" do
    test "validate/1 delegates to Compendium.WasmValidator" do
      {:ok, result} = Validator.validate(@valid_wasm)
      assert result.valid == true
      assert result.format == :core_module
    end

    test "quick_check/1 delegates" do
      assert :ok = Validator.quick_check(@valid_wasm)
    end

    test "compute_digest/1 delegates" do
      digest = Validator.compute_digest(@valid_wasm)
      assert String.starts_with?(digest, "sha256:")
    end

    test "suggest_type/1 delegates" do
      assert :reagent = Validator.suggest_type(["run"])
      assert :formula = Validator.suggest_type(["execute"])
    end

    test "extract_exports/1 delegates" do
      {:ok, exports} = Validator.extract_exports(@valid_wasm)
      assert is_list(exports)
    end
  end
end
