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

  describe "execute_core_module/3 (high-level API)" do
    test "executes with a/b input convention using sum" do
      wasm_bytes = File.read!(@math_wasm_path)
      assert {:ok, %{"result" => 13}, _metadata} = Opus.Runtime.execute_core_module(wasm_bytes, %{"a" => 8, "b" => 5})
    end

    test "executes with x/y input convention using multiply" do
      wasm_bytes = File.read!(@math_wasm_path)
      assert {:ok, %{"result" => 24}, _metadata} = Opus.Runtime.execute_core_module(wasm_bytes, %{"x" => 4, "y" => 6})
    end

    test "defaults to reagent component type" do
      wasm_bytes = File.read!(@math_wasm_path)
      # Should work without specifying type
      assert {:ok, %{"result" => _}, _metadata} = Opus.Runtime.execute_core_module(wasm_bytes, %{"a" => 1, "b" => 1})
    end

    test "accepts explicit component type" do
      wasm_bytes = File.read!(@math_wasm_path)
      assert {:ok, %{"result" => 10}, _metadata} =
        Opus.Runtime.execute_core_module(wasm_bytes, %{"a" => 4, "b" => 6})
    end
  end

  describe "execute_core_module/3" do
    test "executes sum with a/b keys" do
      wasm_bytes = File.read!(@math_wasm_path)
      assert {:ok, %{"result" => 100}, _metadata} = Opus.Runtime.execute_core_module(wasm_bytes, %{"a" => 60, "b" => 40})
    end

    test "executes multiply with x/y keys" do
      wasm_bytes = File.read!(@math_wasm_path)
      assert {:ok, %{"result" => 56}, _metadata} = Opus.Runtime.execute_core_module(wasm_bytes, %{"x" => 8, "y" => 7})
    end
  end

  describe "resource limits" do
    test "execute_core_module accepts custom memory limit" do
      wasm_bytes = File.read!(@math_wasm_path)
      # Should work with small memory limit for simple calculations
      result = Opus.Runtime.execute_core_module(
        wasm_bytes,
        %{"a" => 1, "b" => 2},
        max_memory_bytes: 16 * 1024 * 1024  # 16MB
      )
      assert {:ok, %{"result" => 3}, _metadata} = result
    end

    test "execute_core_module accepts custom fuel limit" do
      wasm_bytes = File.read!(@math_wasm_path)
      # Should work with fuel limit (simple math uses minimal fuel)
      result = Opus.Runtime.execute_core_module(
        wasm_bytes,
        %{"a" => 5, "b" => 5},
        fuel_limit: 1_000_000  # 1M instructions
      )
      assert {:ok, %{"result" => 10}, _metadata} = result
    end

    test "execute_core_module accepts custom memory limit (32MB)" do
      wasm_bytes = File.read!(@math_wasm_path)
      result = Opus.Runtime.execute_core_module(
        wasm_bytes,
        %{"a" => 7, "b" => 3},
        max_memory_bytes: 32 * 1024 * 1024  # 32MB
      )
      assert {:ok, %{"result" => 10}, _metadata} = result
    end

    test "both limits can be specified together" do
      wasm_bytes = File.read!(@math_wasm_path)
      result = Opus.Runtime.execute_core_module(
        wasm_bytes,
        %{"a" => 100, "b" => 200},
        max_memory_bytes: 64 * 1024 * 1024,
        fuel_limit: 50_000_000
      )
      assert {:ok, %{"result" => 300}, _metadata} = result
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
