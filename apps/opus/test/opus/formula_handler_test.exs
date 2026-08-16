# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.FormulaHandlerTest do
  use ExUnit.Case, async: false

  alias Opus.FormulaHandler
  alias Sanctum.Authority
  alias Sanctum.Authority.Blob
  alias Sanctum.Context

  @math_wasm_path Path.join(__DIR__, "../support/test_wasm/math.wasm")
  @test_ref "reagent:local.test-math:0.1.0"
  @test_node "reagent:local.test-math"
  @fh_node "formula:local.fh-root"

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

  defp limits_map do
    %{
      "timeout" => "1m",
      "max_memory_bytes" => 67_108_864,
      "max_request_size" => 1_048_576,
      "max_response_size" => 5_242_880,
      "rate_limit" => %{"requests" => 100, "window" => "1m"},
      "max_concurrent_tasks" => 10,
      "batch_timeout" => "5m"
    }
  end

  # A root authority bound at @fh_node. `tools` grants ride the ingress
  # edge; `edges` are the consented invoke targets; `invoke_mode`
  # distinguishes inert dynamic dispatch from edge_only containment.
  defp authority(opts \\ []) do
    edges = Keyword.get(opts, :edges, %{})
    tools = Keyword.get(opts, :tools, [])
    invoke_mode = Keyword.get(opts, :invoke_mode, :open_inert)

    extra_nodes =
      edges
      |> Map.keys()
      |> Map.new(fn target -> {target, %{"limits" => limits_map(), "edges" => %{}}} end)

    blob_map = %{
      "canonical" => "jcs-1",
      "nodes" =>
        Map.merge(
          %{
            @fh_node => %{
              "limits" => limits_map(),
              "edges" => Map.merge(%{"@ingress" => %{"tools" => tools}}, edges)
            }
          },
          extra_nodes
        )
    }

    {:ok, blob} = Blob.parse(blob_map)

    profile = %{
      profile_id: "prof-fh",
      consent_id: "consent-fh",
      source_ref: @fh_node,
      kind: if(invoke_mode == :edge_only, do: :public, else: :owner),
      invoke_mode: invoke_mode,
      activation: %{@fh_node => "sha256:act-fh"}
    }

    {:ok, auth} = Authority.root(profile, blob)
    auth
  end

  # The opts an execute/3 closure carries under an authority, with the
  # guest-planed context the runtime would hand it.
  defp auth_opts(auth, parent_id, extra \\ []) do
    Keyword.merge([parent_execution_id: parent_id, authority: auth], extra)
  end

  defp fork_imports(ctx, auth, parent_id, overrides \\ []) do
    FormulaHandler.build_formula_imports(
      Context.enter_guest(ctx),
      parent_id,
      Keyword.merge(
        [
          root_execution_id: parent_id,
          limits: Sanctum.Authority.limits(auth),
          authority: auth,
          declared_needs: [],
          activation_digest: "sha256:act-fh"
        ],
        overrides
      )
    )
  end

  # ============================================================================
  # build_formula_imports/2,3
  # ============================================================================

  describe "build_formula_imports/3" do
    test "returns {imports, tracker_pid} tuple with all eight functions", %{ctx: ctx} do
      limits = Sanctum.Limits.defaults(:formula)

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_parent-123",
          limits: limits,
          authority: Sanctum.Authority.zero()
        )

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

    test "works without limits (defaults)", %{ctx: ctx} do
      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_parent-123",
          authority: Sanctum.Authority.zero()
        )

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
    test "dispatches execution.run through the chain on a consented edge", %{ctx: ctx, ref: ref} do
      parent_exec_id = "exec_formula-parent-#{:rand.uniform(100_000)}"
      auth = authority(edges: %{@test_node => %{}})

      json = execution_run_request(ref, %{"a" => 5, "b" => 3})

      result =
        FormulaHandler.execute(json, Context.enter_guest(ctx), auth_opts(auth, parent_exec_id))

      parsed = Jason.decode!(result)

      # math.wasm is a core module, so the bound child fails at component
      # compile — after the edge decision, never as a denial.
      assert parsed["error"]["type"] == "dispatch_error"
      refute parsed["error"]["type"] == "tool_denied"
    end

    test "dispatches to non-execution tools", %{ctx: ctx} do
      auth = authority(tools: ["tools.list"])

      json = mcp_request("tools", "list")

      result =
        FormulaHandler.execute(json, Context.enter_guest(ctx), auth_opts(auth, "exec_tools_test"))

      parsed = Jason.decode!(result)

      assert parsed["status"] == "completed"
      assert is_map(parsed["output"])
    end

    test "returns dispatch error for unregistered component", %{ctx: ctx} do
      # Dynamic dispatch to a ref the registry cannot resolve keeps its
      # error shape: the zero child reaches the executor and fails there.
      auth = authority()
      json = execution_run_request("reagent:local.missing:0.1.0", %{"a" => 1})

      result =
        FormulaHandler.execute(json, Context.enter_guest(ctx), auth_opts(auth, "exec_parent-123"))

      parsed = Jason.decode!(result)

      assert parsed["error"]["type"] == "dispatch_error"
      assert parsed["error"]["message"] =~ "resolve"
    end
  end

  # ============================================================================
  # execute/4 - Invoke containment
  # ============================================================================

  describe "execute/3 - invoke containment" do
    test "an edge_only authority denies an off-edge invoke", %{ctx: ctx, ref: ref} do
      auth = authority(invoke_mode: :edge_only)

      json = execution_run_request(ref, %{"a" => 1, "b" => 2})

      result =
        FormulaHandler.execute(json, Context.enter_guest(ctx), auth_opts(auth, "exec_parent"))

      parsed = Jason.decode!(result)

      assert parsed["error"]["type"] == "tool_denied"
      assert parsed["error"]["message"] =~ "edge_only"
    end

    test "an open_inert authority runs an off-edge invoke inert, not denied", %{
      ctx: ctx,
      ref: ref
    } do
      auth = authority()

      json = execution_run_request(ref, %{"a" => 1, "b" => 2})

      result =
        FormulaHandler.execute(json, Context.enter_guest(ctx), auth_opts(auth, "exec_parent"))

      parsed = Jason.decode!(result)

      # The zero child carries nothing but is not a refusal.
      refute match?(%{"error" => %{"type" => "tool_denied"}}, parsed)
    end
  end

  # ============================================================================
  # execute/4 - In-chain plane containment
  # ============================================================================

  describe "execute/3 - in-chain plane containment" do
    # session/key/policy mutation actions are external-plane only: the
    # reachability gate refuses them from a running chain before any
    # grant is consulted, so even a consented edge cannot open them.

    test "blocks an external-only tool with no grant", %{ctx: ctx} do
      auth = authority()

      json = mcp_request("session", "login", %{"user" => "admin"})

      result =
        FormulaHandler.execute(
          json,
          Context.enter_guest(ctx),
          auth_opts(auth, "exec_restricted_nil")
        )

      parsed = Jason.decode!(result)

      assert parsed["error"]["type"] == "dispatch_error"
      assert parsed["error"]["message"] =~ "not reachable from a running chain"
    end

    test "blocks an external-only tool even when the edge grants it", %{ctx: ctx} do
      auth = authority(tools: ["vault.create"])

      json = mcp_request("vault", "create", %{"name" => "n", "fields" => %{}})

      result =
        FormulaHandler.execute(
          json,
          Context.enter_guest(ctx),
          auth_opts(auth, "exec_restricted_allowed")
        )

      parsed = Jason.decode!(result)

      assert parsed["error"]["type"] == "dispatch_error"
      assert parsed["error"]["message"] =~ "not reachable from a running chain"
    end

    test "blocks key.create in-chain regardless of grants", %{ctx: ctx} do
      auth = authority(tools: ["key.create"])

      json = mcp_request("key", "create", %{})

      result =
        FormulaHandler.execute(
          json,
          Context.enter_guest(ctx),
          auth_opts(auth, "exec_restricted_star")
        )

      parsed = Jason.decode!(result)

      assert parsed["error"]["type"] == "dispatch_error"
      assert parsed["error"]["message"] =~ "not reachable from a running chain"
    end

    test "allows granted in-chain tools through normally", %{ctx: ctx} do
      auth = authority(tools: ["tools.list"])

      json = mcp_request("tools", "list")

      result =
        FormulaHandler.execute(json, Context.enter_guest(ctx), auth_opts(auth, "exec_safe_tool"))

      parsed = Jason.decode!(result)

      refute match?(%{"error" => _}, parsed)
      assert parsed["status"] == "completed"
    end
  end

  # ============================================================================
  # spawn - in-chain plane containment
  # ============================================================================

  describe "spawn - in-chain plane containment" do
    test "a spawned external-only tool call is refused in the task result", %{ctx: ctx} do
      # vault.delete is external-plane only: even a consented edge grant
      # cannot make credential mutation reachable from a running chain.
      auth = authority(tools: ["vault.delete"])

      {imports, tracker_pid} = fork_imports(ctx, auth, "exec_spawn_restricted")

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      spawn_fn = elem(invoke_ns["spawn"], 1)
      await_fn = elem(invoke_ns["await"], 1)

      spawn_result = spawn_fn.(mcp_request("vault", "delete", %{"id" => "vlt_test"}))
      %{"task_id" => task_id} = Jason.decode!(spawn_result)

      awaited = Jason.decode!(await_fn.(task_id))

      assert awaited["status"] == "error"
      assert awaited["error"]["type"] == "dispatch_error"
      assert awaited["error"]["message"] =~ "not reachable from a running chain"

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
      auth = authority(edges: %{@test_node => %{}})

      json = execution_run_request(ref, %{"a" => 2, "b" => 3})
      FormulaHandler.execute(json, Context.enter_guest(ctx), auth_opts(auth, parent_exec_id))

      assert_receive {:mcp_tool_call, metadata}, 5000
      assert metadata.execution_id == parent_exec_id
      assert metadata.tool_action == "execution.run"
      assert metadata.status in [:ok, :error]

      :telemetry.detach("test-formula-mcp-tool-success")
    end

    test "emits telemetry with error status for denied invoke", %{ctx: ctx, ref: ref} do
      test_pid = self()

      :telemetry.attach(
        "test-formula-mcp-denied",
        [:cyfr, :opus, :mcp_tool, :call],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:mcp_tool_status, metadata.status})
        end,
        nil
      )

      auth = authority(invoke_mode: :edge_only)
      json = execution_run_request(ref, %{})
      FormulaHandler.execute(json, Context.enter_guest(ctx), auth_opts(auth, "exec_denied"))

      assert_receive {:mcp_tool_status, :error}, 5000

      :telemetry.detach("test-formula-mcp-denied")
    end
  end

  # ============================================================================
  # spawn + await integration (MCP format)
  # ============================================================================

  describe "spawn + await integration" do
    test "spawn returns task_id, await returns result", %{ctx: ctx, ref: ref} do
      auth = authority(edges: %{@test_node => %{}})
      {imports, tracker_pid} = fork_imports(ctx, auth, "exec_spawn_test")

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
      {imports, tracker_pid} = fork_imports(ctx, authority(), "exec_spawn_err")

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      spawn_fn = elem(invoke_ns["spawn"], 1)

      result = spawn_fn.("not valid json")
      parsed = Jason.decode!(result)
      assert parsed["error"]["type"] == "invalid_json"

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "spawn denies an off-edge invoke under edge_only, synchronously", %{ctx: ctx, ref: ref} do
      auth = authority(invoke_mode: :edge_only)
      {imports, tracker_pid} = fork_imports(ctx, auth, "exec_spawn_denied")

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      spawn_fn = elem(invoke_ns["spawn"], 1)

      # The transition decides before any task exists: a denied spawn
      # consumes no task slot and no budget.
      result = spawn_fn.(execution_run_request(ref, %{"a" => 1, "b" => 2}))
      parsed = Jason.decode!(result)
      assert parsed["error"]["type"] == "tool_denied"
      assert Authority.budget(auth).in_flight == 0

      FormulaHandler.cleanup_registry(tracker_pid)
    end
  end

  # ============================================================================
  # spawn + await-all integration
  # ============================================================================

  describe "spawn + await-all integration" do
    test "spawns multiple tasks and awaits all results", %{ctx: ctx, ref: ref} do
      auth = authority(edges: %{@test_node => %{}})
      {imports, tracker_pid} = fork_imports(ctx, auth, "exec_await_all")

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
      {imports, tracker_pid} = fork_imports(ctx, authority(), "exec_aa_err")

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
      auth = authority(edges: %{@test_node => %{}})
      {imports, tracker_pid} = fork_imports(ctx, auth, "exec_poll")

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
      {imports, tracker_pid} = fork_imports(ctx, authority(), "exec_poll_err")

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
      auth = authority(edges: %{@test_node => %{}})
      {imports, tracker_pid} = fork_imports(ctx, auth, "exec_cancel_test")

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
      {imports, tracker_pid} = fork_imports(ctx, authority(), "exec_cancel_unknown")

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      cancel_fn = elem(invoke_ns["cancel"], 1)

      result = cancel_fn.("nonexistent_task")
      parsed = Jason.decode!(result)

      assert parsed["error"]["type"] == "invalid_request"
      assert parsed["error"]["message"] =~ "Unknown"

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "build_formula_imports includes cancel function", %{ctx: ctx} do
      limits = Sanctum.Limits.defaults(:formula)

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_cancel_check",
          limits: limits,
          authority: Sanctum.Authority.zero()
        )

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

      auth = authority(edges: %{@test_node => %{}})
      {imports, tracker_pid} = fork_imports(ctx, auth, "exec_cancel_telem")

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

      auth = authority(edges: %{@test_node => %{}})
      {imports, tracker_pid} = fork_imports(ctx, auth, "exec_telem_spawn")

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
      limits = Sanctum.Limits.defaults(:formula)

      {_imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_cleanup",
          limits: limits,
          authority: Sanctum.Authority.zero()
        )

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
      limits = Sanctum.Limits.defaults(:formula)

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_emit_test",
          limits: limits,
          authority: Sanctum.Authority.zero()
        )

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      emit_fn = elem(invoke_ns["emit"], 1)

      result = emit_fn.(Jason.encode!(%{"kind" => "turn_start", "turn" => 1}))
      parsed = Jason.decode!(result)

      assert parsed["ok"] == true
      assert parsed["sequence"] == 1

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "emit sequence increments across calls", %{ctx: ctx} do
      limits = Sanctum.Limits.defaults(:formula)

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_emit_seq",
          limits: limits,
          authority: Sanctum.Authority.zero()
        )

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
      limits = Sanctum.Limits.defaults(:formula)

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, "exec_emit_bad",
          limits: limits,
          authority: Sanctum.Authority.zero()
        )

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      emit_fn = elem(invoke_ns["emit"], 1)

      result = emit_fn.("not valid json")
      parsed = Jason.decode!(result)

      # Under an authority a malformed emit is refused loudly, not
      # swallowed: the guest gets a typed error envelope.
      assert parsed["error"]["type"] == "invalid_request"

      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "emit delivers events via PubSub", %{ctx: ctx} do
      execution_id = "exec_emit_pubsub_#{:rand.uniform(100_000)}"
      limits = Sanctum.Limits.defaults(:formula)

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, execution_id,
          limits: limits,
          authority: Sanctum.Authority.zero()
        )

      # Subscribe to the execution events topic
      Opus.ExecutionEventBuffer.subscribe(execution_id, ctx)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      emit_fn = elem(invoke_ns["emit"], 1)

      emit_fn.(Jason.encode!(%{"kind" => "turn_start", "turn" => 1}))

      assert_receive {:execution_event, event}, 2000
      assert event.type == "emit"
      assert event.execution_id == execution_id
      assert event.sequence == 1
      assert event.data["kind"] == "turn_start"
      assert event.data["turn"] == 1

      Opus.ExecutionEventBuffer.unsubscribe(execution_id, ctx)
      FormulaHandler.cleanup_registry(tracker_pid)
    end

    test "emit buffers events for replay via since/2", %{ctx: ctx} do
      execution_id = "exec_emit_buffer_#{:rand.uniform(100_000)}"
      limits = Sanctum.Limits.defaults(:formula)

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, execution_id,
          limits: limits,
          authority: Sanctum.Authority.zero()
        )

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      emit_fn = elem(invoke_ns["emit"], 1)

      # Emit three events
      emit_fn.(Jason.encode!(%{"kind" => "turn_start", "turn" => 1}))
      emit_fn.(Jason.encode!(%{"kind" => "text_delta", "content" => "hello"}))
      emit_fn.(Jason.encode!(%{"kind" => "tool_use", "tool" => "read_file"}))

      # Flush pending buffer writes before reading
      Opus.ExecutionEventBuffer.flush(execution_id)

      # Replay all events (since sequence 0)
      events = Opus.ExecutionEventBuffer.since(execution_id, 0, ctx.athanor_id)
      assert length(events) == 3
      assert Enum.map(events, & &1.sequence) == [1, 2, 3]
      assert Enum.map(events, & &1.data["kind"]) == ["turn_start", "text_delta", "tool_use"]

      # Replay only events after sequence 1
      events_after_1 = Opus.ExecutionEventBuffer.since(execution_id, 1, ctx.athanor_id)
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

      limits = Sanctum.Limits.defaults(:formula)

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, execution_id,
          limits: limits,
          authority: Sanctum.Authority.zero()
        )

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
      limits = Sanctum.Limits.defaults(:formula)

      {imports, tracker_pid} =
        FormulaHandler.build_formula_imports(ctx, parent_id,
          root_execution_id: root_id,
          limits: limits,
          authority: Sanctum.Authority.zero()
        )

      # Subscribe to both root and parent
      Opus.ExecutionEventBuffer.subscribe(root_id, ctx)
      Opus.ExecutionEventBuffer.subscribe(parent_id, ctx)

      invoke_ns = imports["cyfr:formula/invoke@0.1.0"]
      emit_fn = elem(invoke_ns["emit"], 1)

      emit_fn.(Jason.encode!(%{"kind" => "turn_start", "turn" => 1}))

      # Event should arrive on root's buffer
      assert_receive {:execution_event, event}, 2000
      assert event.execution_id == root_id
      assert event.data["kind"] == "turn_start"

      # Should NOT arrive on parent's buffer
      refute_receive {:execution_event, _}, 100

      Opus.ExecutionEventBuffer.unsubscribe(root_id, ctx)
      Opus.ExecutionEventBuffer.unsubscribe(parent_id, ctx)
      FormulaHandler.cleanup_registry(tracker_pid)
    end
  end

  # ============================================================================
  # ExecutionEventBuffer terminal events
  # ============================================================================

  describe "ExecutionEventBuffer terminal events" do
    test "push_terminal delivers complete event via PubSub", %{ctx: ctx} do
      execution_id = "exec_terminal_#{:rand.uniform(100_000)}"

      Opus.ExecutionEventBuffer.subscribe(execution_id, ctx)

      Opus.ExecutionEventBuffer.push_terminal(
        execution_id,
        "complete",
        %{status: "completed", duration_ms: 1234},
        999_999_999,
        ctx
      )

      assert_receive {:execution_event, event}, 2000
      assert event.type == "complete"
      assert event.execution_id == execution_id
      assert event.sequence == 999_999_999
      assert event.data.status == "completed"
      assert event.data.duration_ms == 1234

      Opus.ExecutionEventBuffer.unsubscribe(execution_id, ctx)
    end

    test "push_terminal delivers error event via PubSub", %{ctx: ctx} do
      execution_id = "exec_terminal_err_#{:rand.uniform(100_000)}"

      Opus.ExecutionEventBuffer.subscribe(execution_id, ctx)

      Opus.ExecutionEventBuffer.push_terminal(
        execution_id,
        "error",
        %{error: "Execution timeout after 5000ms"},
        999_999_999,
        ctx
      )

      assert_receive {:execution_event, event}, 2000
      assert event.type == "error"
      assert event.data.error == "Execution timeout after 5000ms"

      Opus.ExecutionEventBuffer.unsubscribe(execution_id, ctx)
    end

    test "terminal events are buffered for replay", %{ctx: ctx} do
      execution_id = "exec_terminal_buf_#{:rand.uniform(100_000)}"

      Opus.ExecutionEventBuffer.push_terminal(
        execution_id,
        "complete",
        %{status: "completed"},
        999_999_999,
        ctx
      )

      Opus.ExecutionEventBuffer.flush(execution_id)

      events = Opus.ExecutionEventBuffer.since(execution_id, 0, ctx.athanor_id)
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
    test "an unsatisfiable consented dependency is setup_required with remediation", %{ctx: ctx} do
      # The consent names an edge to a component the installed world
      # cannot resolve: the bound invoke refuses with a remediation the
      # surface can act on, instead of a bare dispatch failure.
      parent_exec_id = "exec_remediation_#{:rand.uniform(100_000)}"
      auth = authority(edges: %{"catalyst:local.no-policy-test" => %{}})

      json =
        mcp_request("execution", "run", %{
          "reference" => "catalyst:local.no-policy-test:0.1.0",
          "input" => %{},
          "type" => "catalyst"
        })

      result =
        FormulaHandler.execute(json, Context.enter_guest(ctx), auth_opts(auth, parent_exec_id))

      parsed = Jason.decode!(result)

      assert parsed["error"]["type"] == "setup_required"
      assert parsed["error"]["remediation"]["node_ref"] == "catalyst:local.no-policy-test:0.1.0"
      assert parsed["error"]["remediation"]["reason"] == "unresolvable_target"
    end

    test "normal errors remain unchanged when not a setup issue", %{ctx: ctx} do
      parent_exec_id = "exec_normal_err_#{:rand.uniform(100_000)}"
      auth = authority()

      # A missing component off the consent graph gives dispatch_error,
      # not setup_required
      json =
        mcp_request("execution", "run", %{
          "reference" => "reagent:local.does-not-exist:0.1.0",
          "input" => %{}
        })

      result =
        FormulaHandler.execute(json, Context.enter_guest(ctx), auth_opts(auth, parent_exec_id))

      parsed = Jason.decode!(result)

      assert parsed["error"]["type"] == "dispatch_error"
      refute Map.has_key?(parsed["error"], "remediation")
    end
  end
end
