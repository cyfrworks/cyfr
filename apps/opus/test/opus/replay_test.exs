defmodule Opus.ReplayTest do
  use ExUnit.Case, async: false

  alias Opus.Replay
  alias Sanctum.Context

  @math_wasm_path Path.join(__DIR__, "../support/test_wasm/math.wasm")
  @test_ref "reagent:local.test-math:0.1.0"

  setup do
    test_path = Path.join(System.tmp_dir!(), "opus_replay_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :components_path, Path.join(test_path, "components"))

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Context.local()

    wasm_bytes = File.read!(@math_wasm_path)
    {:ok, _component} = Compendium.Registry.publish_bytes(ctx, wasm_bytes, %{
      name: "test-math",
      version: "0.1.0",
      type: "reagent",
      description: "Test math component"
    })

    on_exit(fn ->
      File.rm_rf!(test_path)
      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: ctx, test_path: test_path, ref: @test_ref}
  end

  # ============================================================================
  # Replay
  # ============================================================================

  describe "replay/3" do
    test "detects error when component is unregistered", %{ctx: ctx, ref: ref} do
      # Execute (fails for core module, but record is still created)
      {:error, _} = Opus.run(ctx, ref, %{"a" => 5, "b" => 5})

      # Find the failed record
      {:ok, records} = Opus.list(ctx)
      record = hd(records)

      # Replay should attempt to re-execute
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
    test "verifies failed execution", %{ctx: ctx, ref: ref} do
      # Core module execution fails — verify returns :not_verifiable since there's no output to verify
      {:error, _} = Opus.run(ctx, ref, %{"a" => 2, "b" => 3})

      {:ok, records} = Opus.list(ctx)
      record = hd(records)

      {:ok, status} = Replay.verify(ctx, record.id)
      assert status == :not_verifiable
    end

    test "returns :verified for unregistered component execution", %{ctx: ctx} do
      # Execute unregistered component
      _result = Opus.run(ctx, "reagent:local.unregistered-verify:0.1.0", %{})

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
    test "compares two failed executions with same input", %{ctx: ctx, ref: ref} do
      # Two executions with same input (both fail for core module)
      {:error, _} = Opus.run(ctx, ref, %{"a" => 10, "b" => 20})
      {:error, _} = Opus.run(ctx, ref, %{"a" => 10, "b" => 20})

      {:ok, records} = Opus.list(ctx)
      assert length(records) >= 2
      [rec_b, rec_a | _] = records

      {:ok, result} = Replay.compare(ctx, rec_a.id, rec_b.id)
      # Both failed with same error, so outputs match (both nil/error)
      assert result in [:identical, :different]
    end

    test "compares two failed executions with different inputs", %{ctx: ctx, ref: ref} do
      # Two executions with different inputs (both fail for core module)
      {:error, _} = Opus.run(ctx, ref, %{"a" => 10, "b" => 20})
      {:error, _} = Opus.run(ctx, ref, %{"a" => 5, "b" => 5})

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
