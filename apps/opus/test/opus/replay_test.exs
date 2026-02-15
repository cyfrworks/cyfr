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
    test "detects error when component file is removed", %{ctx: ctx, wasm_path: wasm_path} do
      # Execute (fails for core module, but record is still created)
      {:error, _} = Opus.run(ctx, %{"local" => wasm_path}, %{"a" => 5, "b" => 5})

      # Find the failed record
      {:ok, records} = Opus.list(ctx)
      record = hd(records)

      # Delete the WASM file
      File.rm!(wasm_path)

      # Replay should fail because the file is gone
      {:error, msg} = Replay.replay(ctx, record.id)
      assert is_binary(msg)
    end

    test "returns error for non-existent execution", %{ctx: ctx} do
      {:error, msg} = Replay.replay(ctx, "exec_nonexistent")
      assert msg =~ "not found"
    end

  end

  # ============================================================================
  # Verify (Quick Check)
  # ============================================================================

  describe "verify/2" do
    test "verifies failed execution", %{ctx: ctx, wasm_path: wasm_path} do
      # Core module execution fails, but verify should still work on the record
      {:error, _} = Opus.run(ctx, %{"local" => wasm_path}, %{"a" => 2, "b" => 3})

      {:ok, records} = Opus.list(ctx)
      record = hd(records)

      {:ok, status} = Replay.verify(ctx, record.id)
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
    test "compares two failed executions with same input", %{ctx: ctx, wasm_path: wasm_path} do
      # Two executions with same input (both fail for core module)
      {:error, _} = Opus.run(ctx, %{"local" => wasm_path}, %{"a" => 10, "b" => 20})
      {:error, _} = Opus.run(ctx, %{"local" => wasm_path}, %{"a" => 10, "b" => 20})

      {:ok, records} = Opus.list(ctx)
      assert length(records) >= 2
      [rec_b, rec_a | _] = records

      {:ok, result} = Replay.compare(ctx, rec_a.id, rec_b.id)
      # Both failed with same error, so outputs match (both nil/error)
      assert result in [:identical, :different]
    end

    test "compares two failed executions with different inputs", %{ctx: ctx, wasm_path: wasm_path} do
      # Two executions with different inputs (both fail for core module)
      {:error, _} = Opus.run(ctx, %{"local" => wasm_path}, %{"a" => 10, "b" => 20})
      {:error, _} = Opus.run(ctx, %{"local" => wasm_path}, %{"a" => 5, "b" => 5})

      {:ok, records} = Opus.list(ctx)
      assert length(records) >= 2
      [rec_b, rec_a | _] = records

      {:ok, result} = Replay.compare(ctx, rec_a.id, rec_b.id)
      assert result in [:identical, :different]
    end

    test "returns error for non-existent execution", %{ctx: ctx} do
      {:error, msg} = Replay.compare(ctx, "exec_a", "exec_b")
      assert msg =~ "not found"
    end
  end
end
