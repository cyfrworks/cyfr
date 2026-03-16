defmodule Arca.MCPTest do
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Arca.MCP

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # Use a test-specific base path to avoid polluting real config
    test_path = Path.join(System.tmp_dir!(), "arca_mcp_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: Context.local(), test_path: test_path}
  end

  # ============================================================================
  # Tool Discovery
  # ============================================================================

  describe "tools/0" do
    test "returns retention and record tools" do
      tools = MCP.tools()
      assert length(tools) == 4

      tool_names = Enum.map(tools, & &1.name)
      assert "retention" in tool_names
      assert "record" in tool_names
      assert "mcp_log" in tool_names
      assert "policy_log" in tool_names
    end

    test "retention tool has 3 actions" do
      tools = MCP.tools()
      tool = Enum.find(tools, &(&1.name == "retention"))
      actions = tool.input_schema["properties"]["action"]["enum"]
      assert actions == ["get", "set", "cleanup"]
    end

    test "record tool has 2 read-only actions" do
      tools = MCP.tools()
      tool = Enum.find(tools, &(&1.name == "record"))
      actions = tool.input_schema["properties"]["action"]["enum"]
      assert actions == ["get", "list"]
    end

    test "each tool has required schema fields" do
      for tool <- MCP.tools() do
        assert is_binary(tool.name)
        assert is_binary(tool.title)
        assert is_binary(tool.description)
        assert is_map(tool.input_schema)
        assert tool.input_schema["type"] == "object"
        assert "action" in tool.input_schema["required"]
      end
    end
  end

  # ============================================================================
  # Resources
  # ============================================================================

  describe "resources/0" do
    test "returns no concrete resources" do
      resources = MCP.resources()
      assert length(resources) == 0
    end
  end

  describe "resource_templates/0" do
    test "returns files resource template" do
      templates = MCP.resource_templates()
      assert length(templates) == 1

      template = hd(templates)
      assert template.uriTemplate == "arca://files/{path}"
    end
  end

  describe "read/2" do
    test "reads file resource", %{ctx: ctx} do
      # Create a test file using Arca API
      :ok = Arca.put(ctx, ["test.txt"], "hello world")

      {:ok, result} = MCP.read(ctx, "arca://files/test.txt")
      assert result.mimeType == "application/octet-stream"
      assert Base.decode64!(result.content) == "hello world"
    end

    test "returns error for missing file", %{ctx: ctx} do
      {:error, msg} = MCP.read(ctx, "arca://files/missing.txt")
      assert msg =~ "not found"
    end

    test "returns error for unknown resource", %{ctx: ctx} do
      {:error, msg} = MCP.read(ctx, "arca://unknown/path")
      assert msg =~ "Unknown resource"
    end
  end

  # ============================================================================
  # Retention Tool
  # ============================================================================

  describe "retention get action" do
    test "get returns default settings", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("retention", ctx, %{
          "action" => "get"
        })

      assert result.action == "get"
      assert is_map(result.settings)
      assert result.settings["executions"] == 10
      assert result.settings["builds"] == 10
    end
  end

  describe "retention set action" do
    test "set updates settings", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("retention", ctx, %{
          "action" => "set",
          "settings" => %{"executions" => 5, "builds" => 3}
        })

      assert result.updated == true
      assert result.settings["executions"] == 5
      assert result.settings["builds"] == 3

      # Verify persisted
      {:ok, get_result} =
        MCP.handle("retention", ctx, %{
          "action" => "get"
        })

      assert get_result.settings["executions"] == 5
    end
  end

  describe "retention cleanup action" do
    test "cleanup runs with dry_run", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("retention", ctx, %{
          "action" => "cleanup",
          "cleanup_type" => "executions",
          "dry_run" => true
        })

      assert result.action == "cleanup"
      assert result.dry_run == true
      assert is_list(result.would_delete)
    end

    test "cleanup runs for executions", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("retention", ctx, %{
          "action" => "cleanup",
          "cleanup_type" => "executions"
        })

      assert result.action == "cleanup"
      assert result.cleanup_type == "executions"
      assert is_integer(result.deleted)
    end

    test "returns error for invalid action", %{ctx: ctx} do
      {:error, msg} = MCP.handle("retention", ctx, %{"action" => "invalid"})
      assert msg =~ "Invalid retention action"
    end
  end

  # ============================================================================
  # Record Tool (Execution Records)
  # ============================================================================

  # ============================================================================
  # Record Tool - Write Actions Denied (kernel-only)
  # ============================================================================

  describe "record.record_start action (kernel-only)" do
    test "record_start is denied via MCP", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("record", ctx, %{
          "action" => "record_start",
          "id" => "exec_test",
          "reference" => "reagent:local.test:0.1.0",
          "user_id" => "local_user",
          "component_type" => "reagent"
        })

      assert msg =~ "not permitted via MCP"
    end
  end

  describe "record.record_complete action (kernel-only)" do
    test "record_complete is denied via MCP", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("record", ctx, %{
          "action" => "record_complete",
          "id" => "exec_test",
          "status" => "completed"
        })

      assert msg =~ "not permitted via MCP"
    end
  end

  describe "record.get action" do
    test "returns execution by id", %{ctx: ctx} do
      exec_id = "exec_get_#{:rand.uniform(100_000)}"

      # Create record via internal API (kernel-only operation)
      {:ok, _} =
        Arca.Execution.record_start(%{
          id: exec_id,
          reference: "reagent:local.test:0.1.0",
          user_id: ctx.user_id,
          org_id: ctx.org_id,
          project_id: ctx.project_id || "default",
          component_type: "reagent",
          started_at: DateTime.utc_now(),
          status: "running",
          input: "{}"
        })

      {:ok, result} =
        MCP.handle("record", ctx, %{
          "action" => "get",
          "id" => exec_id
        })

      assert result.id == exec_id
      assert result.status == "running"
    end

    test "returns error for nonexistent execution", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("record", ctx, %{
          "action" => "get",
          "id" => "nonexistent_id"
        })

      assert msg =~ "not found"
    end

    test "returns error without id", %{ctx: ctx} do
      {:error, msg} = MCP.handle("record", ctx, %{"action" => "get"})
      assert msg =~ "Missing required"
    end
  end

  describe "record.list action" do
    test "returns empty list when no executions", %{ctx: ctx} do
      {:ok, result} = MCP.handle("record", ctx, %{"action" => "list"})
      assert is_list(result.executions)
    end

    test "returns executions after recording", %{ctx: ctx} do
      exec_id = "exec_list_#{:rand.uniform(100_000)}"

      # Create record via internal API (kernel-only operation)
      {:ok, _} =
        Arca.Execution.record_start(%{
          id: exec_id,
          reference: "reagent:local.test:0.1.0",
          user_id: ctx.user_id,
          org_id: ctx.org_id,
          project_id: ctx.project_id || "default",
          component_type: "reagent",
          started_at: DateTime.utc_now(),
          status: "running",
          input: "{}"
        })

      {:ok, result} =
        MCP.handle("record", ctx, %{
          "action" => "list"
        })

      ids = Enum.map(result.executions, & &1.id)
      assert exec_id in ids
    end

    test "invalid action returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("record", ctx, %{"action" => "invalid"})
      assert msg =~ "Invalid record action"
    end
  end

  # ============================================================================
  # Error Handling
  # ============================================================================

  describe "error handling" do
    test "returns error for unknown tool", %{ctx: ctx} do
      {:error, msg} = MCP.handle("unknown_tool", ctx, %{})
      assert msg =~ "Unknown tool"
    end
  end

  # ============================================================================
  # Authorization Rejection Tests
  # ============================================================================

  # ============================================================================
  # Retention Authorization
  # ============================================================================

  describe "retention authorization with application API key" do
    setup do
      app_ctx = %Context{
        user_id: "app_user",
        org_id: nil,
        permissions: MapSet.new([:execute, :storage_read]),
        scope: :project,
        auth_method: :api_key,
        api_key_type: :application,
        authenticated: true
      }

      {:ok, app_ctx: app_ctx}
    end

    test "can get retention settings", %{app_ctx: app_ctx} do
      {:ok, result} = MCP.handle("retention", app_ctx, %{"action" => "get"})
      assert is_map(result.settings)
    end

    test "cannot set retention settings", %{app_ctx: app_ctx} do
      {:error, msg} =
        MCP.handle("retention", app_ctx, %{
          "action" => "set",
          "settings" => %{"executions" => 5}
        })

      assert msg =~ "Unauthorized"
      assert msg =~ "admin"
    end

    test "cannot run cleanup", %{app_ctx: app_ctx} do
      {:error, msg} =
        MCP.handle("retention", app_ctx, %{
          "action" => "cleanup",
          "cleanup_type" => "executions"
        })

      assert msg =~ "Unauthorized"
      assert msg =~ "admin"
    end
  end

  describe "retention authorization with OIDC session" do
    setup do
      oidc_ctx = %Context{
        user_id: "oidc_user",
        org_id: nil,
        permissions: MapSet.new([:execute, :read, :write, :storage_read, :storage_write, :admin]),
        scope: :project,
        auth_method: :oidc,
        api_key_type: nil,
        session_id: "session_123",
        authenticated: true
      }

      {:ok, oidc_ctx: oidc_ctx}
    end

    test "can set retention settings", %{oidc_ctx: oidc_ctx} do
      {:ok, result} =
        MCP.handle("retention", oidc_ctx, %{
          "action" => "set",
          "settings" => %{"executions" => 5}
        })

      assert result.updated == true
    end

    test "can run cleanup", %{oidc_ctx: oidc_ctx} do
      {:ok, result} =
        MCP.handle("retention", oidc_ctx, %{
          "action" => "cleanup",
          "cleanup_type" => "executions",
          "dry_run" => true
        })

      assert result.dry_run == true
    end
  end

  # ============================================================================
  # Record Authorization (non-admin denied)
  # ============================================================================

  describe "record authorization with non-admin context" do
    setup do
      non_admin_ctx = %Context{
        user_id: "regular_user",
        org_id: nil,
        permissions: MapSet.new([:execute, :storage_read]),
        scope: :project,
        auth_method: :api_key,
        api_key_type: :application,
        authenticated: true
      }

      {:ok, non_admin_ctx: non_admin_ctx}
    end

    test "cross-tenant record.get returns not-found", %{ctx: _ctx} do
      # Create execution in org_alpha/proj_1
      ctx_a =
        Sanctum.Context.build(
          user_id: "user_a",
          org_id: "org_alpha",
          project_id: "proj_1",
          permissions: [:*],
          scope: :project,
          auth_method: :oidc,
          authenticated: true
        )

      exec_id = "exec_cross_tenant_#{:rand.uniform(100_000)}"

      {:ok, _} =
        Arca.Execution.record_start(%{
          id: exec_id,
          reference: "reagent:local.test:0.1.0",
          user_id: ctx_a.user_id,
          org_id: ctx_a.org_id,
          project_id: ctx_a.project_id,
          component_type: "reagent",
          started_at: DateTime.utc_now(),
          status: "running",
          input: "{}"
        })

      # Different tenant tries to get it
      ctx_b =
        Sanctum.Context.build(
          user_id: "user_b",
          org_id: "org_beta",
          project_id: "proj_2",
          permissions: [:*],
          scope: :project,
          auth_method: :oidc,
          authenticated: true
        )

      {:error, msg} =
        MCP.handle("record", ctx_b, %{
          "action" => "get",
          "id" => exec_id
        })

      assert msg =~ "not found"

      # Original tenant can still get it
      {:ok, result} =
        MCP.handle("record", ctx_a, %{
          "action" => "get",
          "id" => exec_id
        })

      assert result.id == exec_id
    end

    test "non-admin cannot see other users' records", %{ctx: ctx, non_admin_ctx: non_admin_ctx} do
      # Create record for admin user via internal API
      exec_id = "exec_auth_#{:rand.uniform(100_000)}"

      {:ok, _} =
        Arca.Execution.record_start(%{
          id: exec_id,
          reference: "reagent:local.test:0.1.0",
          user_id: ctx.user_id,
          org_id: ctx.org_id,
          project_id: ctx.project_id || "default",
          component_type: "reagent",
          started_at: DateTime.utc_now(),
          status: "running",
          input: "{}"
        })

      # Non-admin trying to get another user's record should fail
      {:error, msg} =
        MCP.handle("record", non_admin_ctx, %{
          "action" => "get",
          "id" => exec_id
        })

      assert msg =~ "not found"
    end
  end

  # ============================================================================
  # Edge Cases: Retention
  # ============================================================================

  describe "retention edge cases" do
    test "cleanup with unknown type returns error", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("retention", ctx, %{
          "action" => "cleanup",
          "cleanup_type" => "unknown_type"
        })

      assert msg =~ "Cleanup failed" or msg =~ "Unknown cleanup_type"
    end

    test "defaults cleanup_type to executions", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("retention", ctx, %{
          "action" => "cleanup",
          "dry_run" => true
        })

      assert result.cleanup_type == "executions"
    end

    test "cleanup with builds type works", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("retention", ctx, %{
          "action" => "cleanup",
          "cleanup_type" => "builds",
          "dry_run" => true
        })

      assert result.cleanup_type == "builds"
    end

    test "cleanup returns integer count when not dry_run", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("retention", ctx, %{
          "action" => "cleanup",
          "cleanup_type" => "executions",
          "dry_run" => false
        })

      assert result.cleanup_type == "executions"
      assert is_integer(result.deleted)
    end
  end

  # ============================================================================
  # Tool Discovery - Updated
  # ============================================================================

  # ============================================================================
  # Tool Schema Hardening
  # ============================================================================

  describe "mcp_log tool schema" do
    test "only exposes read-only actions" do
      tools = MCP.tools()
      tool = Enum.find(tools, &(&1.name == "mcp_log"))
      actions = tool.input_schema["properties"]["action"]["enum"]
      assert actions == ["list", "get", "correlate", "stats"]

      refute "log_started" in actions
      refute "log_completed" in actions
      refute "log_failed" in actions
    end
  end

  describe "policy_log tool schema" do
    test "only exposes read-only actions" do
      tools = MCP.tools()
      tool = Enum.find(tools, &(&1.name == "policy_log"))
      actions = tool.input_schema["properties"]["action"]["enum"]
      assert actions == ["list", "get", "correlate"]

      refute "log" in actions
    end
  end

  # ============================================================================
  # MCP Log Write Actions Denied (kernel-only)
  # ============================================================================

  describe "mcp_log.log_started action (kernel-only)" do
    test "log_started is denied via MCP", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("mcp_log", ctx, %{
          "action" => "log_started",
          "id" => "req_test"
        })

      assert msg =~ "not permitted via MCP"
    end
  end

  describe "mcp_log.log_completed action (kernel-only)" do
    test "log_completed is denied via MCP", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("mcp_log", ctx, %{
          "action" => "log_completed",
          "id" => "req_test"
        })

      assert msg =~ "not permitted via MCP"
    end
  end

  describe "mcp_log.log_failed action (kernel-only)" do
    test "log_failed is denied via MCP", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("mcp_log", ctx, %{
          "action" => "log_failed",
          "id" => "req_test"
        })

      assert msg =~ "not permitted via MCP"
    end
  end

  # ============================================================================
  # Policy Log Write Action Denied (kernel-only)
  # ============================================================================

  describe "policy_log.log action (kernel-only)" do
    test "log is denied via MCP", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("policy_log", ctx, %{
          "action" => "log",
          "component_ref" => "catalyst:local.test:1.0.0",
          "decision" => "allow"
        })

      assert msg =~ "not permitted via MCP"
    end
  end

  # ============================================================================
  # MCP Log Delete Action
  # ============================================================================

  describe "mcp_log.delete action (append-only)" do
    test "deletion is denied for audit integrity", %{ctx: ctx} do
      {:error, msg} = MCP.handle("mcp_log", ctx, %{"action" => "delete", "id" => "any_id"})
      assert msg =~ "not permitted"
    end
  end

  # ============================================================================
  # Policy Log Delete Action
  # ============================================================================

  describe "policy_log.delete action (append-only)" do
    test "deletion is denied for audit integrity", %{ctx: ctx} do
      {:error, msg} = MCP.handle("policy_log", ctx, %{"action" => "delete", "id" => "any_id"})
      assert msg =~ "not permitted"
    end
  end

  # ============================================================================
  # Edge Cases: Error Paths
  # ============================================================================

  describe "resource read error paths" do
    test "handles get error other than not_found", %{ctx: ctx} do
      # read/2 with valid file
      :ok = Arca.put(ctx, ["resource_test.txt"], "content")

      {:ok, result} = MCP.read(ctx, "arca://files/resource_test.txt")
      assert Base.decode64!(result.content) == "content"
    end

    test "handles nested path in resource URI", %{ctx: ctx} do
      :ok = Arca.put(ctx, ["deep", "nested", "file.txt"], "nested content")

      {:ok, result} = MCP.read(ctx, "arca://files/deep/nested/file.txt")
      assert Base.decode64!(result.content) == "nested content"
    end
  end
end
