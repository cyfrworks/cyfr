defmodule Opus.RuntimeTest do
  use ExUnit.Case, async: true

  @math_wasm_path Path.join(__DIR__, "../support/test_wasm/math.wasm")

  describe "call_function/4 (core module API)" do
    test "executes sum function from core WASM module" do
      wasm_bytes = File.read!(@math_wasm_path)
      assert {:ok, [8]} = Opus.Runtime.call_function(wasm_bytes, "sum", [5, 3])
    end

    test "executes add function from core WASM module" do
      wasm_bytes = File.read!(@math_wasm_path)
      assert {:ok, [15]} = Opus.Runtime.call_function(wasm_bytes, "add", [10, 5])
    end

    test "executes multiply function from core WASM module" do
      wasm_bytes = File.read!(@math_wasm_path)
      assert {:ok, [42]} = Opus.Runtime.call_function(wasm_bytes, "multiply", [6, 7])
    end

    test "returns error for non-existent function" do
      wasm_bytes = File.read!(@math_wasm_path)
      assert {:error, _reason} = Opus.Runtime.call_function(wasm_bytes, "nonexistent", [1, 2])
    end

    test "returns error for invalid WASM bytes" do
      assert {:error, _reason} = Opus.Runtime.call_function("not wasm", "sum", [1, 2])
    end
  end

  describe "call_function/4 with various inputs" do
    test "executes sum with a/b inputs" do
      wasm_bytes = File.read!(@math_wasm_path)
      assert {:ok, [13]} = Opus.Runtime.call_function(wasm_bytes, "sum", [8, 5])
    end

    test "executes multiply with x/y inputs" do
      wasm_bytes = File.read!(@math_wasm_path)
      assert {:ok, [24]} = Opus.Runtime.call_function(wasm_bytes, "multiply", [4, 6])
    end

    test "executes sum with various values" do
      wasm_bytes = File.read!(@math_wasm_path)
      assert {:ok, [100]} = Opus.Runtime.call_function(wasm_bytes, "sum", [60, 40])
    end

    test "executes multiply with various values" do
      wasm_bytes = File.read!(@math_wasm_path)
      assert {:ok, [56]} = Opus.Runtime.call_function(wasm_bytes, "multiply", [8, 7])
    end
  end

  describe "validate/1" do
    test "validates well-formed WASM binary" do
      wasm_bytes = File.read!(@math_wasm_path)
      assert :ok = Opus.Runtime.validate(wasm_bytes)
    end

    test "returns error for invalid WASM" do
      assert {:error, _reason} = Opus.Runtime.validate("not valid wasm")
    end

    test "returns error for empty binary" do
      assert {:error, _reason} = Opus.Runtime.validate(<<>>)
    end
  end

  describe "list_exports/1" do
    test "lists exported functions from core module" do
      wasm_bytes = File.read!(@math_wasm_path)
      {:ok, exports} = Opus.Runtime.list_exports(wasm_bytes)

      assert "sum" in exports
      assert "add" in exports
      assert "multiply" in exports
    end

    test "returns error for invalid WASM" do
      assert {:error, _reason} = Opus.Runtime.list_exports("not wasm")
    end
  end
end
