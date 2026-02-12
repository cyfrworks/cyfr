defmodule OpusTest do
  use ExUnit.Case, async: false

  alias Sanctum.Context

  @math_wasm_path Path.join([__DIR__, "support/test_wasm/math.wasm"])

  setup do
    test_path = Path.join(System.tmp_dir!(), "opus_test_#{:rand.uniform(100_000)}")
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

    {:ok, ctx: ctx, wasm_path: wasm_path}
  end

  describe "run/4" do
    test "executes local WASM component", %{ctx: ctx, wasm_path: wasm_path} do
      # Execute via public API
      {:ok, result} = Opus.run(ctx, %{"local" => wasm_path}, %{"a" => 5, "b" => 10})

      assert result.status == :completed
      assert result.output == %{"result" => 15}
      assert result.metadata.component_type == :reagent
      assert is_binary(result.metadata.execution_id)
      assert String.starts_with?(result.metadata.component_digest, "sha256:")
    end

    test "returns error for non-canonical local path", %{ctx: ctx} do
      {:error, msg} = Opus.run(ctx, %{"local" => "/nonexistent/file.wasm"}, %{})
      assert msg =~ "canonical layout"
    end

    test "returns error for invalid reference", %{ctx: ctx} do
      {:error, msg} = Opus.run(ctx, %{}, %{})
      assert msg =~ "Cannot extract component ref"
    end
  end

  describe "list/2" do
    test "lists execution records", %{ctx: ctx} do
      {:ok, records} = Opus.list(ctx)
      assert is_list(records)
    end

    test "returns empty list initially", %{ctx: ctx} do
      {:ok, records} = Opus.list(ctx)
      assert records == []
    end
  end

  describe "get/2" do
    test "returns :not_found for non-existent execution", %{ctx: ctx} do
      assert {:error, :not_found} = Opus.get(ctx, "exec_nonexistent")
    end

    test "retrieves execution after run", %{ctx: ctx, wasm_path: wasm_path} do
      {:ok, run_result} = Opus.run(ctx, %{"local" => wasm_path}, %{"a" => 1, "b" => 2})

      {:ok, record} = Opus.get(ctx, run_result.metadata.execution_id)
      assert record.id == run_result.metadata.execution_id
      assert record.status == :completed
    end
  end

  describe "cancel/2" do
    test "returns :not_found for non-existent execution", %{ctx: ctx} do
      assert {:error, :not_found} = Opus.cancel(ctx, "exec_nonexistent")
    end

    test "returns :not_cancellable for completed execution", %{ctx: ctx, wasm_path: wasm_path} do
      {:ok, run_result} = Opus.run(ctx, %{"local" => wasm_path}, %{"a" => 1, "b" => 1})

      assert {:error, :not_cancellable} = Opus.cancel(ctx, run_result.metadata.execution_id)
    end
  end
end
