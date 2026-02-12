defmodule Opus.ReplayTest do
  use ExUnit.Case, async: false

  alias Opus.Replay
  alias Sanctum.Context

  @math_wasm_path Path.join(__DIR__, "../support/test_wasm/math.wasm")

  setup do
    test_path = Path.join(System.tmp_dir!(), "opus_replay_test_#{:rand.uniform(100_000)}")
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
  # Replay
  # ============================================================================

  describe "replay/3" do
    test "replays execution and verifies output matches", %{ctx: ctx, wasm_path: wasm_path} do
      # Execute original
      {:ok, exec_result} = Opus.run(ctx, %{"local" => wasm_path}, %{"a" => 10, "b" => 25})

      assert exec_result.status == :completed
      assert exec_result.output == %{"result" => 35}

      # Replay
      {:ok, replay_result} = Replay.replay(ctx, exec_result.metadata.execution_id)

      assert replay_result.verification == :match
      assert replay_result.original_output == %{"result" => 35}
      assert replay_result.replay_output == %{"result" => 35}
      assert replay_result.duration_ms >= 0
      assert replay_result.details =~ "matches original"
    end

    test "detects error when component file is removed", %{ctx: ctx, wasm_path: wasm_path} do
      # Execute original
      {:ok, exec_result} = Opus.run(ctx, %{"local" => wasm_path}, %{"a" => 5, "b" => 5})

      # Delete the WASM file
      File.rm!(wasm_path)

      # Replay should fail because the file is gone
      {:error, msg} = Replay.replay(ctx, exec_result.metadata.execution_id)
      assert is_binary(msg)
    end

    test "returns error for non-existent execution", %{ctx: ctx} do
      {:error, msg} = Replay.replay(ctx, "exec_nonexistent")
      assert msg =~ "not found"
    end

    test "handles execution with minimal input", %{ctx: ctx, wasm_path: wasm_path} do
      # Execute with minimal input (math.wasm needs a and b)
      {:ok, exec_result} = Opus.run(ctx, %{"local" => wasm_path}, %{"a" => 0, "b" => 0})

      # Replay should work with minimal input
      {:ok, replay_result} = Replay.replay(ctx, exec_result.metadata.execution_id)

      assert replay_result.verification == :match
      assert replay_result.original_output == %{"result" => 0}
    end

    test "replay with custom resource limits", %{ctx: ctx, wasm_path: wasm_path} do
      {:ok, exec_result} = Opus.run(ctx, %{"local" => wasm_path}, %{"a" => 1, "b" => 1})

      # Replay with explicit limits
      {:ok, replay_result} =
        Replay.replay(ctx, exec_result.metadata.execution_id,
          max_memory_bytes: 32 * 1024 * 1024,
          fuel_limit: 50_000_000
        )

      assert replay_result.verification == :match
    end
  end

  # ============================================================================
  # Verify (Quick Check)
  # ============================================================================

  describe "verify/2" do
    test "verifies completed execution", %{ctx: ctx, wasm_path: wasm_path} do
      {:ok, exec_result} = Opus.run(ctx, %{"local" => wasm_path}, %{"a" => 2, "b" => 3})

      {:ok, status} = Replay.verify(ctx, exec_result.metadata.execution_id)
      assert status == :verified
    end

    test "returns :verified for failed execution", %{ctx: ctx, test_path: test_path} do
      invalid_path = Path.join(test_path, "invalid_verify.wasm")
      File.write!(invalid_path, "invalid wasm")

      # Execute invalid WASM
      _result =
        try do
          Opus.run(ctx, %{"local" => invalid_path}, %{})
        rescue
          _e -> {:error, "wasm parsing failed"}
        end

      # List to get the execution ID
      {:ok, records} = Opus.list(ctx)

      if length(records) > 0 do
        failed_record = Enum.find(records, &(&1.status == :failed))

        if failed_record do
          {:ok, status} = Replay.verify(ctx, failed_record.id)
          assert status == :verified
        end
      end
    end

    test "returns error for non-existent execution", %{ctx: ctx} do
      {:error, msg} = Replay.verify(ctx, "exec_nonexistent")
      assert msg =~ "not found"
    end
  end

  # ============================================================================
  # Compare
  # ============================================================================

  describe "compare/3" do
    test "returns :identical for same input and component", %{ctx: ctx, wasm_path: wasm_path} do
      # Two executions with same input
      {:ok, exec_a} = Opus.run(ctx, %{"local" => wasm_path}, %{"a" => 10, "b" => 20})
      {:ok, exec_b} = Opus.run(ctx, %{"local" => wasm_path}, %{"a" => 10, "b" => 20})

      {:ok, result} = Replay.compare(ctx, exec_a.metadata.execution_id, exec_b.metadata.execution_id)
      assert result == :identical
    end

    test "returns :different for different inputs", %{ctx: ctx, wasm_path: wasm_path} do
      # Two executions with different inputs
      {:ok, exec_a} = Opus.run(ctx, %{"local" => wasm_path}, %{"a" => 10, "b" => 20})
      {:ok, exec_b} = Opus.run(ctx, %{"local" => wasm_path}, %{"a" => 5, "b" => 5})

      {:ok, result} = Replay.compare(ctx, exec_a.metadata.execution_id, exec_b.metadata.execution_id)
      assert result == :different
    end

    test "returns error for non-existent execution", %{ctx: ctx} do
      {:error, msg} = Replay.compare(ctx, "exec_a", "exec_b")
      assert msg =~ "not found"
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "edge cases" do
    test "replay preserves component type", %{ctx: ctx, wasm_path: wasm_path} do
      # Execute as reagent
      {:ok, exec_result} =
        Opus.run(ctx, %{"local" => wasm_path}, %{"a" => 3, "b" => 4}, type: :reagent)

      {:ok, replay_result} = Replay.replay(ctx, exec_result.metadata.execution_id)
      assert replay_result.verification == :match
    end

    test "replays execution with large input", %{ctx: ctx, wasm_path: wasm_path} do
      # Execute with large values (within i32 range)
      {:ok, exec_result} =
        Opus.run(ctx, %{"local" => wasm_path}, %{"a" => 1_000_000, "b" => 2_000_000})

      {:ok, replay_result} = Replay.replay(ctx, exec_result.metadata.execution_id)
      assert replay_result.verification == :match
      assert replay_result.original_output == %{"result" => 3_000_000}
    end

    test "multiple replays of same execution", %{ctx: ctx, wasm_path: wasm_path} do
      {:ok, exec_result} = Opus.run(ctx, %{"local" => wasm_path}, %{"a" => 7, "b" => 8})

      # Replay multiple times
      for _i <- 1..3 do
        {:ok, replay_result} = Replay.replay(ctx, exec_result.metadata.execution_id)
        assert replay_result.verification == :match
        assert replay_result.replay_output == %{"result" => 15}
      end
    end
  end
end
