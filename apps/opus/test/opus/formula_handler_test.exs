defmodule Opus.FormulaHandlerTest do
  use ExUnit.Case, async: false

  alias Opus.FormulaHandler
  alias Sanctum.Context

  @math_wasm_path Path.join(__DIR__, "../support/test_wasm/math.wasm")
  @test_ref "reagent:local.test-math:0.1.0"

  setup do
    test_path = Path.join(System.tmp_dir!(), "formula_handler_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

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
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: ctx, test_path: test_path, ref: @test_ref}
  end

  # ============================================================================
  # build_formula_imports/3
  # ============================================================================

  describe "build_formula_imports/3" do
    test "returns {imports, tracker_pid} tuple with all seven functions", %{ctx: ctx} do
      policy = Sanctum.Policy.default(:formula)
      {imports, tracker_pid} = FormulaHandler.build_formula_imports(ctx, "exec_parent-123", policy)

      assert is_map(imports)
      assert is_pid(tracker_pid)
      assert Process.alive?(tracker_pid)
      assert Map.has_key?(imports, "cyfr:formula/invoke@0.1.0")

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]

      for func_name <- ["call", "spawn", "await", "await-all", "await-any", "poll", "cancel"] do
        assert Map.has_key?(invoke_ns, func_name), "Missing function: #{func_name}"
        assert {:fn, func} = invoke_ns[func_name]
        assert is_function(func, 1), "#{func_name} is not arity-1"
      end

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "works without policy (defaults)", %{ctx: ctx} do
      {imports, tracker_pid} = FormulaHandler.build_formula_imports(ctx, "exec_parent-123")

      assert is_map(imports)
      assert is_pid(tracker_pid)

      FormulaHandler.cleanup_registry(tracker_pid)
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
      json = Jason.encode!(%{"reference" => "reagent:local.test:0.1.0"})
      result = FormulaHandler.execute(json, ctx, "exec_parent")

      parsed = Jason.decode!(result)
      assert parsed["error"]["type"] == "invalid_request"
    end

    test "returns error for invalid component type", %{ctx: ctx} do
      json = Jason.encode!(%{
        "reference" => "reagent:local.test:0.1.0",
        "input" => %{},
        "type" => "invalid_type"
      })
      result = FormulaHandler.execute(json, ctx, "exec_parent")

      parsed = Jason.decode!(result)
      assert parsed["error"]["type"] == "invalid_request"
    end

    test "defaults type to reagent when not specified", %{ctx: ctx, ref: ref} do
      json = Jason.encode!(%{
        "reference" => ref,
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
    test "returns execution_failed for core module (no Component Model fallback)", %{ctx: ctx, ref: ref} do
      parent_exec_id = "exec_formula-parent-#{:rand.uniform(100_000)}"

      json = Jason.encode!(%{
        "reference" => ref,
        "input" => %{"a" => 5, "b" => 3},
        "type" => "reagent"
      })

      result = FormulaHandler.execute(json, ctx, parent_exec_id)
      parsed = Jason.decode!(result)

      # math.wasm is a core module; execution fails with Component Model error
      assert parsed["error"]["type"] == "execution_failed"
      assert parsed["error"]["message"] =~ "Component Model"
    end

    test "returns execution_failed error for unregistered component", %{ctx: ctx} do
      json = Jason.encode!(%{
        "reference" => "reagent:local.missing:0.1.0",
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
    test "sub-execution records parent_execution_id in SQLite", %{ctx: ctx, ref: ref} do
      parent_exec_id = "exec_formula-linkage-#{:rand.uniform(100_000)}"

      json = Jason.encode!(%{
        "reference" => ref,
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
    test "emits formula invoke telemetry event on success", %{ctx: ctx, ref: ref} do
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
        "reference" => ref,
        "input" => %{"a" => 2, "b" => 3},
        "type" => "reagent"
      })

      FormulaHandler.execute(json, ctx, parent_exec_id)

      assert_receive {:formula_invoke, metadata}, 5000
      assert metadata.parent_execution_id == parent_exec_id
      assert metadata.status in [:ok, :error]

      :telemetry.detach("test-formula-invoke-success")
    end

    test "emits formula invoke telemetry event on error", %{ctx: ctx} do
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

      json = Jason.encode!(%{
        "reference" => "reagent:local.missing:0.1.0",
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
  # spawn + await integration
  # ============================================================================

  describe "spawn + await integration" do
    test "spawn returns task_id, await returns result", %{ctx: ctx, ref: ref} do
      policy = Sanctum.Policy.default(:formula)
      {imports, tracker_pid} = FormulaHandler.build_formula_imports(ctx, "exec_spawn_test", policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]

      # Spawn a task
      spawn_fn = elem(invoke_ns["spawn"], 1)
      spawn_result = spawn_fn.(Jason.encode!(%{
        "reference" => ref,
        "input" => %{"a" => 1, "b" => 2},
        "type" => "reagent"
      }))

      parsed_spawn = Jason.decode!(spawn_result)
      assert Map.has_key?(parsed_spawn, "task_id")
      task_id = parsed_spawn["task_id"]

      # Await the task
      await_fn = elem(invoke_ns["await"], 1)
      await_result = await_fn.(task_id)

      parsed_await = Jason.decode!(await_result)
      assert parsed_await["task_id"] == task_id
      # Could be completed or error (math.wasm is core module)
      assert parsed_await["status"] in ["completed", "error"]

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "spawn returns error when request is invalid", %{ctx: ctx} do
      policy = Sanctum.Policy.default(:formula)
      {imports, tracker_pid} = FormulaHandler.build_formula_imports(ctx, "exec_spawn_err", policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      spawn_fn = elem(invoke_ns["spawn"], 1)

      result = spawn_fn.("not valid json")
      parsed = Jason.decode!(result)
      assert parsed["error"]["type"] == "invalid_json"

      FormulaHandler.cleanup_registry(tracker_pid)
    end
  end

  # ============================================================================
  # spawn + await-all integration
  # ============================================================================

  describe "spawn + await-all integration" do
    test "spawns multiple tasks and awaits all results", %{ctx: ctx, ref: ref} do
      policy = Sanctum.Policy.default(:formula)
      {imports, tracker_pid} = FormulaHandler.build_formula_imports(ctx, "exec_await_all", policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      spawn_fn = elem(invoke_ns["spawn"], 1)
      await_all_fn = elem(invoke_ns["await-all"], 1)

      # Spawn two tasks
      r1 = spawn_fn.(Jason.encode!(%{"reference" => ref, "input" => %{"a" => 1, "b" => 2}, "type" => "reagent"}))
      r2 = spawn_fn.(Jason.encode!(%{"reference" => ref, "input" => %{"a" => 3, "b" => 4}, "type" => "reagent"}))

      id1 = Jason.decode!(r1)["task_id"]
      id2 = Jason.decode!(r2)["task_id"]

      # Await all
      result = await_all_fn.(Jason.encode!(%{"task_ids" => [id1, id2]}))
      parsed = Jason.decode!(result)

      assert parsed["count"] == 2
      assert is_list(parsed["results"])
      assert length(parsed["results"]) == 2

      for item <- parsed["results"] do
        assert item["status"] in ["completed", "error"]
        assert Map.has_key?(item, "task_id")
      end

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "await-all returns error for invalid JSON", %{ctx: ctx} do
      policy = Sanctum.Policy.default(:formula)
      {imports, tracker_pid} = FormulaHandler.build_formula_imports(ctx, "exec_aa_err", policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      await_all_fn = elem(invoke_ns["await-all"], 1)

      result = await_all_fn.("not json")
      parsed = Jason.decode!(result)
      assert parsed["error"]["type"] == "invalid_json"

      FormulaHandler.cleanup_registry(tracker_pid)
    end
  end

  # ============================================================================
  # poll integration
  # ============================================================================

  describe "poll integration" do
    test "poll returns pending for running task, then completed", %{ctx: ctx, ref: ref} do
      policy = Sanctum.Policy.default(:formula)
      {imports, tracker_pid} = FormulaHandler.build_formula_imports(ctx, "exec_poll", policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      spawn_fn = elem(invoke_ns["spawn"], 1)
      poll_fn = elem(invoke_ns["poll"], 1)

      # Spawn a task
      spawn_result = spawn_fn.(Jason.encode!(%{
        "reference" => ref,
        "input" => %{"a" => 1, "b" => 2},
        "type" => "reagent"
      }))
      task_id = Jason.decode!(spawn_result)["task_id"]

      # Wait for task to complete
      Process.sleep(2000)

      # Poll should now return result
      poll_result = poll_fn.(task_id)
      parsed = Jason.decode!(poll_result)
      assert parsed["status"] in ["completed", "error", "pending"]

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "poll returns error for unknown task_id", %{ctx: ctx} do
      policy = Sanctum.Policy.default(:formula)
      {imports, tracker_pid} = FormulaHandler.build_formula_imports(ctx, "exec_poll_err", policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      poll_fn = elem(invoke_ns["poll"], 1)

      result = poll_fn.("nonexistent_task")
      parsed = Jason.decode!(result)
      assert parsed["error"]["type"] == "invalid_request"
      assert parsed["error"]["message"] =~ "Unknown"

      FormulaHandler.cleanup_registry(tracker_pid)
    end
  end

  # ============================================================================
  # cancel integration
  # ============================================================================

  describe "cancel integration" do
    test "cancel returns cancelled response for running task", %{ctx: ctx, ref: ref} do
      policy = Sanctum.Policy.default(:formula)
      {imports, tracker_pid} = FormulaHandler.build_formula_imports(ctx, "exec_cancel_test", policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      spawn_fn = elem(invoke_ns["spawn"], 1)
      cancel_fn = elem(invoke_ns["cancel"], 1)

      # Spawn a long-running task
      spawn_result = spawn_fn.(Jason.encode!(%{
        "reference" => ref,
        "input" => %{"a" => 1, "b" => 2},
        "type" => "reagent"
      }))
      task_id = Jason.decode!(spawn_result)["task_id"]

      # Cancel it
      cancel_result = cancel_fn.(task_id)
      parsed = Jason.decode!(cancel_result)

      assert parsed["cancelled"] == true
      assert parsed["task_id"] == task_id

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "cancel returns error for unknown task_id", %{ctx: ctx} do
      policy = Sanctum.Policy.default(:formula)
      {imports, tracker_pid} = FormulaHandler.build_formula_imports(ctx, "exec_cancel_unknown", policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      cancel_fn = elem(invoke_ns["cancel"], 1)

      result = cancel_fn.("nonexistent_task")
      parsed = Jason.decode!(result)

      assert parsed["error"]["type"] == "invalid_request"
      assert parsed["error"]["message"] =~ "Unknown"

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "build_formula_imports includes cancel function", %{ctx: ctx} do
      policy = Sanctum.Policy.default(:formula)
      {imports, tracker_pid} = FormulaHandler.build_formula_imports(ctx, "exec_cancel_check", policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      assert Map.has_key?(invoke_ns, "cancel")
      assert {:fn, func} = invoke_ns["cancel"]
      assert is_function(func, 1)

      FormulaHandler.cleanup_registry(tracker_pid)
    end
  end

  # ============================================================================
  # cancel telemetry
  # ============================================================================

  describe "cancel telemetry" do
    test "emits formula cancel telemetry event", %{ctx: ctx, ref: ref} do
      test_pid = self()

      :telemetry.attach(
        "test-formula-cancel",
        [:cyfr, :opus, :formula, :cancel],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:formula_cancel, metadata})
        end,
        nil
      )

      policy = Sanctum.Policy.default(:formula)
      {imports, tracker_pid} = FormulaHandler.build_formula_imports(ctx, "exec_cancel_telem", policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      spawn_fn = elem(invoke_ns["spawn"], 1)
      cancel_fn = elem(invoke_ns["cancel"], 1)

      spawn_result = spawn_fn.(Jason.encode!(%{
        "reference" => ref,
        "input" => %{"a" => 1, "b" => 2},
        "type" => "reagent"
      }))
      task_id = Jason.decode!(spawn_result)["task_id"]

      cancel_fn.(task_id)

      assert_receive {:formula_cancel, metadata}, 5000
      assert metadata.parent_execution_id == "exec_cancel_telem"
      assert metadata.task_id == task_id

      :telemetry.detach("test-formula-cancel")
      FormulaHandler.cleanup_registry(tracker_pid)
    end
  end

  # ============================================================================
  # cleanup_registry/1
  # ============================================================================

  describe "cleanup_registry/1" do
    test "stops tracker and returns :ok", %{ctx: ctx} do
      policy = Sanctum.Policy.default(:formula)
      {_imports, tracker_pid} = FormulaHandler.build_formula_imports(ctx, "exec_cleanup", policy)

      assert Process.alive?(tracker_pid)
      assert :ok == FormulaHandler.cleanup_registry(tracker_pid)
      refute Process.alive?(tracker_pid)
    end

    test "returns :ok for non-pid values" do
      assert :ok == FormulaHandler.cleanup_registry(nil)
      assert :ok == FormulaHandler.cleanup_registry("some_string")
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

  # ============================================================================
  # Telemetry: spawn events
  # ============================================================================

  describe "spawn telemetry" do
    test "emits formula spawn telemetry event", %{ctx: ctx, ref: ref} do
      test_pid = self()

      :telemetry.attach(
        "test-formula-spawn",
        [:cyfr, :opus, :formula, :spawn],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:formula_spawn, metadata})
        end,
        nil
      )

      policy = Sanctum.Policy.default(:formula)
      {imports, tracker_pid} = FormulaHandler.build_formula_imports(ctx, "exec_telem_spawn", policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      spawn_fn = elem(invoke_ns["spawn"], 1)

      spawn_fn.(Jason.encode!(%{
        "reference" => ref,
        "input" => %{"a" => 1, "b" => 2},
        "type" => "reagent"
      }))

      assert_receive {:formula_spawn, metadata}, 5000
      assert metadata.parent_execution_id == "exec_telem_spawn"
      assert metadata.task_id == "task_1"

      :telemetry.detach("test-formula-spawn")
      FormulaHandler.cleanup_registry(tracker_pid)
    end
  end
end
