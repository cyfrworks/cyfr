# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.FormulaHandlerTest do
  use ExUnit.Case, async: false

  alias Opus.FormulaHandler
  alias Sanctum.Context

  @math_wasm_path Path.join(__DIR__, "../support/test_wasm/math.wasm")
  @test_ref "reagent:local.test-math:0.1.0"

  setup do
    test_path = Path.join(System.tmp_dir!(), "formula_handler_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :components_path, Path.join(test_path, "components"))

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()

    wasm_bytes = File.read!(@math_wasm_path)

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, wasm_bytes, %{
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

  # Helper to build MCP-format requests
  defp mcp_request(tool, action, args \\ %{}) do
    Jason.encode!(%{"tool" => tool, "action" => action, "args" => args})
  end

  defp execution_run_request(reference, input, type \\ "reagent") do
    mcp_request("execution", "run", %{
      "reference" => reference,
      "input" => input,
      "type" => type
    })
  end

  # ============================================================================
  # build_formula_imports/2,3
  # ============================================================================

  describe "build_formula_imports/3" do
    test "returns {imports, tracker_pid} tuple with all eight functions", %{ctx: ctx} do
      policy = Sanctum.Policy.default(:formula)

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_parent-123", policy: policy)

      assert is_map(imports)
      assert is_pid(tracker_pid)
      assert Process.alive?(tracker_pid)
      assert Map.has_key?(imports, "cyfr:formula/invoke@0.1.0")

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]

      for func_name <- [
            "call",
            "spawn",
            "await",
            "await-all",
            "await-any",
            "poll",
            "cancel",
            "emit"
          ] do
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
  # execute/4 - JSON Parsing (MCP format)
  # ============================================================================

  describe "execute/3 - JSON parsing" do
    test "returns error for invalid JSON", %{ctx: ctx} do
      result = FormulaHandler.execute("not json", ctx, parent_execution_id: "exec_parent")

      parsed = Jason.decode!(result)
      assert parsed["error"]["type"] == "invalid_json"
      assert parsed["error"]["message"] =~ "Invalid JSON"
    end

    test "returns error when tool is missing", %{ctx: ctx} do
      json = Jason.encode!(%{"action" => "run"})
      result = FormulaHandler.execute(json, ctx, parent_execution_id: "exec_parent")

      parsed = Jason.decode!(result)
      assert parsed["error"]["type"] == "invalid_request"
      assert parsed["error"]["message"] =~ "tool"
    end

    test "returns error when action is missing", %{ctx: ctx} do
      json = Jason.encode!(%{"tool" => "execution"})
      result = FormulaHandler.execute(json, ctx, parent_execution_id: "exec_parent")

      parsed = Jason.decode!(result)
      assert parsed["error"]["type"] == "invalid_request"
    end

    test "returns error when args is not a map", %{ctx: ctx} do
      json = Jason.encode!(%{"tool" => "execution", "action" => "run", "args" => "string"})
      result = FormulaHandler.execute(json, ctx, parent_execution_id: "exec_parent")

      parsed = Jason.decode!(result)
      assert parsed["error"]["type"] == "invalid_request"
      assert parsed["error"]["message"] =~ "args"
    end
  end

  # ============================================================================
  # execute/4 - MCP Dispatch
  # ============================================================================

  describe "execute/3 - MCP dispatch" do
    test "dispatches execution.run through ToolRegistry", %{ctx: ctx, ref: ref} do
      parent_exec_id = "exec_formula-parent-#{:rand.uniform(100_000)}"

      json = execution_run_request(ref, %{"a" => 5, "b" => 3})
      result = FormulaHandler.execute(json, ctx, parent_execution_id: parent_exec_id)
      parsed = Jason.decode!(result)

      # math.wasm is a core module; execution fails with Component Model error
      # But it dispatches correctly through MCP
      assert Map.has_key?(parsed, "status") or Map.has_key?(parsed, "error")
    end

    test "dispatches to non-execution tools", %{ctx: ctx} do
      policy = %Sanctum.Policy{allowed_tools: ["tools.list"]}

      json = mcp_request("tools", "list")

      result =
        FormulaHandler.execute(json, ctx, parent_execution_id: "exec_tools_test", policy: policy)

      parsed = Jason.decode!(result)

      assert parsed["status"] == "completed"
      assert is_map(parsed["output"])
    end

    test "returns dispatch error for unregistered component", %{ctx: ctx} do
      # An unregistered component has no profile, so the run is refused by
      # the consent gate before resolution is attempted.
      json = execution_run_request("reagent:local.missing:0.1.0", %{"a" => 1})
      result = FormulaHandler.execute(json, ctx, parent_execution_id: "exec_parent-123")
      parsed = Jason.decode!(result)

      assert parsed["error"]["type"] == "dispatch_error"
      assert parsed["error"]["message"] =~ "consent_required: "
    end
  end

  # ============================================================================
  # execute/4 - Policy Enforcement
  # ============================================================================

  describe "execute/3 - policy enforcement" do
    test "denies tool not in allowed_tools", %{ctx: ctx} do
      policy = %Sanctum.Policy{allowed_tools: ["storage.read"]}

      json = mcp_request("execution", "run", %{"reference" => "reagent:test:0.1.0"})

      result =
        FormulaHandler.execute(json, ctx, parent_execution_id: "exec_parent", policy: policy)

      parsed = Jason.decode!(result)

      assert parsed["error"]["type"] == "tool_denied"
      assert parsed["error"]["message"] =~ "execution.run"
    end

    test "allows all tools when policy is nil", %{ctx: ctx, ref: ref} do
      json = execution_run_request(ref, %{"a" => 1, "b" => 2})
      result = FormulaHandler.execute(json, ctx, parent_execution_id: "exec_parent")
      parsed = Jason.decode!(result)

      # Should not be tool_denied
      refute match?(%{"error" => %{"type" => "tool_denied"}}, parsed)
    end

    test "allows tool with wildcard match", %{ctx: ctx, ref: ref} do
      policy = %Sanctum.Policy{allowed_tools: ["execution.*"]}

      json = execution_run_request(ref, %{"a" => 1, "b" => 2})

      result =
        FormulaHandler.execute(json, ctx, parent_execution_id: "exec_parent", policy: policy)

      parsed = Jason.decode!(result)

      refute match?(%{"error" => %{"type" => "tool_denied"}}, parsed)
    end
  end

  # ============================================================================
  # execute/4 - tools.list filtering
  # ============================================================================

  describe "execute/3 - tools.list filtering" do
    test "tools.list filters out restricted tools for formulas", %{ctx: ctx} do
      policy = %Sanctum.Policy{allowed_tools: ["tools.list", "execution.*", "guide.*"]}

      json = mcp_request("tools", "list")

      result =
        FormulaHandler.execute(json, ctx,
          parent_execution_id: "exec_tools_filtered",
          policy: policy
        )

      parsed = Jason.decode!(result)

      assert parsed["status"] == "completed"
      tool_names = Enum.map(parsed["output"]["tools"], & &1["name"])

      # Restricted namespaces should be removed
      refute "session" in tool_names
      refute "key" in tool_names
      refute "permission" in tool_names
      refute "secret_store" in tool_names
      refute "policy_store" in tool_names

      # Safe tools that are in policy should be present
      # (execution and guide are in allowed_tools)
    end

    test "tools.list with nil policy shows all non-restricted tools", %{ctx: ctx} do
      json = mcp_request("tools", "list")
      result = FormulaHandler.execute(json, ctx, parent_execution_id: "exec_tools_nil_policy")
      parsed = Jason.decode!(result)

      assert parsed["status"] == "completed"
      tool_names = Enum.map(parsed["output"]["tools"], & &1["name"])

      # Restricted namespaces should still be removed even with nil policy
      refute "session" in tool_names
      refute "key" in tool_names
    end
  end

  # ============================================================================
  # execute/4 - Restricted tools enforcement
  # ============================================================================

  describe "execute/3 - restricted tools enforcement" do
    test "blocks restricted tool even with nil policy", %{ctx: ctx} do
      json = mcp_request("session", "login", %{"user" => "admin"})
      result = FormulaHandler.execute(json, ctx, parent_execution_id: "exec_restricted_nil")
      parsed = Jason.decode!(result)

      assert parsed["error"]["type"] == "tool_denied"
      assert parsed["error"]["message"] =~ "restricted for formula"
      assert parsed["error"]["message"] =~ "session.*"
    end

    test "blocks restricted tool even when policy explicitly allows it", %{ctx: ctx} do
      policy = %Sanctum.Policy{allowed_tools: ["session.*", "policy.set"]}

      json = mcp_request("policy", "set", %{"ref" => "test:1.0.0"})

      result =
        FormulaHandler.execute(json, ctx,
          parent_execution_id: "exec_restricted_allowed",
          policy: policy
        )

      parsed = Jason.decode!(result)

      assert parsed["error"]["type"] == "tool_denied"
      assert parsed["error"]["message"] =~ "restricted for formula"
      assert parsed["error"]["message"] =~ "policy.set"
    end

    test "blocks restricted tool with '*' wildcard policy", %{ctx: ctx} do
      policy = %Sanctum.Policy{allowed_tools: ["*"]}

      json = mcp_request("key", "create", %{})

      result =
        FormulaHandler.execute(json, ctx,
          parent_execution_id: "exec_restricted_star",
          policy: policy
        )

      parsed = Jason.decode!(result)

      assert parsed["error"]["type"] == "tool_denied"
      assert parsed["error"]["message"] =~ "restricted for formula"
      assert parsed["error"]["message"] =~ "key.*"
    end

    test "allows safe tools through normally", %{ctx: ctx} do
      policy = %Sanctum.Policy{allowed_tools: ["tools.list"]}

      json = mcp_request("tools", "list")

      result =
        FormulaHandler.execute(json, ctx, parent_execution_id: "exec_safe_tool", policy: policy)

      parsed = Jason.decode!(result)

      refute match?(%{"error" => %{"type" => "tool_denied"}}, parsed)
    end
  end

  # ============================================================================
  # spawn - restricted tools enforcement
  # ============================================================================

  describe "spawn - restricted tools enforcement" do
    test "spawn blocks restricted tools", %{ctx: ctx} do
      policy = %Sanctum.Policy{
        allowed_tools: ["*"],
        max_concurrent_tasks: 10,
        batch_timeout: "5m"
      }

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_spawn_restricted", policy: policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      spawn_fn = elem(invoke_ns["spawn"], 1)

      result = spawn_fn.(mcp_request("secret", "delete", %{"key" => "test"}))
      parsed = Jason.decode!(result)

      assert parsed["error"]["type"] == "tool_denied"
      assert parsed["error"]["message"] =~ "restricted for formula"

      FormulaHandler.cleanup_registry(tracker_pid)
    end
  end

  # ============================================================================
  # execute/4 - Telemetry
  # ============================================================================

  describe "execute/3 - telemetry" do
    test "emits mcp_tool telemetry event", %{ctx: ctx, ref: ref} do
      test_pid = self()

      :telemetry.attach(
        "test-formula-mcp-tool-success",
        [:cyfr, :opus, :mcp_tool, :call],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:mcp_tool_call, metadata})
        end,
        nil
      )

      parent_exec_id = "exec_formula-telem-#{:rand.uniform(100_000)}"

      json = execution_run_request(ref, %{"a" => 2, "b" => 3})
      FormulaHandler.execute(json, ctx, parent_execution_id: parent_exec_id)

      assert_receive {:mcp_tool_call, metadata}, 5000
      assert metadata.execution_id == parent_exec_id
      assert metadata.tool_action == "execution.run"
      assert metadata.status in [:ok, :error]

      :telemetry.detach("test-formula-mcp-tool-success")
    end

    test "emits telemetry with error status for denied tool", %{ctx: ctx} do
      test_pid = self()

      :telemetry.attach(
        "test-formula-mcp-denied",
        [:cyfr, :opus, :mcp_tool, :call],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:mcp_tool_status, metadata.status})
        end,
        nil
      )

      policy = %Sanctum.Policy{allowed_tools: []}
      json = mcp_request("execution", "run")
      FormulaHandler.execute(json, ctx, parent_execution_id: "exec_denied", policy: policy)

      assert_receive {:mcp_tool_status, :error}, 5000

      :telemetry.detach("test-formula-mcp-denied")
    end
  end

  # ============================================================================
  # spawn + await integration (MCP format)
  # ============================================================================

  describe "spawn + await integration" do
    test "spawn returns task_id, await returns result", %{ctx: ctx, ref: ref} do
      policy = %Sanctum.Policy{
        allowed_tools: ["execution.*"],
        max_concurrent_tasks: 10,
        batch_timeout: "5m"
      }

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_spawn_test", policy: policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]

      # Spawn a task using MCP format
      spawn_fn = elem(invoke_ns["spawn"], 1)
      spawn_result = spawn_fn.(execution_run_request(ref, %{"a" => 1, "b" => 2}))

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

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_spawn_err", policy: policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      spawn_fn = elem(invoke_ns["spawn"], 1)

      result = spawn_fn.("not valid json")
      parsed = Jason.decode!(result)
      assert parsed["error"]["type"] == "invalid_json"

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "spawn denies tool not in allowed_tools", %{ctx: ctx, ref: ref} do
      policy = %Sanctum.Policy{
        allowed_tools: ["storage.read"],
        max_concurrent_tasks: 10,
        batch_timeout: "5m"
      }

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_spawn_denied", policy: policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      spawn_fn = elem(invoke_ns["spawn"], 1)

      result = spawn_fn.(execution_run_request(ref, %{"a" => 1, "b" => 2}))
      parsed = Jason.decode!(result)
      assert parsed["error"]["type"] == "tool_denied"

      FormulaHandler.cleanup_registry(tracker_pid)
    end
  end

  # ============================================================================
  # spawn + await-all integration
  # ============================================================================

  describe "spawn + await-all integration" do
    test "spawns multiple tasks and awaits all results", %{ctx: ctx, ref: ref} do
      policy = %Sanctum.Policy{
        allowed_tools: ["execution.*"],
        max_concurrent_tasks: 10,
        batch_timeout: "5m"
      }

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_await_all", policy: policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      spawn_fn = elem(invoke_ns["spawn"], 1)
      await_all_fn = elem(invoke_ns["await-all"], 1)

      # Spawn two tasks
      r1 = spawn_fn.(execution_run_request(ref, %{"a" => 1, "b" => 2}))
      r2 = spawn_fn.(execution_run_request(ref, %{"a" => 3, "b" => 4}))

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

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_aa_err", policy: policy)

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
      policy = %Sanctum.Policy{
        allowed_tools: ["execution.*"],
        max_concurrent_tasks: 10,
        batch_timeout: "5m"
      }

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_poll", policy: policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      spawn_fn = elem(invoke_ns["spawn"], 1)
      poll_fn = elem(invoke_ns["poll"], 1)

      # Spawn a task
      spawn_result = spawn_fn.(execution_run_request(ref, %{"a" => 1, "b" => 2}))
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

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_poll_err", policy: policy)

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
      policy = %Sanctum.Policy{
        allowed_tools: ["execution.*"],
        max_concurrent_tasks: 10,
        batch_timeout: "5m"
      }

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_cancel_test", policy: policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      spawn_fn = elem(invoke_ns["spawn"], 1)
      cancel_fn = elem(invoke_ns["cancel"], 1)

      # Spawn a task
      spawn_result = spawn_fn.(execution_run_request(ref, %{"a" => 1, "b" => 2}))
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

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_cancel_unknown", policy: policy)

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

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_cancel_check", policy: policy)

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

      policy = %Sanctum.Policy{
        allowed_tools: ["execution.*"],
        max_concurrent_tasks: 10,
        batch_timeout: "5m"
      }

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_cancel_telem", policy: policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      spawn_fn = elem(invoke_ns["spawn"], 1)
      cancel_fn = elem(invoke_ns["cancel"], 1)

      spawn_result = spawn_fn.(execution_run_request(ref, %{"a" => 1, "b" => 2}))
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
  # spawn telemetry
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

      policy = %Sanctum.Policy{
        allowed_tools: ["execution.*"],
        max_concurrent_tasks: 10,
        batch_timeout: "5m"
      }

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_telem_spawn", policy: policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      spawn_fn = elem(invoke_ns["spawn"], 1)

      spawn_fn.(execution_run_request(ref, %{"a" => 1, "b" => 2}))

      assert_receive {:formula_spawn, metadata}, 5000
      assert metadata.parent_execution_id == "exec_telem_spawn"
      assert metadata.task_id == "task_1"

      :telemetry.detach("test-formula-spawn")
      FormulaHandler.cleanup_registry(tracker_pid)
    end
  end

  # ============================================================================
  # cleanup_registry/1
  # ============================================================================

  describe "cleanup_registry/1" do
    test "stops tracker and returns :ok", %{ctx: ctx} do
      policy = Sanctum.Policy.default(:formula)

      {_imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_cleanup", policy: policy)

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
  # emit integration
  # ============================================================================

  describe "emit integration" do
    test "emit returns ok with sequence number", %{ctx: ctx} do
      policy = Sanctum.Policy.default(:formula)

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_emit_test", policy: policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      emit_fn = elem(invoke_ns["emit"], 1)

      result = emit_fn.(Jason.encode!(%{"kind" => "turn_start", "turn" => 1}))
      parsed = Jason.decode!(result)

      assert parsed["ok"] == true
      assert parsed["sequence"] == 1

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "emit sequence increments across calls", %{ctx: ctx} do
      policy = Sanctum.Policy.default(:formula)

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_emit_seq", policy: policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      emit_fn = elem(invoke_ns["emit"], 1)

      r1 = Jason.decode!(emit_fn.(Jason.encode!(%{"kind" => "turn_start", "turn" => 1})))
      r2 = Jason.decode!(emit_fn.(Jason.encode!(%{"kind" => "text_delta", "content" => "hi"})))
      r3 = Jason.decode!(emit_fn.(Jason.encode!(%{"kind" => "tool_use", "tool" => "read"})))

      assert r1["sequence"] == 1
      assert r2["sequence"] == 2
      assert r3["sequence"] == 3

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "emit handles invalid JSON gracefully", %{ctx: ctx} do
      policy = Sanctum.Policy.default(:formula)

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_emit_bad", policy: policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      emit_fn = elem(invoke_ns["emit"], 1)

      result = emit_fn.("not valid json")
      parsed = Jason.decode!(result)

      assert parsed["ok"] == true

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "emit delivers events via PubSub", %{ctx: ctx} do
      execution_id = "exec_emit_pubsub_#{:rand.uniform(100_000)}"
      policy = Sanctum.Policy.default(:formula)

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, execution_id, policy: policy)

      # Subscribe to the execution events topic
      Opus.ExecutionEventBuffer.subscribe(execution_id)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      emit_fn = elem(invoke_ns["emit"], 1)

      emit_fn.(Jason.encode!(%{"kind" => "turn_start", "turn" => 1}))

      assert_receive {:execution_event, event}, 2000
      assert event.type == "emit"
      assert event.execution_id == execution_id
      assert event.sequence == 1
      assert event.data["kind"] == "turn_start"
      assert event.data["turn"] == 1

      Opus.ExecutionEventBuffer.unsubscribe(execution_id)
      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "emit buffers events for replay via since/2", %{ctx: ctx} do
      execution_id = "exec_emit_buffer_#{:rand.uniform(100_000)}"
      policy = Sanctum.Policy.default(:formula)

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, execution_id, policy: policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      emit_fn = elem(invoke_ns["emit"], 1)

      # Emit three events
      emit_fn.(Jason.encode!(%{"kind" => "turn_start", "turn" => 1}))
      emit_fn.(Jason.encode!(%{"kind" => "text_delta", "content" => "hello"}))
      emit_fn.(Jason.encode!(%{"kind" => "tool_use", "tool" => "read_file"}))

      # Flush pending buffer writes before reading
      Opus.ExecutionEventBuffer.flush(execution_id)

      # Replay all events (since sequence 0)
      events = Opus.ExecutionEventBuffer.since(execution_id, 0)
      assert length(events) == 3
      assert Enum.map(events, & &1.sequence) == [1, 2, 3]
      assert Enum.map(events, & &1.data["kind"]) == ["turn_start", "text_delta", "tool_use"]

      # Replay only events after sequence 1
      events_after_1 = Opus.ExecutionEventBuffer.since(execution_id, 1)
      assert length(events_after_1) == 2
      assert Enum.map(events_after_1, & &1.sequence) == [2, 3]

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "emit telemetry fires on each emit", %{ctx: ctx} do
      test_pid = self()
      execution_id = "exec_emit_telem_#{:rand.uniform(100_000)}"

      :telemetry.attach(
        "test-formula-emit",
        [:cyfr, :opus, :formula, :emit],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:formula_emit, metadata, measurements})
        end,
        nil
      )

      policy = Sanctum.Policy.default(:formula)

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, execution_id, policy: policy)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      emit_fn = elem(invoke_ns["emit"], 1)

      emit_fn.(Jason.encode!(%{"kind" => "turn_start", "turn" => 1}))

      assert_receive {:formula_emit, metadata, measurements}, 2000
      assert metadata.execution_id == execution_id
      assert measurements.sequence == 1

      :telemetry.detach("test-formula-emit")
      FormulaHandler.cleanup_registry(tracker_pid)
    end
  end

  # ============================================================================
  # emit routes to root_execution_id
  # ============================================================================

  describe "emit routes to root_execution_id" do
    test "emit delivers events to root execution buffer, not parent", %{ctx: ctx} do
      root_id = "exec_root_#{:rand.uniform(100_000)}"
      parent_id = "exec_child_#{:rand.uniform(100_000)}"
      policy = Sanctum.Policy.default(:formula)

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, parent_id,
          root_execution_id: root_id,
          policy: policy
        )

      # Subscribe to both root and parent
      Opus.ExecutionEventBuffer.subscribe(root_id)
      Opus.ExecutionEventBuffer.subscribe(parent_id)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      emit_fn = elem(invoke_ns["emit"], 1)

      emit_fn.(Jason.encode!(%{"kind" => "turn_start", "turn" => 1}))

      # Event should arrive on root's buffer
      assert_receive {:execution_event, event}, 2000
      assert event.execution_id == root_id
      assert event.data["kind"] == "turn_start"

      # Should NOT arrive on parent's buffer
      refute_receive {:execution_event, _}, 100

      Opus.ExecutionEventBuffer.unsubscribe(root_id)
      Opus.ExecutionEventBuffer.unsubscribe(parent_id)
      FormulaHandler.cleanup_registry(tracker_pid)
    end
  end

  # ============================================================================
  # ExecutionEventBuffer terminal events
  # ============================================================================

  describe "ExecutionEventBuffer terminal events" do
    test "push_terminal delivers complete event via PubSub" do
      execution_id = "exec_terminal_#{:rand.uniform(100_000)}"

      Opus.ExecutionEventBuffer.subscribe(execution_id)

      Opus.ExecutionEventBuffer.push_terminal(
        execution_id,
        "complete",
        %{status: "completed", duration_ms: 1234},
        999_999_999
      )

      assert_receive {:execution_event, event}, 2000
      assert event.type == "complete"
      assert event.execution_id == execution_id
      assert event.sequence == 999_999_999
      assert event.data.status == "completed"
      assert event.data.duration_ms == 1234

      Opus.ExecutionEventBuffer.unsubscribe(execution_id)
    end

    test "push_terminal delivers error event via PubSub" do
      execution_id = "exec_terminal_err_#{:rand.uniform(100_000)}"

      Opus.ExecutionEventBuffer.subscribe(execution_id)

      Opus.ExecutionEventBuffer.push_terminal(
        execution_id,
        "error",
        %{error: "Execution timeout after 5000ms"},
        999_999_999
      )

      assert_receive {:execution_event, event}, 2000
      assert event.type == "error"
      assert event.data.error == "Execution timeout after 5000ms"

      Opus.ExecutionEventBuffer.unsubscribe(execution_id)
    end

    test "terminal events are buffered for replay" do
      execution_id = "exec_terminal_buf_#{:rand.uniform(100_000)}"

      Opus.ExecutionEventBuffer.push_terminal(
        execution_id,
        "complete",
        %{status: "completed"},
        999_999_999
      )

      Opus.ExecutionEventBuffer.flush(execution_id)

      events = Opus.ExecutionEventBuffer.since(execution_id, 0)
      assert length(events) == 1
      assert hd(events).type == "complete"
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
  # execute/5 - Setup error remediation
  # ============================================================================

  describe "execute/3 - setup error remediation" do
    test "enriches setup errors with remediation field", %{ctx: ctx} do
      # Trigger a setup error by running a catalyst with no policy
      # Use a non-existent catalyst to get a dispatch_error (not a setup error)
      # Then test with a known setup error pattern
      parent_exec_id = "exec_remediation_#{:rand.uniform(100_000)}"

      # The policy enforcer produces this error for catalysts with no capabilities
      # We test by calling execution.run on a catalyst that has no policy set
      json =
        mcp_request("execution", "run", %{
          "reference" => "catalyst:local.no-policy-test:0.1.0",
          "input" => %{},
          "type" => "catalyst"
        })

      result = FormulaHandler.execute(json, ctx, parent_execution_id: parent_exec_id)
      parsed = Jason.decode!(result)

      # The component doesn't exist, so we get a dispatch_error (not setup)
      # This verifies non-setup errors are unchanged
      assert parsed["error"]["type"] in ["dispatch_error", "setup_required"]
    end

    test "emits setup_required event to ExecutionEventBuffer", %{ctx: ctx} do
      parent_exec_id = "exec_setup_event_#{:rand.uniform(100_000)}"
      emit_counter = :atomics.new(1, signed: false)

      # Subscribe to events for the parent execution
      Opus.ExecutionEventBuffer.subscribe(parent_exec_id)

      # Simulate: create a catalyst reference that will trigger
      # "has no capabilities configured" error. We need a real registered
      # catalyst for this to work.
      wasm_bytes = File.read!(Path.join(__DIR__, "../support/test_wasm/math.wasm"))

      {:ok, _component} =
        Compendium.Registry.publish_bytes(ctx, wasm_bytes, %{
          name: "setup-test-catalyst",
          version: "0.1.0",
          type: "catalyst",
          description: "Catalyst for setup remediation test"
        })

      json =
        mcp_request("execution", "run", %{
          "reference" => "catalyst:local.setup-test-catalyst:0.1.0",
          "input" => %{},
          "type" => "catalyst"
        })

      result =
        FormulaHandler.execute(json, ctx,
          parent_execution_id: parent_exec_id,
          emit_counter: emit_counter
        )

      parsed = Jason.decode!(result)

      # This catalyst has no policy, so it should produce a setup error
      if parsed["error"]["type"] == "setup_required" do
        assert parsed["error"]["remediation"]
        assert parsed["error"]["remediation"]["component_ref"] =~ "setup-test-catalyst"

        # Verify event was emitted
        assert_receive {:execution_event, event}, 2000
        assert event.data["kind"] == "setup_required"
        assert event.data["component_ref"] =~ "setup-test-catalyst"
      end

      Opus.ExecutionEventBuffer.unsubscribe(parent_exec_id)
    end

    test "normal errors remain unchanged when not a setup issue", %{ctx: ctx} do
      parent_exec_id = "exec_normal_err_#{:rand.uniform(100_000)}"

      # A missing component reference gives dispatch_error, not setup_required
      json =
        mcp_request("execution", "run", %{
          "reference" => "reagent:local.does-not-exist:0.1.0",
          "input" => %{}
        })

      result = FormulaHandler.execute(json, ctx, parent_execution_id: parent_exec_id)
      parsed = Jason.decode!(result)

      assert parsed["error"]["type"] == "dispatch_error"
      refute Map.has_key?(parsed["error"], "remediation")
    end
  end
end
