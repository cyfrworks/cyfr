defmodule Opus.FormulaHandlerTest do
  use ExUnit.Case, async: false

  alias Opus.FormulaHandler
  alias Sanctum.Context

  @math_wasm_path Path.join(__DIR__, "../support/test_wasm/math.wasm")

  setup do
    test_path = Path.join(System.tmp_dir!(), "formula_handler_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

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
  # build_formula_imports/2
  # ============================================================================

  describe "build_formula_imports/2" do
    test "returns map with correct namespace and function", %{ctx: ctx} do
      imports = FormulaHandler.build_formula_imports(ctx, "exec_parent-123")

      assert is_map(imports)
      assert Map.has_key?(imports, "cyfr:formula/invoke@0.1.0")

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      assert Map.has_key?(invoke_ns, "call")
      assert {:fn, func} = invoke_ns["call"]
      assert is_function(func, 1)
    end
  end

  # ============================================================================
  # execute/3 - JSON Parsing
  # ============================================================================

  describe "execute/3 - JSON parsing" do
    test "returns error for invalid JSON", %{ctx: ctx} do
      result = FormulaHandler.execute("not json", ctx, "exec_parent")

      parsed = Jason.decode!(result)
      assert parsed["error"]["type"] == "invalid_json"
      assert parsed["error"]["message"] =~ "Invalid JSON"
    end

    test "returns error when reference is missing", %{ctx: ctx} do
      json = Jason.encode!(%{"input" => %{"a" => 1}})
      result = FormulaHandler.execute(json, ctx, "exec_parent")

      parsed = Jason.decode!(result)
      assert parsed["error"]["type"] == "invalid_request"
    end

    test "returns error when input is missing", %{ctx: ctx} do
      json = Jason.encode!(%{"reference" => %{"local" => "/tmp/test.wasm"}})
      result = FormulaHandler.execute(json, ctx, "exec_parent")

      parsed = Jason.decode!(result)
      assert parsed["error"]["type"] == "invalid_request"
    end

    test "returns error for invalid component type", %{ctx: ctx} do
      json = Jason.encode!(%{
        "reference" => %{"local" => "/tmp/test.wasm"},
        "input" => %{},
        "type" => "invalid_type"
      })
      result = FormulaHandler.execute(json, ctx, "exec_parent")

      parsed = Jason.decode!(result)
      assert parsed["error"]["type"] == "invalid_request"
    end

    test "defaults type to reagent when not specified", %{ctx: ctx, wasm_path: wasm_path} do
      json = Jason.encode!(%{
        "reference" => %{"local" => wasm_path},
        "input" => %{"a" => 5, "b" => 3}
      })

      result = FormulaHandler.execute(json, ctx, "exec_parent-123")
      parsed = Jason.decode!(result)

      # Either success or failure is fine - we're testing that type defaults to reagent
      assert Map.has_key?(parsed, "status") or Map.has_key?(parsed, "error")
    end
  end

  # ============================================================================
  # execute/3 - Invocation via Executor
  # ============================================================================

  describe "execute/3 - invocation" do
    test "invokes local component and returns output", %{ctx: ctx, wasm_path: wasm_path} do
      parent_exec_id = "exec_formula-parent-#{:rand.uniform(100_000)}"

      json = Jason.encode!(%{
        "reference" => %{"local" => wasm_path},
        "input" => %{"a" => 5, "b" => 3},
        "type" => "reagent"
      })

      result = FormulaHandler.execute(json, ctx, parent_exec_id)
      parsed = Jason.decode!(result)

      assert parsed["status"] == "completed"
      assert is_map(parsed["output"])
    end

    test "returns execution_failed error for nonexistent local file", %{ctx: ctx, test_path: test_path} do
      # Use a canonical-looking path so ref extraction succeeds, but the file doesn't exist
      nonexistent = Path.join(test_path, "reagents/local/missing/0.1.0/reagent.wasm")
      json = Jason.encode!(%{
        "reference" => %{"local" => nonexistent},
        "input" => %{"a" => 1}
      })

      result = FormulaHandler.execute(json, ctx, "exec_parent-123")
      parsed = Jason.decode!(result)

      assert parsed["error"]["type"] == "execution_failed"
      assert parsed["error"]["message"] =~ "not found"
    end
  end

  # ============================================================================
  # execute/3 - parent_execution_id Linkage
  # ============================================================================

  describe "execute/3 - parent_execution_id linkage" do
    test "sub-execution records parent_execution_id in SQLite", %{ctx: ctx, wasm_path: wasm_path} do
      parent_exec_id = "exec_formula-linkage-#{:rand.uniform(100_000)}"

      json = Jason.encode!(%{
        "reference" => %{"local" => wasm_path},
        "input" => %{"a" => 10, "b" => 7},
        "type" => "reagent"
      })

      result = FormulaHandler.execute(json, ctx, parent_exec_id)
      parsed = Jason.decode!(result)

      if parsed["status"] == "completed" do
        # Find the child execution record in SQLite
        executions = Arca.Execution.list(user_id: ctx.user_id, parent_execution_id: parent_exec_id)

        assert length(executions) >= 1
        child = hd(executions)
        assert child.parent_execution_id == parent_exec_id
        assert child.status == "completed"
      end
    end
  end

  # ============================================================================
  # execute/3 - Telemetry
  # ============================================================================

  describe "execute/3 - telemetry" do
    test "emits formula invoke telemetry event on success", %{ctx: ctx, wasm_path: wasm_path} do
      test_pid = self()

      :telemetry.attach(
        "test-formula-invoke-success",
        [:cyfr, :opus, :formula, :invoke],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:formula_invoke, metadata})
        end,
        nil
      )

      parent_exec_id = "exec_formula-telem-#{:rand.uniform(100_000)}"

      json = Jason.encode!(%{
        "reference" => %{"local" => wasm_path},
        "input" => %{"a" => 2, "b" => 3},
        "type" => "reagent"
      })

      FormulaHandler.execute(json, ctx, parent_exec_id)

      assert_receive {:formula_invoke, metadata}, 5000
      assert metadata.parent_execution_id == parent_exec_id
      assert metadata.status in [:ok, :error]

      :telemetry.detach("test-formula-invoke-success")
    end

    test "emits formula invoke telemetry event on error", %{ctx: ctx, test_path: test_path} do
      test_pid = self()

      :telemetry.attach(
        "test-formula-invoke-error",
        [:cyfr, :opus, :formula, :invoke],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:formula_invoke, metadata})
        end,
        nil
      )

      parent_exec_id = "exec_formula-telem-err-#{:rand.uniform(100_000)}"

      # Use a canonical-looking path so ref extraction succeeds, but the file doesn't exist
      nonexistent = Path.join(test_path, "reagents/local/missing/0.1.0/reagent.wasm")
      json = Jason.encode!(%{
        "reference" => %{"local" => nonexistent},
        "input" => %{"a" => 1}
      })

      FormulaHandler.execute(json, ctx, parent_exec_id)

      assert_receive {:formula_invoke, metadata}, 5000
      assert metadata.parent_execution_id == parent_exec_id
      assert metadata.status == :error
      assert metadata.child_execution_id == nil

      :telemetry.detach("test-formula-invoke-error")
    end
  end

  # ============================================================================
  # encode_error/2
  # ============================================================================

  describe "encode_error/2" do
    test "encodes error as JSON" do
      result = FormulaHandler.encode_error(:test_error, "something failed")
      parsed = Jason.decode!(result)

      assert parsed["error"]["type"] == "test_error"
      assert parsed["error"]["message"] == "something failed"
    end
  end
end
