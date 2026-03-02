defmodule Arca.MCPTest do
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Arca.MCP

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

    # Use a test-specific base path to avoid polluting real config
    test_path = Path.join(System.tmp_dir!(), "arca_mcp_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)
      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: Context.local(), test_path: test_path}
  end

  # ============================================================================
  # Tool Discovery
  # ============================================================================

  describe "tools/0" do
    test "returns retention and execution tools" do
      tools = MCP.tools()
      assert length(tools) == 11

      tool_names = Enum.map(tools, & &1.name)
      assert "retention" in tool_names
      assert "execution" in tool_names
      assert "secret_store" in tool_names
      assert "session_store" in tool_names
      assert "api_key_store" in tool_names
      assert "permission_store" in tool_names
      assert "policy_store" in tool_names
      assert "component_store" in tool_names
      assert "mcp_log" in tool_names
      assert "policy_log" in tool_names
    end

    test "retention tool has 3 actions" do
      tools = MCP.tools()
      tool = Enum.find(tools, & &1.name == "retention")
      actions = tool.input_schema["properties"]["action"]["enum"]
      assert actions == ["get", "set", "cleanup"]
    end

    test "execution tool has 4 actions" do
      tools = MCP.tools()
      tool = Enum.find(tools, & &1.name == "execution")
      actions = tool.input_schema["properties"]["action"]["enum"]
      assert actions == ["record_start", "record_complete", "get", "list"]
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
    test "returns files resource" do
      resources = MCP.resources()
      assert length(resources) == 1

      [resource] = resources
      assert resource.uri == "arca://files/{path}"
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
      {:ok, result} = MCP.handle("retention", ctx, %{
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
      {:ok, result} = MCP.handle("retention", ctx, %{
        "action" => "set",
        "settings" => %{"executions" => 5, "builds" => 3}
      })

      assert result.updated == true
      assert result.settings["executions"] == 5
      assert result.settings["builds"] == 3

      # Verify persisted
      {:ok, get_result} = MCP.handle("retention", ctx, %{
        "action" => "get"
      })

      assert get_result.settings["executions"] == 5
    end
  end

  describe "retention cleanup action" do
    test "cleanup runs with dry_run", %{ctx: ctx} do
      {:ok, result} = MCP.handle("retention", ctx, %{
        "action" => "cleanup",
        "cleanup_type" => "executions",
        "dry_run" => true
      })

      assert result.action == "cleanup"
      assert result.dry_run == true
      assert is_list(result.would_delete)
    end

    test "cleanup runs for executions", %{ctx: ctx} do
      {:ok, result} = MCP.handle("retention", ctx, %{
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
  # Execution Tool
  # ============================================================================

  describe "execution.record_start action" do
    test "records a new execution start", %{ctx: ctx} do
      exec_id = "exec_test_#{:rand.uniform(100_000)}"

      {:ok, result} = MCP.handle("execution", ctx, %{
        "action" => "record_start",
        "id" => exec_id,
        "reference" => "reagent:local.test:0.1.0",
        "input_hash" => "abc123",
        "user_id" => "local_user",
        "component_type" => "reagent",
        "started_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "status" => "running"
      })

      assert result.recorded == true
    end
  end

  describe "execution.record_start with parent_execution_id" do
    test "records parent_execution_id", %{ctx: ctx} do
      exec_id = "exec_child_#{:rand.uniform(100_000)}"

      {:ok, result} = MCP.handle("execution", ctx, %{
        "action" => "record_start",
        "id" => exec_id,
        "reference" => "reagent:local.test:0.1.0",
        "user_id" => "local_user",
        "component_type" => "reagent",
        "started_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "parent_execution_id" => "exec_parent-abc"
      })

      assert result.recorded == true

      {:ok, record} = MCP.handle("execution", ctx, %{"action" => "get", "id" => exec_id})
      assert record.parent_execution_id == "exec_parent-abc"
    end

    test "parent_execution_id is nil when not provided", %{ctx: ctx} do
      exec_id = "exec_noparent_#{:rand.uniform(100_000)}"

      {:ok, _} = MCP.handle("execution", ctx, %{
        "action" => "record_start",
        "id" => exec_id,
        "reference" => "reagent:local.test:0.1.0",
        "user_id" => "local_user",
        "component_type" => "reagent",
        "started_at" => DateTime.to_iso8601(DateTime.utc_now())
      })

      {:ok, record} = MCP.handle("execution", ctx, %{"action" => "get", "id" => exec_id})
      assert record.parent_execution_id == nil
    end
  end

  describe "execution.list with parent_execution_id filter" do
    test "filters by parent_execution_id", %{ctx: ctx} do
      parent_id = "exec_parent_filter_#{:rand.uniform(100_000)}"

      # Create child execution with parent
      child_id = "exec_child_filter_#{:rand.uniform(100_000)}"
      {:ok, _} = MCP.handle("execution", ctx, %{
        "action" => "record_start",
        "id" => child_id,
        "reference" => "reagent:local.test:0.1.0",
        "user_id" => "local_user",
        "component_type" => "reagent",
        "started_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "parent_execution_id" => parent_id
      })

      # Create unrelated execution without parent
      other_id = "exec_other_#{:rand.uniform(100_000)}"
      {:ok, _} = MCP.handle("execution", ctx, %{
        "action" => "record_start",
        "id" => other_id,
        "reference" => "reagent:local.other:0.1.0",
        "user_id" => "local_user",
        "component_type" => "reagent",
        "started_at" => DateTime.to_iso8601(DateTime.utc_now())
      })

      {:ok, result} = MCP.handle("execution", ctx, %{
        "action" => "list",
        "user_id" => "local_user",
        "parent_execution_id" => parent_id
      })

      ids = Enum.map(result.executions, & &1.id)
      assert child_id in ids
      refute other_id in ids
    end
  end

  describe "execution.record_complete action" do
    test "records execution completion", %{ctx: ctx} do
      exec_id = "exec_complete_#{:rand.uniform(100_000)}"

      # First record start
      {:ok, _} = MCP.handle("execution", ctx, %{
        "action" => "record_start",
        "id" => exec_id,
        "reference" => "reagent:local.test:0.1.0",
        "user_id" => "local_user",
        "component_type" => "reagent",
        "started_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "status" => "running"
      })

      # Then record completion
      {:ok, result} = MCP.handle("execution", ctx, %{
        "action" => "record_complete",
        "id" => exec_id,
        "completed_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "duration_ms" => 150,
        "status" => "completed"
      })

      assert result.recorded == true
    end

    test "returns error without id", %{ctx: ctx} do
      {:error, msg} = MCP.handle("execution", ctx, %{"action" => "record_complete"})
      assert msg =~ "Missing required"
    end
  end

  describe "execution.get action" do
    test "returns execution by id", %{ctx: ctx} do
      exec_id = "exec_get_#{:rand.uniform(100_000)}"

      {:ok, _} = MCP.handle("execution", ctx, %{
        "action" => "record_start",
        "id" => exec_id,
        "reference" => "reagent:local.test:0.1.0",
        "user_id" => "local_user",
        "component_type" => "reagent",
        "started_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "status" => "running"
      })

      {:ok, result} = MCP.handle("execution", ctx, %{
        "action" => "get",
        "id" => exec_id
      })

      assert result.id == exec_id
      assert result.status == "running"
      assert result.user_id == "local_user"
    end

    test "returns error for nonexistent execution", %{ctx: ctx} do
      {:error, msg} = MCP.handle("execution", ctx, %{
        "action" => "get",
        "id" => "nonexistent_id"
      })

      assert msg =~ "not found"
    end

    test "returns error without id", %{ctx: ctx} do
      {:error, msg} = MCP.handle("execution", ctx, %{"action" => "get"})
      assert msg =~ "Missing required"
    end
  end

  describe "execution.list action" do
    test "returns empty list when no executions", %{ctx: ctx} do
      {:ok, result} = MCP.handle("execution", ctx, %{"action" => "list"})
      assert is_list(result.executions)
    end

    test "returns executions after recording", %{ctx: ctx} do
      exec_id = "exec_list_#{:rand.uniform(100_000)}"

      {:ok, _} = MCP.handle("execution", ctx, %{
        "action" => "record_start",
        "id" => exec_id,
        "reference" => "reagent:local.test:0.1.0",
        "user_id" => "local_user",
        "component_type" => "reagent",
        "started_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "status" => "running"
      })

      {:ok, result} = MCP.handle("execution", ctx, %{
        "action" => "list",
        "user_id" => "local_user"
      })

      ids = Enum.map(result.executions, & &1.id)
      assert exec_id in ids
    end

    test "invalid action returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("execution", ctx, %{"action" => "invalid"})
      assert msg =~ "Invalid execution action"
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
        permissions: MapSet.new([:execute]),
        scope: :personal,
        auth_method: :api_key,
        api_key_type: :application
      }

      {:ok, app_ctx: app_ctx}
    end

    test "can get retention settings", %{app_ctx: app_ctx} do
      {:ok, result} = MCP.handle("retention", app_ctx, %{"action" => "get"})
      assert is_map(result.settings)
    end

    test "cannot set retention settings", %{app_ctx: app_ctx} do
      {:error, msg} = MCP.handle("retention", app_ctx, %{
        "action" => "set",
        "settings" => %{"executions" => 5}
      })

      assert msg =~ "Unauthorized"
      assert msg =~ "admin"
    end

    test "cannot run cleanup", %{app_ctx: app_ctx} do
      {:error, msg} = MCP.handle("retention", app_ctx, %{
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
        permissions: MapSet.new([:execute, :read, :write]),
        scope: :personal,
        auth_method: :oidc,
        api_key_type: nil,
        session_id: "session_123"
      }

      {:ok, oidc_ctx: oidc_ctx}
    end

    test "can set retention settings", %{oidc_ctx: oidc_ctx} do
      {:ok, result} = MCP.handle("retention", oidc_ctx, %{
        "action" => "set",
        "settings" => %{"executions" => 5}
      })

      assert result.updated == true
    end

    test "can run cleanup", %{oidc_ctx: oidc_ctx} do
      {:ok, result} = MCP.handle("retention", oidc_ctx, %{
        "action" => "cleanup",
        "cleanup_type" => "executions",
        "dry_run" => true
      })

      assert result.dry_run == true
    end
  end

  # ============================================================================
  # Edge Cases: Retention
  # ============================================================================

  describe "retention edge cases" do
    test "cleanup with unknown type returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("retention", ctx, %{
        "action" => "cleanup",
        "cleanup_type" => "unknown_type"
      })

      assert msg =~ "Unknown cleanup_type"
    end

    test "defaults cleanup_type to executions", %{ctx: ctx} do
      {:ok, result} = MCP.handle("retention", ctx, %{
        "action" => "cleanup",
        "dry_run" => true
      })

      assert result.cleanup_type == "executions"
    end

    test "cleanup with builds type works", %{ctx: ctx} do
      {:ok, result} = MCP.handle("retention", ctx, %{
        "action" => "cleanup",
        "cleanup_type" => "builds",
        "dry_run" => true
      })

      assert result.cleanup_type == "builds"
    end

    test "cleanup returns integer count when not dry_run", %{ctx: ctx} do
      {:ok, result} = MCP.handle("retention", ctx, %{
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

  describe "tools/0 includes new tools" do
    test "returns all expected tools" do
      tools = MCP.tools()
      tool_names = Enum.map(tools, & &1.name)
      assert "secret_store" in tool_names
      assert "session_store" in tool_names
      assert "api_key_store" in tool_names
      assert "permission_store" in tool_names
      assert "policy_store" in tool_names
      assert "component_store" in tool_names
      assert "retention" in tool_names
      assert "execution" in tool_names
    end
  end

  # ============================================================================
  # Secret Store Tool
  # ============================================================================

  describe "secret_store tool" do
    test "put and get secret", %{ctx: ctx} do
      encrypted = :crypto.strong_rand_bytes(32)

      {:ok, _} = MCP.handle("secret_store", ctx, %{
        "action" => "put",
        "name" => "TEST_SECRET",
        "encrypted_value" => Base.encode64(encrypted),
        "scope" => "personal",
        "org_id" => nil
      })

      {:ok, result} = MCP.handle("secret_store", ctx, %{
        "action" => "get",
        "name" => "TEST_SECRET",
        "scope" => "personal",
        "org_id" => nil
      })

      assert Base.decode64!(result.encrypted_value) == encrypted
    end

    test "list secrets", %{ctx: ctx} do
      {:ok, _} = MCP.handle("secret_store", ctx, %{
        "action" => "put",
        "name" => "LIST_TEST",
        "encrypted_value" => Base.encode64("test"),
        "scope" => "personal",
        "org_id" => nil
      })

      {:ok, result} = MCP.handle("secret_store", ctx, %{
        "action" => "list",
        "scope" => "personal",
        "org_id" => nil
      })

      assert "LIST_TEST" in result.names
    end

    test "delete secret", %{ctx: ctx} do
      {:ok, _} = MCP.handle("secret_store", ctx, %{
        "action" => "put",
        "name" => "DELETE_ME",
        "encrypted_value" => Base.encode64("test"),
        "scope" => "personal",
        "org_id" => nil
      })

      {:ok, _} = MCP.handle("secret_store", ctx, %{
        "action" => "delete",
        "name" => "DELETE_ME",
        "scope" => "personal",
        "org_id" => nil
      })

      {:error, :not_found} = MCP.handle("secret_store", ctx, %{
        "action" => "get",
        "name" => "DELETE_ME",
        "scope" => "personal",
        "org_id" => nil
      })
    end

    test "put_grant and list_grants", %{ctx: ctx} do
      {:ok, _} = MCP.handle("secret_store", ctx, %{
        "action" => "put",
        "name" => "GRANT_SECRET",
        "encrypted_value" => Base.encode64("test"),
        "scope" => "personal",
        "org_id" => nil
      })

      {:ok, _} = MCP.handle("secret_store", ctx, %{
        "action" => "put_grant",
        "name" => "GRANT_SECRET",
        "component_ref" => "catalyst:local.test-catalyst:1.0.0",
        "scope" => "personal",
        "org_id" => nil
      })

      {:ok, result} = MCP.handle("secret_store", ctx, %{
        "action" => "list_grants",
        "name" => "GRANT_SECRET",
        "scope" => "personal",
        "org_id" => nil
      })

      assert "catalyst:local.test-catalyst:1.0.0" in result.grants
    end

    test "grants_for_component", %{ctx: ctx} do
      {:ok, _} = MCP.handle("secret_store", ctx, %{
        "action" => "put",
        "name" => "COMP_SECRET",
        "encrypted_value" => Base.encode64("test"),
        "scope" => "personal",
        "org_id" => nil
      })

      {:ok, _} = MCP.handle("secret_store", ctx, %{
        "action" => "put_grant",
        "name" => "COMP_SECRET",
        "component_ref" => "reagent:local.comp-test:1.0.0",
        "scope" => "personal",
        "org_id" => nil
      })

      {:ok, result} = MCP.handle("secret_store", ctx, %{
        "action" => "grants_for_component",
        "component_ref" => "reagent:local.comp-test:1.0.0",
        "scope" => "personal",
        "org_id" => nil
      })

      assert "COMP_SECRET" in result.secret_names
    end

    test "delete_grant", %{ctx: ctx} do
      {:ok, _} = MCP.handle("secret_store", ctx, %{
        "action" => "put",
        "name" => "DEL_GRANT_SEC",
        "encrypted_value" => Base.encode64("test"),
        "scope" => "personal",
        "org_id" => nil
      })

      {:ok, _} = MCP.handle("secret_store", ctx, %{
        "action" => "put_grant",
        "name" => "DEL_GRANT_SEC",
        "component_ref" => "reagent:local.del-test:1.0.0",
        "scope" => "personal",
        "org_id" => nil
      })

      {:ok, _} = MCP.handle("secret_store", ctx, %{
        "action" => "delete_grant",
        "name" => "DEL_GRANT_SEC",
        "component_ref" => "reagent:local.del-test:1.0.0",
        "scope" => "personal",
        "org_id" => nil
      })

      {:ok, result} = MCP.handle("secret_store", ctx, %{
        "action" => "list_grants",
        "name" => "DEL_GRANT_SEC",
        "scope" => "personal",
        "org_id" => nil
      })

      refute "reagent:local.del-test:1.0.0" in result.grants
    end

    test "delete_grants_for_component removes all grants for a component", %{ctx: ctx} do
      # Create two grants for the same component across different secrets
      {:ok, _} = MCP.handle("secret_store", ctx, %{
        "action" => "put",
        "name" => "SECRET_A",
        "encrypted_value" => Base.encode64("val_a"),
        "scope" => "personal",
        "org_id" => nil
      })

      {:ok, _} = MCP.handle("secret_store", ctx, %{
        "action" => "put",
        "name" => "SECRET_B",
        "encrypted_value" => Base.encode64("val_b"),
        "scope" => "personal",
        "org_id" => nil
      })

      ref = "catalyst:local.bulk-del-test:1.0.0"

      {:ok, _} = MCP.handle("secret_store", ctx, %{
        "action" => "put_grant",
        "name" => "SECRET_A",
        "component_ref" => ref,
        "scope" => "personal",
        "org_id" => nil
      })

      {:ok, _} = MCP.handle("secret_store", ctx, %{
        "action" => "put_grant",
        "name" => "SECRET_B",
        "component_ref" => ref,
        "scope" => "personal",
        "org_id" => nil
      })

      # Verify grants exist
      {:ok, result} = MCP.handle("secret_store", ctx, %{
        "action" => "grants_for_component",
        "component_ref" => ref,
        "scope" => "personal",
        "org_id" => nil
      })
      assert length(result.secret_names) == 2

      # Bulk delete all grants for the component
      {:ok, %{deleted: true}} = MCP.handle("secret_store", ctx, %{
        "action" => "delete_grants_for_component",
        "component_ref" => ref
      })

      # Verify grants are gone
      {:ok, result2} = MCP.handle("secret_store", ctx, %{
        "action" => "grants_for_component",
        "component_ref" => ref,
        "scope" => "personal",
        "org_id" => nil
      })
      assert result2.secret_names == []
    end

    test "delete_grants_for_component requires component_ref", %{ctx: ctx} do
      {:error, msg} = MCP.handle("secret_store", ctx, %{"action" => "delete_grants_for_component"})
      assert msg =~ "Missing required argument: component_ref"
    end

    test "invalid action returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("secret_store", ctx, %{"action" => "invalid"})
      assert msg =~ "Invalid secret_store action"
    end

    test "missing params returns error", %{ctx: ctx} do
      {:error, _} = MCP.handle("secret_store", ctx, %{"action" => "put"})
      {:error, _} = MCP.handle("secret_store", ctx, %{"action" => "get"})
    end
  end

  # ============================================================================
  # Session Store Tool
  # ============================================================================

  describe "session_store tool" do
    test "create and get session", %{ctx: ctx} do
      token_hash = :crypto.hash(:sha256, "test_token")

      {:ok, _} = MCP.handle("session_store", ctx, %{
        "action" => "create",
        "token_hash" => Base.encode64(token_hash),
        "attrs" => %{
          "token_prefix" => "test1234",
          "user_id" => "user_123",
          "email" => "test@example.com",
          "provider" => "github",
          "permissions" => "[\"execute\"]",
          "expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 86400, :second)),
          "inserted_at" => DateTime.to_iso8601(DateTime.utc_now())
        }
      })

      {:ok, result} = MCP.handle("session_store", ctx, %{
        "action" => "get",
        "token_hash" => Base.encode64(token_hash)
      })

      assert result.session.user_id == "user_123"
    end

    test "delete session", %{ctx: ctx} do
      token_hash = :crypto.hash(:sha256, "delete_token")

      {:ok, _} = MCP.handle("session_store", ctx, %{
        "action" => "create",
        "token_hash" => Base.encode64(token_hash),
        "attrs" => %{
          "token_prefix" => "del12345",
          "user_id" => "user_del",
          "provider" => "github",
          "permissions" => "[]",
          "expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 86400, :second)),
          "inserted_at" => DateTime.to_iso8601(DateTime.utc_now())
        }
      })

      {:ok, _} = MCP.handle("session_store", ctx, %{
        "action" => "delete",
        "token_hash" => Base.encode64(token_hash)
      })

      {:error, :not_found} = MCP.handle("session_store", ctx, %{
        "action" => "get",
        "token_hash" => Base.encode64(token_hash)
      })
    end

    test "list_active sessions", %{ctx: ctx} do
      {:ok, result} = MCP.handle("session_store", ctx, %{"action" => "list_active"})
      assert is_list(result.sessions)
    end

    test "cleanup_expired", %{ctx: ctx} do
      {:ok, result} = MCP.handle("session_store", ctx, %{"action" => "cleanup_expired"})
      assert is_integer(result.cleaned)
    end

    test "put_revocation and check_revoked", %{ctx: ctx} do
      {:ok, _} = MCP.handle("session_store", ctx, %{
        "action" => "put_revocation",
        "session_id" => "rev_test_123",
        "revoked_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 86400, :second))
      })

      {:ok, result} = MCP.handle("session_store", ctx, %{
        "action" => "check_revoked",
        "session_id" => "rev_test_123"
      })

      assert result.revoked == true
    end

    test "cleanup_revocations", %{ctx: ctx} do
      {:ok, result} = MCP.handle("session_store", ctx, %{"action" => "cleanup_revocations"})
      assert is_integer(result.cleaned)
    end

    test "invalid action returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("session_store", ctx, %{"action" => "invalid"})
      assert msg =~ "Invalid session_store action"
    end
  end

  # ============================================================================
  # API Key Store Tool
  # ============================================================================

  describe "api_key_store tool" do
    test "create and get key", %{ctx: ctx} do
      key_hash = :crypto.hash(:sha256, "test_api_key")

      {:ok, _} = MCP.handle("api_key_store", ctx, %{
        "action" => "create",
        "attrs" => %{
          "name" => "test-key-mcp",
          "key_hash" => Base.encode64(key_hash),
          "key_prefix" => "cyfr_pk_test",
          "type" => "public",
          "scope" => "[\"execute\"]",
          "created_by" => "local_user",
          "scope_type" => "personal",
          "org_id" => nil
        }
      })

      {:ok, result} = MCP.handle("api_key_store", ctx, %{
        "action" => "get",
        "name" => "test-key-mcp",
        "scope_type" => "personal",
        "org_id" => nil
      })

      assert result.key.name == "test-key-mcp"
    end

    test "list keys", %{ctx: ctx} do
      {:ok, result} = MCP.handle("api_key_store", ctx, %{
        "action" => "list",
        "scope_type" => "personal",
        "org_id" => nil
      })

      assert is_list(result.keys)
    end

    test "get_by_hash", %{ctx: ctx} do
      key_hash = :crypto.hash(:sha256, "hash_lookup_key")

      {:ok, _} = MCP.handle("api_key_store", ctx, %{
        "action" => "create",
        "attrs" => %{
          "name" => "hash-lookup-key",
          "key_hash" => Base.encode64(key_hash),
          "key_prefix" => "cyfr_pk_hash",
          "type" => "public",
          "scope" => "[]",
          "created_by" => "local_user",
          "scope_type" => "personal",
          "org_id" => nil
        }
      })

      {:ok, result} = MCP.handle("api_key_store", ctx, %{
        "action" => "get_by_hash",
        "key_hash" => Base.encode64(key_hash)
      })

      assert result.key.name == "hash-lookup-key"
    end

    test "revoke key", %{ctx: ctx} do
      key_hash = :crypto.hash(:sha256, "revoke_key")

      {:ok, _} = MCP.handle("api_key_store", ctx, %{
        "action" => "create",
        "attrs" => %{
          "name" => "revoke-me",
          "key_hash" => Base.encode64(key_hash),
          "key_prefix" => "cyfr_pk_rev",
          "type" => "public",
          "scope" => "[]",
          "created_by" => "local_user",
          "scope_type" => "personal",
          "org_id" => nil
        }
      })

      {:ok, _} = MCP.handle("api_key_store", ctx, %{
        "action" => "revoke",
        "name" => "revoke-me",
        "scope_type" => "personal",
        "org_id" => nil
      })
    end

    test "invalid action returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("api_key_store", ctx, %{"action" => "invalid"})
      assert msg =~ "Invalid api_key_store action"
    end
  end

  # ============================================================================
  # Permission Store Tool
  # ============================================================================

  describe "permission_store tool" do
    test "set and get permissions", %{ctx: ctx} do
      {:ok, _} = MCP.handle("permission_store", ctx, %{
        "action" => "set",
        "subject" => "perm_test_user",
        "permissions" => "[\"execute\", \"read\"]",
        "scope_type" => "personal",
        "org_id" => nil
      })

      {:ok, result} = MCP.handle("permission_store", ctx, %{
        "action" => "get",
        "subject" => "perm_test_user",
        "scope_type" => "personal",
        "org_id" => nil
      })

      assert result.permissions == "[\"execute\", \"read\"]"
    end

    test "list permissions", %{ctx: ctx} do
      {:ok, _} = MCP.handle("permission_store", ctx, %{
        "action" => "set",
        "subject" => "list_perm_user",
        "permissions" => "[\"execute\"]",
        "scope_type" => "personal",
        "org_id" => nil
      })

      {:ok, result} = MCP.handle("permission_store", ctx, %{
        "action" => "list",
        "scope_type" => "personal",
        "org_id" => nil
      })

      assert is_list(result.entries)
      subjects = Enum.map(result.entries, & &1.subject)
      assert "list_perm_user" in subjects
    end

    test "delete permissions", %{ctx: ctx} do
      {:ok, _} = MCP.handle("permission_store", ctx, %{
        "action" => "set",
        "subject" => "del_perm_user",
        "permissions" => "[\"execute\"]",
        "scope_type" => "personal",
        "org_id" => nil
      })

      {:ok, _} = MCP.handle("permission_store", ctx, %{
        "action" => "delete",
        "subject" => "del_perm_user",
        "scope_type" => "personal",
        "org_id" => nil
      })

      {:error, :not_found} = MCP.handle("permission_store", ctx, %{
        "action" => "get",
        "subject" => "del_perm_user",
        "scope_type" => "personal",
        "org_id" => nil
      })
    end

    test "invalid action returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("permission_store", ctx, %{"action" => "invalid"})
      assert msg =~ "Invalid permission_store action"
    end
  end

  # ============================================================================
  # Policy Store Tool
  # ============================================================================

  describe "policy_store tool" do
    test "put and get policy", %{ctx: ctx} do
      {:ok, _} = MCP.handle("policy_store", ctx, %{
        "action" => "put",
        "attrs" => %{
          "id" => "pol_test123",
          "component_ref" => "reagent:local.test-policy-comp:1.0.0",
          "component_type" => "reagent",
          "allowed_domains" => "[]",
          "allowed_methods" => "[\"GET\"]",
          "timeout" => "30s",
          "max_memory_bytes" => 67108864,
          "inserted_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "updated_at" => DateTime.to_iso8601(DateTime.utc_now())
        }
      })

      {:ok, result} = MCP.handle("policy_store", ctx, %{
        "action" => "get",
        "component_ref" => "reagent:local.test-policy-comp:1.0.0"
      })

      assert result.policy.component_ref == "reagent:local.test-policy-comp:1.0.0"
    end

    test "list policies", %{ctx: ctx} do
      {:ok, result} = MCP.handle("policy_store", ctx, %{"action" => "list"})
      assert is_list(result.policies)
    end

    test "delete policy", %{ctx: ctx} do
      {:ok, _} = MCP.handle("policy_store", ctx, %{
        "action" => "put",
        "attrs" => %{
          "id" => "pol_del123",
          "component_ref" => "reagent:local.del-policy-comp:1.0.0",
          "component_type" => "reagent",
          "allowed_domains" => "[]",
          "timeout" => "30s",
          "inserted_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "updated_at" => DateTime.to_iso8601(DateTime.utc_now())
        }
      })

      {:ok, _} = MCP.handle("policy_store", ctx, %{
        "action" => "delete",
        "component_ref" => "reagent:local.del-policy-comp:1.0.0"
      })

      {:error, :not_found} = MCP.handle("policy_store", ctx, %{
        "action" => "get",
        "component_ref" => "reagent:local.del-policy-comp:1.0.0"
      })
    end

    test "invalid action returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("policy_store", ctx, %{"action" => "invalid"})
      assert msg =~ "Invalid policy_store action"
    end
  end

  # ============================================================================
  # Component Store Tool
  # ============================================================================

  describe "component_store tool" do
    test "put and get component", %{ctx: ctx} do
      {:ok, _} = MCP.handle("component_store", ctx, %{
        "action" => "put",
        "attrs" => %{
          "id" => "comp_test123",
          "name" => "test-component",
          "version" => "1.0.0",
          "component_type" => "reagent",
          "description" => "Test component",
          "tags" => "[]",
          "digest" => "sha256:abc123",
          "size" => 1024,
          "exports" => "[]",
          "publisher" => "local",
          "publisher_id" => "local_user",
          "inserted_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "updated_at" => DateTime.to_iso8601(DateTime.utc_now())
        }
      })

      {:ok, result} = MCP.handle("component_store", ctx, %{
        "action" => "get",
        "name" => "test-component",
        "version" => "1.0.0"
      })

      assert result.component.name == "test-component"
    end

    test "list components", %{ctx: ctx} do
      {:ok, result} = MCP.handle("component_store", ctx, %{"action" => "list"})
      assert is_list(result.components)
    end

    test "exists check", %{ctx: ctx} do
      {:ok, result} = MCP.handle("component_store", ctx, %{
        "action" => "exists",
        "name" => "nonexistent-comp",
        "version" => "1.0.0"
      })

      assert result.exists == false
    end

    test "delete component", %{ctx: ctx} do
      {:ok, _} = MCP.handle("component_store", ctx, %{
        "action" => "put",
        "attrs" => %{
          "id" => "comp_del123",
          "name" => "del-component",
          "version" => "1.0.0",
          "component_type" => "reagent",
          "description" => "Delete me",
          "tags" => "[]",
          "digest" => "sha256:del123",
          "size" => 512,
          "exports" => "[]",
          "publisher" => "local",
          "publisher_id" => "local_user",
          "inserted_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "updated_at" => DateTime.to_iso8601(DateTime.utc_now())
        }
      })

      {:ok, _} = MCP.handle("component_store", ctx, %{
        "action" => "delete",
        "name" => "del-component",
        "version" => "1.0.0"
      })

      {:error, :not_found} = MCP.handle("component_store", ctx, %{
        "action" => "get",
        "name" => "del-component",
        "version" => "1.0.0"
      })
    end

    test "invalid action returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("component_store", ctx, %{"action" => "invalid"})
      assert msg =~ "Invalid component_store action"
    end
  end

  # ============================================================================
  # MCP Log Delete Action
  # ============================================================================

  describe "mcp_log.delete action" do
    test "deletes an existing MCP log", %{ctx: ctx} do
      req_id = "req_del_#{:rand.uniform(100_000)}"

      {:ok, _} = MCP.handle("mcp_log", ctx, %{
        "action" => "log_started",
        "id" => req_id,
        "tool" => "test",
        "input" => %{}
      })

      {:ok, _} = MCP.handle("mcp_log", ctx, %{"action" => "get", "id" => req_id})

      {:ok, result} = MCP.handle("mcp_log", ctx, %{"action" => "delete", "id" => req_id})
      assert result.deleted == true

      {:error, _} = MCP.handle("mcp_log", ctx, %{"action" => "get", "id" => req_id})
    end

    test "returns error for nonexistent log", %{ctx: ctx} do
      {:error, msg} = MCP.handle("mcp_log", ctx, %{"action" => "delete", "id" => "nonexistent"})
      assert msg =~ "not found"
    end

    test "returns error without id", %{ctx: ctx} do
      {:error, msg} = MCP.handle("mcp_log", ctx, %{"action" => "delete"})
      assert msg =~ "Missing required"
    end
  end

  # ============================================================================
  # Policy Log Delete Action
  # ============================================================================

  describe "policy_log.delete action" do
    test "deletes an existing policy log", %{ctx: ctx} do
      {:ok, _} = MCP.handle("policy_log", ctx, %{
        "action" => "log",
        "event_type" => "policy_consultation",
        "component_ref" => "reagent:local.test:1.0.0",
        "decision" => "allowed"
      })

      {:ok, %{logs: logs}} = MCP.handle("policy_log", ctx, %{"action" => "list"})
      assert length(logs) >= 1

      log = hd(logs)
      {:ok, result} = MCP.handle("policy_log", ctx, %{"action" => "delete", "id" => log.id})
      assert result.deleted == true
    end

    test "returns error for nonexistent log", %{ctx: ctx} do
      {:error, msg} = MCP.handle("policy_log", ctx, %{"action" => "delete", "id" => "nonexistent"})
      assert msg =~ "not found"
    end

    test "returns error without id", %{ctx: ctx} do
      {:error, msg} = MCP.handle("policy_log", ctx, %{"action" => "delete"})
      assert msg =~ "Missing required"
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
