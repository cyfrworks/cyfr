defmodule Opus.McpHandlerTest do
  use ExUnit.Case, async: false

  alias Opus.McpHandler
  alias Sanctum.{Policy, Context}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Arca.Cache.init()

    test_dir = Path.join(System.tmp_dir!(), "mcp_handler_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_dir)

    ctx = Context.local()
    execution_id = "exec_test_#{:rand.uniform(100_000)}"

    on_exit(fn ->
      File.rm_rf!(test_dir)
      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: ctx, execution_id: execution_id, test_dir: test_dir}
  end

  # ============================================================================
  # Request Parsing
  # ============================================================================

  describe "execute/4 - request parsing" do
    test "returns error for invalid JSON", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["component.*"]}

      result = McpHandler.execute("not json", policy, ctx, eid)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_json"
      assert decoded["error"]["message"] =~ "Invalid JSON"
    end

    test "returns error for missing tool field", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["component.*"]}

      result = McpHandler.execute(~s({"action": "search"}), policy, ctx, eid)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_request"
      assert decoded["error"]["message"] =~ "tool"
    end

    test "returns error for missing action field", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["component.*"]}

      result = McpHandler.execute(~s({"tool": "component"}), policy, ctx, eid)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_request"
    end
  end

  # ============================================================================
  # Policy Enforcement
  # ============================================================================

  describe "execute/4 - tool policy enforcement" do
    test "denies tool not in allowed_tools", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["storage.read"]}

      request = Jason.encode!(%{"tool" => "component", "action" => "search", "args" => %{"query" => "test"}})
      result = McpHandler.execute(request, policy, ctx, eid)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "tool_denied"
      assert decoded["error"]["message"] =~ "component.search"
    end

    test "denies all tools when allowed_tools is empty", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: []}

      request = Jason.encode!(%{"tool" => "component", "action" => "search", "args" => %{}})
      result = McpHandler.execute(request, policy, ctx, eid)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "tool_denied"
    end

    test "allows tool with exact match", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["component.search"]}

      request = Jason.encode!(%{"tool" => "component", "action" => "search", "args" => %{"query" => "test"}})
      result = McpHandler.execute(request, policy, ctx, eid)
      decoded = Jason.decode!(result)

      # Should not be a tool_denied error (may be a dispatch error due to test env, but not denied)
      refute match?(%{"error" => %{"type" => "tool_denied"}}, decoded)
    end

    test "allows tool with wildcard match", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["component.*"]}

      request = Jason.encode!(%{"tool" => "component", "action" => "search", "args" => %{"query" => "test"}})
      result = McpHandler.execute(request, policy, ctx, eid)
      decoded = Jason.decode!(result)

      refute match?(%{"error" => %{"type" => "tool_denied"}}, decoded)
    end
  end

  # ============================================================================
  # Storage Path Enforcement
  # ============================================================================

  describe "execute/4 - storage path enforcement" do
    test "denies storage write outside agent/ namespace", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["storage.write"]}

      request = Jason.encode!(%{"tool" => "storage", "action" => "write", "args" => %{"path" => "secrets/key.json", "content" => "data"}})
      result = McpHandler.execute(request, policy, ctx, eid)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "storage_path_denied"
      assert decoded["error"]["message"] =~ "agent/"
    end

    test "allows storage write inside agent/ namespace", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["storage.write"]}

      request = Jason.encode!(%{"tool" => "storage", "action" => "write", "args" => %{"path" => "agent/data.json", "content" => "dGVzdA=="}})
      result = McpHandler.execute(request, policy, ctx, eid)
      decoded = Jason.decode!(result)

      # Should not be storage_path_denied (may succeed or fail for other reasons in test env)
      refute match?(%{"error" => %{"type" => "storage_path_denied"}}, decoded)
    end

    test "enforces allowed_storage_paths for reads", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["storage.read"], allowed_storage_paths: ["agent/"]}

      request = Jason.encode!(%{"tool" => "storage", "action" => "read", "args" => %{"path" => "secrets/key.json"}})
      result = McpHandler.execute(request, policy, ctx, eid)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "storage_path_denied"
    end

    test "allows reads within allowed_storage_paths", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["storage.read"], allowed_storage_paths: ["agent/"]}

      request = Jason.encode!(%{"tool" => "storage", "action" => "read", "args" => %{"path" => "agent/data.json"}})
      result = McpHandler.execute(request, policy, ctx, eid)
      decoded = Jason.decode!(result)

      refute match?(%{"error" => %{"type" => "storage_path_denied"}}, decoded)
    end
  end

  # ============================================================================
  # Build Imports
  # ============================================================================

  describe "build_mcp_imports/3" do
    test "returns correct namespace structure", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["component.*"]}

      imports = McpHandler.build_mcp_imports(policy, ctx, eid)

      assert Map.has_key?(imports, "cyfr:mcp/tools@0.1.0")
      assert Map.has_key?(imports["cyfr:mcp/tools@0.1.0"], "call")
      assert match?({:fn, _}, imports["cyfr:mcp/tools@0.1.0"]["call"])
    end
  end

  # ============================================================================
  # Telemetry
  # ============================================================================

  describe "execute/4 - telemetry" do
    test "emits telemetry event on tool call", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["component.search"]}

      # Attach a telemetry handler to capture the event
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-mcp-tool-#{inspect(ref)}",
        [:cyfr, :opus, :mcp_tool, :call],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

      request = Jason.encode!(%{"tool" => "component", "action" => "search", "args" => %{"query" => "test"}})
      _result = McpHandler.execute(request, policy, ctx, eid)

      assert_receive {:telemetry_event, [:cyfr, :opus, :mcp_tool, :call], measurements, metadata}
      assert is_integer(measurements.duration_ms)
      assert metadata.execution_id == eid
      assert metadata.tool_action == "component.search"
      assert metadata.status in [:ok, :error]

      :telemetry.detach("test-mcp-tool-#{inspect(ref)}")
    end

    test "emits telemetry with error status for denied tool", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: []}

      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-mcp-denied-#{inspect(ref)}",
        [:cyfr, :opus, :mcp_tool, :call],
        fn _event_name, _measurements, metadata, _config ->
          send(test_pid, {:telemetry_status, metadata.status})
        end,
        nil
      )

      request = Jason.encode!(%{"tool" => "component", "action" => "search", "args" => %{}})
      _result = McpHandler.execute(request, policy, ctx, eid)

      assert_receive {:telemetry_status, :error}

      :telemetry.detach("test-mcp-denied-#{inspect(ref)}")
    end
  end

  # ============================================================================
  # Dispatch Routes
  # ============================================================================

  describe "execute/4 - dispatch routes" do
    test "routes secret.list to Sanctum.MCP", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["secret.*"]}

      request = Jason.encode!(%{"tool" => "secret", "action" => "list", "args" => %{}})
      result = McpHandler.execute(request, policy, ctx, eid)
      decoded = Jason.decode!(result)

      # Should not be tool_denied - it routes successfully to Sanctum.MCP
      refute match?(%{"error" => %{"type" => "tool_denied"}}, decoded)
      refute match?(%{"error" => %{"type" => "dispatch_error", "message" => "Unknown tool" <> _}}, decoded)
    end

    test "routes execution.list to Opus.MCP", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["execution.*"]}

      request = Jason.encode!(%{"tool" => "execution", "action" => "list", "args" => %{}})
      result = McpHandler.execute(request, policy, ctx, eid)
      decoded = Jason.decode!(result)

      refute match?(%{"error" => %{"type" => "tool_denied"}}, decoded)
      refute match?(%{"error" => %{"type" => "dispatch_error", "message" => "Unknown tool" <> _}}, decoded)
    end

    test "routes audit.list to Sanctum.MCP", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["audit.*"]}

      request = Jason.encode!(%{"tool" => "audit", "action" => "list", "args" => %{}})
      result = McpHandler.execute(request, policy, ctx, eid)
      decoded = Jason.decode!(result)

      refute match?(%{"error" => %{"type" => "tool_denied"}}, decoded)
      refute match?(%{"error" => %{"type" => "dispatch_error", "message" => "Unknown tool" <> _}}, decoded)
    end

    test "routes config.get to Sanctum.MCP", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["config.*"]}

      request = Jason.encode!(%{"tool" => "config", "action" => "get", "args" => %{}})
      result = McpHandler.execute(request, policy, ctx, eid)
      decoded = Jason.decode!(result)

      refute match?(%{"error" => %{"type" => "tool_denied"}}, decoded)
      refute match?(%{"error" => %{"type" => "dispatch_error", "message" => "Unknown tool" <> _}}, decoded)
    end

    test "routes build.toolchains to Locus.MCP", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["build.*"]}

      request = Jason.encode!(%{"tool" => "build", "action" => "toolchains", "args" => %{}})
      result = McpHandler.execute(request, policy, ctx, eid)
      decoded = Jason.decode!(result)

      refute match?(%{"error" => %{"type" => "tool_denied"}}, decoded)
      refute match?(%{"error" => %{"type" => "dispatch_error", "message" => "Unknown tool" <> _}}, decoded)
      assert decoded["status"] == "ok"
      assert is_map(decoded["result"]["toolchains"])
    end
  end

  # ============================================================================
  # Unknown Tool
  # ============================================================================

  describe "execute/4 - unknown tool dispatch" do
    test "returns dispatch error for unknown tool", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["unknown_service.action"]}

      request = Jason.encode!(%{"tool" => "unknown_service", "action" => "action", "args" => %{}})
      result = McpHandler.execute(request, policy, ctx, eid)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "dispatch_error"
      assert decoded["error"]["message"] =~ "Unknown tool"
    end
  end
end
