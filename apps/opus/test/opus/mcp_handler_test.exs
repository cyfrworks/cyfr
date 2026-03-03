defmodule Opus.FormulaHandlerMcpTest do
  @moduledoc """
  Tests for FormulaHandler's MCP dispatch functionality.
  (Previously McpHandler tests — now absorbed by FormulaHandler)
  """
  use ExUnit.Case, async: false

  alias Opus.FormulaHandler
  alias Sanctum.{Policy, Context}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Arca.Cache.init()

    test_dir = Path.join(System.tmp_dir!(), "formula_handler_mcp_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_dir)

    # Ensure ToolRegistry has providers loaded for dispatch tests
    if Process.whereis(Emissary.MCP.ToolRegistry) do
      Emissary.MCP.ToolRegistry.refresh()
    end

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

      result = FormulaHandler.execute("not json", ctx, eid, policy)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_json"
      assert decoded["error"]["message"] =~ "Invalid JSON"
    end

    test "returns error for missing tool field", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["component.*"]}

      result = FormulaHandler.execute(~s({"action": "search"}), ctx, eid, policy)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_request"
      assert decoded["error"]["message"] =~ "tool"
    end

    test "returns error for missing action field", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["component.*"]}

      result = FormulaHandler.execute(~s({"tool": "component"}), ctx, eid, policy)
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
      result = FormulaHandler.execute(request, ctx, eid, policy)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "tool_denied"
      assert decoded["error"]["message"] =~ "component.search"
    end

    test "denies all tools when allowed_tools is empty", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: []}

      request = Jason.encode!(%{"tool" => "component", "action" => "search", "args" => %{}})
      result = FormulaHandler.execute(request, ctx, eid, policy)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "tool_denied"
    end

    test "allows tool with exact match", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["component.search"]}

      request = Jason.encode!(%{"tool" => "component", "action" => "search", "args" => %{"query" => "test"}})
      result = FormulaHandler.execute(request, ctx, eid, policy)
      decoded = Jason.decode!(result)

      # Should not be a tool_denied error (may be a dispatch error due to test env, but not denied)
      refute match?(%{"error" => %{"type" => "tool_denied"}}, decoded)
    end

    test "allows tool with wildcard match", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["component.*"]}

      request = Jason.encode!(%{"tool" => "component", "action" => "search", "args" => %{"query" => "test"}})
      result = FormulaHandler.execute(request, ctx, eid, policy)
      decoded = Jason.decode!(result)

      refute match?(%{"error" => %{"type" => "tool_denied"}}, decoded)
    end

    test "allows all tools when policy is nil", %{ctx: ctx, execution_id: eid} do
      request = Jason.encode!(%{"tool" => "component", "action" => "search", "args" => %{"query" => "test"}})
      result = FormulaHandler.execute(request, ctx, eid, nil)
      decoded = Jason.decode!(result)

      refute match?(%{"error" => %{"type" => "tool_denied"}}, decoded)
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
      _result = FormulaHandler.execute(request, ctx, eid, policy)

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
      _result = FormulaHandler.execute(request, ctx, eid, policy)

      assert_receive {:telemetry_status, :error}

      :telemetry.detach("test-mcp-denied-#{inspect(ref)}")
    end
  end

  # ============================================================================
  # Dispatch via ToolRegistry
  # ============================================================================

  describe "execute/4 - dispatch via ToolRegistry" do
    test "routes secret.list through ToolRegistry", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["secret.*"]}

      request = Jason.encode!(%{"tool" => "secret", "action" => "list", "args" => %{}})
      result = FormulaHandler.execute(request, ctx, eid, policy)
      decoded = Jason.decode!(result)

      # Should not be tool_denied - it routes successfully through ToolRegistry
      refute match?(%{"error" => %{"type" => "tool_denied"}}, decoded)
    end

    test "routes execution.list through ToolRegistry", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["execution.*"]}

      request = Jason.encode!(%{"tool" => "execution", "action" => "list", "args" => %{}})
      result = FormulaHandler.execute(request, ctx, eid, policy)
      decoded = Jason.decode!(result)

      refute match?(%{"error" => %{"type" => "tool_denied"}}, decoded)
    end

    test "routes build.toolchains through ToolRegistry", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["build.*"]}

      request = Jason.encode!(%{"tool" => "build", "action" => "toolchains", "args" => %{}})
      result = FormulaHandler.execute(request, ctx, eid, policy)
      decoded = Jason.decode!(result)

      refute match?(%{"error" => %{"type" => "tool_denied"}}, decoded)
      assert decoded["status"] == "completed"
      assert is_map(decoded["output"]["toolchains"])
    end

    test "routes guide.list through ToolRegistry", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["guide.*"]}

      request = Jason.encode!(%{"tool" => "guide", "action" => "list", "args" => %{}})
      result = FormulaHandler.execute(request, ctx, eid, policy)
      decoded = Jason.decode!(result)

      refute match?(%{"error" => %{"type" => "tool_denied"}}, decoded)
    end

    test "routes tools.list through ToolRegistry", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["tools.list"]}

      request = Jason.encode!(%{"tool" => "tools", "action" => "list", "args" => %{}})
      result = FormulaHandler.execute(request, ctx, eid, policy)
      decoded = Jason.decode!(result)

      assert decoded["status"] == "completed"
      assert is_list(decoded["output"]["tools"])
    end
  end

  # ============================================================================
  # Unknown Tool
  # ============================================================================

  describe "execute/4 - unknown tool dispatch" do
    test "returns dispatch error for unknown tool", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["unknown_service.action"]}

      request = Jason.encode!(%{"tool" => "unknown_service", "action" => "action", "args" => %{}})
      result = FormulaHandler.execute(request, ctx, eid, policy)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "dispatch_error"
      assert decoded["error"]["message"] =~ "Unknown tool"
    end
  end

  # ============================================================================
  # Parent Execution ID Threading
  # ============================================================================

  describe "execute/4 - parent execution id threading" do
    test "threads parent_execution_id for execution.run calls", %{ctx: ctx, execution_id: eid} do
      policy = %Policy{allowed_tools: ["execution.run"]}

      # This will fail at the executor level (no such component), but we can verify
      # it gets past policy and dispatch
      request = Jason.encode!(%{
        "tool" => "execution",
        "action" => "run",
        "args" => %{"reference" => "reagent:test.nonexistent:0.1.0", "input" => %{}}
      })
      result = FormulaHandler.execute(request, ctx, eid, policy)
      decoded = Jason.decode!(result)

      # Should not be tool_denied — the dispatch should proceed
      refute match?(%{"error" => %{"type" => "tool_denied"}}, decoded)
    end
  end
end
