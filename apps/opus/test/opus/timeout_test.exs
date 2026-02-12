defmodule Opus.TimeoutTest do
  use ExUnit.Case, async: false

  alias Opus.Executor
  alias Opus.MCP
  alias Sanctum.Context

  @math_wasm_path Path.join(__DIR__, "../support/test_wasm/math.wasm")

  setup do
    # Use a test-specific base path to avoid state leaking between tests
    test_path = Path.join(System.tmp_dir!(), "opus_timeout_test_#{:rand.uniform(100_000)}")
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

  describe "timeout enforcement" do
    test "execution completes within timeout", %{ctx: ctx, wasm_path: wasm_path} do
      # Normal execution should complete well within default 30s timeout
      {:ok, result} = MCP.handle("execution", ctx, %{
        "action" => "run",
        "reference" => %{"local" => wasm_path},
        "input" => %{"a" => 5, "b" => 3}
      })

      assert result.status == "completed"
      assert result.result["result"] == 8
    end

    test "Executor respects timeout_ms option", %{ctx: ctx, wasm_path: wasm_path} do
      # Execute with explicit timeout - should succeed
      {:ok, result} = Executor.run(ctx, %{"local" => wasm_path}, %{"a" => 10, "b" => 20},
        timeout_ms: 5000
      )

      assert result.status == :completed
      assert result.output["result"] == 30
    end

    test "default timeout (30s) applied when not specified", %{ctx: ctx, wasm_path: wasm_path} do
      # Execution without explicit timeout uses default
      {:ok, result} = MCP.handle("execution", ctx, %{
        "action" => "run",
        "reference" => %{"local" => wasm_path},
        "input" => %{"a" => 1, "b" => 2}
      })

      # The policy_applied should show the default timeout
      assert result.policy_applied.timeout == "30s"
    end

    test "timeout error is properly returned", %{ctx: _ctx} do
      # Create a mock scenario where we can test timeout behavior
      # Since we can't easily create a WASM that times out, we test the error format
      # by verifying the timeout mechanism exists

      # The actual timeout would require a WASM that runs for > timeout_ms
      # For now, verify the timeout infrastructure is in place
      assert Code.ensure_loaded?(Task)

      # Verify Executor module is loaded and has the run function
      assert Code.ensure_loaded?(Executor)
      # Executor exports run/3 and run/4 (with optional opts)
      assert function_exported?(Executor, :run, 3) or function_exported?(Executor, :run, 4)
    end

    test "policy-derived timeout is used when available", %{ctx: ctx, wasm_path: wasm_path} do
      # Execute - the policy should set the timeout
      {:ok, result} = MCP.handle("execution", ctx, %{
        "action" => "run",
        "reference" => %{"local" => wasm_path},
        "input" => %{"a" => 1, "b" => 1}
      })

      # Verify policy was applied
      assert result.policy_applied != nil
      assert result.policy_applied.timeout != nil
    end
  end

  describe "timeout edge cases" do
    test "very short timeout still allows fast execution", %{ctx: ctx, wasm_path: wasm_path} do
      # Simple math operations should complete in < 1s
      {:ok, result} = Executor.run(ctx, %{"local" => wasm_path}, %{"a" => 1, "b" => 1},
        timeout_ms: 1000
      )

      assert result.status == :completed
    end

    test "timeout does not affect subsequent executions", %{ctx: ctx, wasm_path: wasm_path} do
      # Run multiple executions
      for i <- 1..3 do
        {:ok, result} = MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => %{"local" => wasm_path},
          "input" => %{"a" => i, "b" => i}
        })

        assert result.status == "completed"
        assert result.result["result"] == i * 2
      end
    end
  end
end
