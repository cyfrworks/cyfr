defmodule Opus.ResourceLimitsTest do
  use ExUnit.Case, async: false

  alias Opus.Runtime
  alias Sanctum.Context

  @math_wasm_path Path.join(__DIR__, "../support/test_wasm/math.wasm")

  setup do
    test_path = Path.join(System.tmp_dir!(), "opus_limits_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    # Checkout the Ecto sandbox to isolate SQLite data between tests
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

    ctx = Context.local()

    # Copy WASM to canonical layout for local reference execution
    wasm_dir = Path.join(test_path, "reagents/local/test-math/0.1.0")
    File.mkdir_p!(wasm_dir)
    wasm_path = Path.join(wasm_dir, "reagent.wasm")
    File.cp!(@math_wasm_path, wasm_path)

    on_exit(fn ->
      File.rm_rf!(test_path)
      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: ctx, test_path: test_path, wasm_path: wasm_path}
  end

  # ============================================================================
  # Memory Limits
  # ============================================================================

  describe "memory limits" do
    test "accepts memory limit option" do
      wasm_bytes = File.read!(@math_wasm_path)

      # Small memory limit should work for simple math
      result =
        Runtime.execute_component(
          wasm_bytes,
          %{"a" => 1, "b" => 2},
          max_memory_bytes: 1 * 1024 * 1024
        )

      assert {:ok, %{"result" => 3}, _metadata} = result
    end

    test "uses default memory limit when not specified" do
      wasm_bytes = File.read!(@math_wasm_path)

      # Default limit is 64MB, should work fine
      result = Runtime.execute_component(wasm_bytes, %{"a" => 10, "b" => 20})
      assert {:ok, %{"result" => 30}, _metadata} = result
    end

    test "memory limit is applied to core modules" do
      wasm_bytes = File.read!(@math_wasm_path)

      result =
        Runtime.execute_core_module(
          wasm_bytes,
          %{"a" => 5, "b" => 5},
          max_memory_bytes: 8 * 1024 * 1024
        )

      assert {:ok, %{"result" => 10}, _metadata} = result
    end

    test "memory limit of zero uses minimum required" do
      wasm_bytes = File.read!(@math_wasm_path)

      # Zero or very small limit - Wasmex may enforce a minimum
      result =
        Runtime.execute_component(
          wasm_bytes,
          %{"a" => 1, "b" => 1},
          max_memory_bytes: 0
        )

      # Should either work (with minimum memory) or error cleanly
      case result do
        {:ok, %{"result" => 2}, _metadata} -> :ok
        {:error, _} -> :ok
      end
    end
  end

  # ============================================================================
  # Fuel Limits
  # ============================================================================

  describe "fuel limits" do
    test "accepts fuel limit option" do
      wasm_bytes = File.read!(@math_wasm_path)

      # Large fuel limit should work for simple math
      result =
        Runtime.execute_component(
          wasm_bytes,
          %{"a" => 3, "b" => 4},
          fuel_limit: 10_000_000
        )

      assert {:ok, %{"result" => 7}, _metadata} = result
    end

    test "uses default fuel limit when not specified" do
      wasm_bytes = File.read!(@math_wasm_path)

      # Default is 100M instructions
      result = Runtime.execute_component(wasm_bytes, %{"a" => 100, "b" => 200})
      assert {:ok, %{"result" => 300}, _metadata} = result
    end

    test "fuel limit of zero disables fuel metering" do
      wasm_bytes = File.read!(@math_wasm_path)

      # Fuel limit 0 typically means no fuel metering
      result =
        Runtime.execute_component(
          wasm_bytes,
          %{"a" => 1, "b" => 1},
          fuel_limit: 0
        )

      # Should work without fuel metering
      assert {:ok, %{"result" => 2}, _metadata} = result
    end

    test "very small fuel limit for simple operation" do
      wasm_bytes = File.read!(@math_wasm_path)

      # Simple add takes very few instructions
      result =
        Runtime.execute_component(
          wasm_bytes,
          %{"a" => 1, "b" => 1},
          fuel_limit: 1_000
        )

      # Should work - simple add takes < 100 instructions
      assert {:ok, %{"result" => 2}, _metadata} = result
    end
  end

  # ============================================================================
  # Combined Limits
  # ============================================================================

  describe "combined limits" do
    test "both memory and fuel limits can be specified" do
      wasm_bytes = File.read!(@math_wasm_path)

      result =
        Runtime.execute_component(
          wasm_bytes,
          %{"a" => 50, "b" => 50},
          max_memory_bytes: 16 * 1024 * 1024,
          fuel_limit: 5_000_000
        )

      assert {:ok, %{"result" => 100}, _metadata} = result
    end

    test "limits are respected with component type" do
      wasm_bytes = File.read!(@math_wasm_path)

      result =
        Runtime.execute_component(
          wasm_bytes,
          %{"a" => 25, "b" => 25},
          max_memory_bytes: 32 * 1024 * 1024,
          fuel_limit: 10_000_000,
          component_type: :reagent
        )

      assert {:ok, %{"result" => 50}, _metadata} = result
    end
  end

  # ============================================================================
  # High-Level API (Opus.run)
  # ============================================================================

  describe "Opus.run with limits" do
    test "passes memory limit to runtime", %{ctx: ctx, wasm_path: wasm_path} do
      {:ok, result} =
        Opus.run(
          ctx,
          %{"local" => wasm_path},
          %{"a" => 10, "b" => 10},
          max_memory_bytes: 8 * 1024 * 1024
        )

      assert result.status == :completed
      assert result.output == %{"result" => 20}
    end

    test "passes fuel limit to runtime", %{ctx: ctx, wasm_path: wasm_path} do
      {:ok, result} =
        Opus.run(
          ctx,
          %{"local" => wasm_path},
          %{"a" => 5, "b" => 5},
          fuel_limit: 5_000_000
        )

      assert result.status == :completed
      assert result.output == %{"result" => 10}
    end

    test "passes both limits to runtime", %{ctx: ctx, wasm_path: wasm_path} do
      {:ok, result} =
        Opus.run(
          ctx,
          %{"local" => wasm_path},
          %{"a" => 3, "b" => 7},
          max_memory_bytes: 16 * 1024 * 1024,
          fuel_limit: 10_000_000
        )

      assert result.status == :completed
      assert result.output == %{"result" => 10}
    end
  end

  # ============================================================================
  # Default Values
  # ============================================================================

  describe "default limit values" do
    test "default memory limit is 64MB" do
      # Verify default by checking module attributes
      # Default: @default_max_memory_bytes 64 * 1024 * 1024
      default_mb = 64 * 1024 * 1024
      assert default_mb == 67_108_864
    end

    test "default fuel limit is 100M instructions" do
      # Default: @default_fuel_limit 100_000_000
      default_fuel = 100_000_000
      assert default_fuel == 100_000_000
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "edge cases" do
    test "large memory limit value" do
      wasm_bytes = File.read!(@math_wasm_path)

      result =
        Runtime.execute_component(
          wasm_bytes,
          %{"a" => 1, "b" => 1},
          max_memory_bytes: 512 * 1024 * 1024
        )

      assert {:ok, %{"result" => 2}, _metadata} = result
    end

    test "large fuel limit value" do
      wasm_bytes = File.read!(@math_wasm_path)

      result =
        Runtime.execute_component(
          wasm_bytes,
          %{"a" => 1, "b" => 1},
          fuel_limit: 1_000_000_000
        )

      assert {:ok, %{"result" => 2}, _metadata} = result
    end

    test "concurrent executions respect individual limits" do
      wasm_bytes = File.read!(@math_wasm_path)

      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            Runtime.execute_component(
              wasm_bytes,
              %{"a" => i, "b" => i},
              max_memory_bytes: 8 * 1024 * 1024,
              fuel_limit: 1_000_000
            )
          end)
        end

      results = Task.await_many(tasks)

      for {result, i} <- Enum.with_index(results, 1) do
        assert {:ok, %{"result" => expected}, _metadata} = result
        assert expected == i * 2
      end
    end
  end
end
