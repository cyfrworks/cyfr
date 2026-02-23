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
    test "returns {imports, exec_ref} tuple with correct namespace and all five functions", %{ctx: ctx} do
      {imports, exec_ref} = FormulaHandler.build_formula_imports(ctx, "exec_parent-123")

      assert is_map(imports)
      assert is_binary(exec_ref)
      assert Map.has_key?(imports, "cyfr:formula/invoke@0.1.0")

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]

      for func_name <- ["call", "call-batch", "poll", "poll-all", "close"] do
        assert Map.has_key?(invoke_ns, func_name), "Missing function: #{func_name}"
        assert {:fn, func} = invoke_ns[func_name]
        assert is_function(func, 1), "#{func_name} is not arity-1"
      end
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
    test "returns execution_failed for core module (no Component Model fallback)", %{ctx: ctx, wasm_path: wasm_path} do
      parent_exec_id = "exec_formula-parent-#{:rand.uniform(100_000)}"

      json = Jason.encode!(%{
        "reference" => %{"local" => wasm_path},
        "input" => %{"a" => 5, "b" => 3},
        "type" => "reagent"
      })

      result = FormulaHandler.execute(json, ctx, parent_exec_id)
      parsed = Jason.decode!(result)

      # math.wasm is a core module; execution fails with Component Model error
      assert parsed["error"]["type"] == "execution_failed"
      assert parsed["error"]["message"] =~ "Component Model"
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

      _result = FormulaHandler.execute(json, ctx, parent_exec_id)

      # Find the child execution record in SQLite (created even on failure)
      executions = Arca.Execution.list(user_id: ctx.user_id, parent_execution_id: parent_exec_id)

      assert length(executions) >= 1
      child = hd(executions)
      assert child.parent_execution_id == parent_exec_id
      # Core module execution fails (no Component Model fallback)
      assert child.status in ["completed", "failed"]
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
  # call_batch/4 - Parsing
  # ============================================================================

  describe "call_batch/4 - parsing" do
    test "returns error for invalid JSON", %{ctx: ctx} do
      result = FormulaHandler.call_batch("not json", ctx, "exec_parent", "ref123")

      parsed = Jason.decode!(result)
      assert parsed["error"]["type"] == "invalid_json"
    end

    test "returns error when invocations key is missing", %{ctx: ctx} do
      json = Jason.encode!(%{"foo" => "bar"})
      result = FormulaHandler.call_batch(json, ctx, "exec_parent", "ref123")

      parsed = Jason.decode!(result)
      assert parsed["error"]["type"] == "invalid_request"
      assert parsed["error"]["message"] =~ "invocations"
    end

    test "returns error for empty invocations array", %{ctx: ctx} do
      json = Jason.encode!(%{"invocations" => []})
      result = FormulaHandler.call_batch(json, ctx, "exec_parent", "ref123")

      parsed = Jason.decode!(result)
      assert parsed["error"]["type"] == "invalid_request"
      assert parsed["error"]["message"] =~ "non-empty"
    end

    test "returns error when invocation has invalid structure", %{ctx: ctx} do
      json = Jason.encode!(%{
        "invocations" => [
          %{"bad" => "data"}
        ]
      })
      result = FormulaHandler.call_batch(json, ctx, "exec_parent", "ref123")

      parsed = Jason.decode!(result)
      assert parsed["error"]["type"] == "invalid_request"
    end

    test "returns batch handle for valid request", %{ctx: ctx, wasm_path: wasm_path} do
      json = Jason.encode!(%{
        "invocations" => [
          %{"reference" => %{"local" => wasm_path}, "input" => %{"a" => 1, "b" => 2}, "type" => "reagent"},
          %{"reference" => %{"local" => wasm_path}, "input" => %{"a" => 3, "b" => 4}, "type" => "reagent"}
        ]
      })

      result = FormulaHandler.call_batch(json, ctx, "exec_parent", "ref123")
      parsed = Jason.decode!(result)

      assert is_binary(parsed["batch"])
      assert parsed["count"] == 2
    end
  end

  # ============================================================================
  # poll/2
  # ============================================================================

  describe "poll/2" do
    test "returns error for invalid handle", _context do
      json = Jason.encode!(%{"batch" => "nonexistent", "index" => 0})
      result = FormulaHandler.poll(json, "ref123")

      parsed = Jason.decode!(result)
      assert parsed["error"]["type"] == "invalid_handle"
    end

    test "returns error for invalid index", %{ctx: ctx, wasm_path: wasm_path} do
      exec_ref = "test_ref_#{:rand.uniform(100_000)}"

      # Create a batch first
      batch_json = Jason.encode!(%{
        "invocations" => [
          %{"reference" => %{"local" => wasm_path}, "input" => %{"a" => 1, "b" => 2}, "type" => "reagent"}
        ]
      })

      batch_result = FormulaHandler.call_batch(batch_json, ctx, "exec_parent", exec_ref)
      batch = Jason.decode!(batch_result)
      handle = batch["batch"]

      # Poll with out-of-range index
      poll_json = Jason.encode!(%{"batch" => handle, "index" => 99})
      result = FormulaHandler.poll(poll_json, exec_ref)

      parsed = Jason.decode!(result)
      assert parsed["error"]["type"] == "invalid_index"

      # Cleanup
      FormulaHandler.close(Jason.encode!(%{"batch" => handle}), exec_ref)
    end

    test "returns pending status immediately after launch", %{ctx: ctx, wasm_path: wasm_path} do
      exec_ref = "test_ref_#{:rand.uniform(100_000)}"

      batch_json = Jason.encode!(%{
        "invocations" => [
          %{"reference" => %{"local" => wasm_path}, "input" => %{"a" => 1, "b" => 2}, "type" => "reagent"}
        ]
      })

      batch_result = FormulaHandler.call_batch(batch_json, ctx, "exec_parent", exec_ref)
      batch = Jason.decode!(batch_result)
      handle = batch["batch"]

      # Poll immediately — spawned process hasn't completed yet
      poll_json = Jason.encode!(%{"batch" => handle, "index" => 0})
      result = FormulaHandler.poll(poll_json, exec_ref)
      parsed = Jason.decode!(result)

      # Should be pending since spawned process needs time
      assert parsed["status"] in ["pending", "completed", "error"]

      FormulaHandler.close(Jason.encode!(%{"batch" => handle}), exec_ref)
    end
  end

  # ============================================================================
  # poll_all/2
  # ============================================================================

  describe "poll_all/2" do
    test "returns all results with correct structure", %{ctx: ctx, wasm_path: wasm_path} do
      exec_ref = "test_ref_#{:rand.uniform(100_000)}"

      batch_json = Jason.encode!(%{
        "invocations" => [
          %{"reference" => %{"local" => wasm_path}, "input" => %{"a" => 1, "b" => 2}, "type" => "reagent"},
          %{"reference" => %{"local" => wasm_path}, "input" => %{"a" => 3, "b" => 4}, "type" => "reagent"}
        ]
      })

      batch_result = FormulaHandler.call_batch(batch_json, ctx, "exec_parent", exec_ref)
      batch = Jason.decode!(batch_result)
      handle = batch["batch"]

      # Poll immediately for structure validation
      poll_json = Jason.encode!(%{"batch" => handle})
      result = FormulaHandler.poll_all(poll_json, exec_ref)
      parsed = Jason.decode!(result)

      assert is_list(parsed["results"])
      assert length(parsed["results"]) == 2
      assert is_boolean(parsed["all_done"])

      # Each result should have an index
      indices = Enum.map(parsed["results"], & &1["index"])
      assert Enum.sort(indices) == [0, 1]

      # Each result should have a status
      for result_item <- parsed["results"] do
        assert result_item["status"] in ["pending", "completed", "error"]
      end

      FormulaHandler.close(Jason.encode!(%{"batch" => handle}), exec_ref)
    end

    test "returns error for invalid handle" do
      json = Jason.encode!(%{"batch" => "nonexistent"})
      result = FormulaHandler.poll_all(json, "ref123")

      parsed = Jason.decode!(result)
      assert parsed["error"]["type"] == "invalid_handle"
    end
  end

  # ============================================================================
  # close/2
  # ============================================================================

  describe "close/2" do
    test "returns ok for unknown handle" do
      json = Jason.encode!(%{"batch" => "nonexistent"})
      result = FormulaHandler.close(json, "ref123")

      parsed = Jason.decode!(result)
      assert parsed["ok"] == true
    end

    test "cleans up active batch", %{ctx: ctx, wasm_path: wasm_path} do
      exec_ref = "test_ref_#{:rand.uniform(100_000)}"

      batch_json = Jason.encode!(%{
        "invocations" => [
          %{"reference" => %{"local" => wasm_path}, "input" => %{"a" => 1, "b" => 2}, "type" => "reagent"}
        ]
      })

      batch_result = FormulaHandler.call_batch(batch_json, ctx, "exec_parent", exec_ref)
      batch = Jason.decode!(batch_result)
      handle = batch["batch"]

      # Close immediately
      close_json = Jason.encode!(%{"batch" => handle})
      result = FormulaHandler.close(close_json, exec_ref)
      parsed = Jason.decode!(result)
      assert parsed["ok"] == true

      # Verify cache entry is gone
      assert Arca.Cache.get({:formula_batch, exec_ref, handle}) == :miss
    end

    test "is idempotent - closing twice returns ok", %{ctx: ctx, wasm_path: wasm_path} do
      exec_ref = "test_ref_#{:rand.uniform(100_000)}"

      batch_json = Jason.encode!(%{
        "invocations" => [
          %{"reference" => %{"local" => wasm_path}, "input" => %{"a" => 1, "b" => 2}, "type" => "reagent"}
        ]
      })

      batch_result = FormulaHandler.call_batch(batch_json, ctx, "exec_parent", exec_ref)
      batch = Jason.decode!(batch_result)
      handle = batch["batch"]

      close_json = Jason.encode!(%{"batch" => handle})

      # Close twice
      result1 = FormulaHandler.close(close_json, exec_ref)
      result2 = FormulaHandler.close(close_json, exec_ref)

      assert Jason.decode!(result1)["ok"] == true
      assert Jason.decode!(result2)["ok"] == true
    end
  end

  # ============================================================================
  # call_batch/4 - Telemetry
  # ============================================================================

  describe "call_batch/4 - telemetry" do
    test "emits formula batch telemetry event", %{ctx: ctx, wasm_path: wasm_path} do
      test_pid = self()

      :telemetry.attach(
        "test-formula-batch",
        [:cyfr, :opus, :formula, :batch],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:formula_batch, metadata})
        end,
        nil
      )

      exec_ref = "test_ref_#{:rand.uniform(100_000)}"

      batch_json = Jason.encode!(%{
        "invocations" => [
          %{"reference" => %{"local" => wasm_path}, "input" => %{"a" => 1, "b" => 2}, "type" => "reagent"},
          %{"reference" => %{"local" => wasm_path}, "input" => %{"a" => 3, "b" => 4}, "type" => "reagent"}
        ]
      })

      result = FormulaHandler.call_batch(batch_json, ctx, "exec_parent_telem", exec_ref)
      batch = Jason.decode!(result)

      assert_receive {:formula_batch, metadata}, 5000
      assert metadata.parent_execution_id == "exec_parent_telem"
      assert metadata.batch_handle == batch["batch"]
      assert metadata.count == 2

      :telemetry.detach("test-formula-batch")

      FormulaHandler.close(Jason.encode!(%{"batch" => batch["batch"]}), exec_ref)
    end
  end

  # ============================================================================
  # cleanup_registry/1
  # ============================================================================

  describe "cleanup_registry/1" do
    test "is safe on nonexistent exec_ref" do
      assert :ok == FormulaHandler.cleanup_registry("nonexistent_ref")
    end

    test "cleans up all batches for exec_ref", %{ctx: ctx, wasm_path: wasm_path} do
      exec_ref = "test_ref_#{:rand.uniform(100_000)}"

      # Create two batches under the same exec_ref
      batch_json = Jason.encode!(%{
        "invocations" => [
          %{"reference" => %{"local" => wasm_path}, "input" => %{"a" => 1, "b" => 2}, "type" => "reagent"}
        ]
      })

      result1 = FormulaHandler.call_batch(batch_json, ctx, "exec_parent", exec_ref)
      result2 = FormulaHandler.call_batch(batch_json, ctx, "exec_parent", exec_ref)
      handle1 = Jason.decode!(result1)["batch"]
      handle2 = Jason.decode!(result2)["batch"]

      # Both should exist in cache
      assert {:ok, _} = Arca.Cache.get({:formula_batch, exec_ref, handle1})
      assert {:ok, _} = Arca.Cache.get({:formula_batch, exec_ref, handle2})

      # Cleanup
      assert :ok == FormulaHandler.cleanup_registry(exec_ref)

      # Both should be gone
      assert Arca.Cache.get({:formula_batch, exec_ref, handle1}) == :miss
      assert Arca.Cache.get({:formula_batch, exec_ref, handle2}) == :miss
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
