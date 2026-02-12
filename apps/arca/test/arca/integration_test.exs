defmodule Arca.IntegrationTest do
  @moduledoc """
  Integration tests for Arca storage service.

  Tests full workflows including:
  - CRUD cycles (list → write → read → delete)
  - Retention workflows (set settings → create data → cleanup → verify)
  - User isolation verification
  - MCP tool integration
  """

  use ExUnit.Case, async: false

  alias Arca.MCP
  alias Arca.Retention
  alias Sanctum.Context

  setup do
    test_path = Path.join(System.tmp_dir!(), "arca_integration_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    # Checkout Ecto sandbox for SQLite-based operations
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

    ctx = Context.local()

    on_exit(fn ->
      File.rm_rf!(test_path)
      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: ctx, test_path: test_path}
  end

  # ============================================================================
  # Full CRUD Workflow
  # ============================================================================

  describe "list → write → read → delete workflow" do
    test "complete file lifecycle via Arca API", %{ctx: ctx} do
      # 1. List - should start empty
      {:ok, files} = Arca.list(ctx, ["workflow"])
      assert files == []

      # 2. Write - create a file
      :ok = Arca.put(ctx, ["workflow", "test.txt"], "hello world")

      # 3. List - should now contain the file
      {:ok, files} = Arca.list(ctx, ["workflow"])
      assert "test.txt" in files

      # 4. Read - verify content
      {:ok, content} = Arca.get(ctx, ["workflow", "test.txt"])
      assert content == "hello world"

      # 5. Exists - verify existence
      assert Arca.exists?(ctx, ["workflow", "test.txt"])

      # 6. Delete - remove the file
      :ok = Arca.delete(ctx, ["workflow", "test.txt"])

      # 7. Verify deletion
      refute Arca.exists?(ctx, ["workflow", "test.txt"])
      {:error, :not_found} = Arca.get(ctx, ["workflow", "test.txt"])
    end

    test "complete file lifecycle via MCP tool", %{ctx: ctx} do
      # 1. List - should start empty
      {:ok, result} = MCP.handle("storage", ctx, %{"action" => "list", "path" => "mcp_workflow"})
      assert result.files == []

      # 2. Write - create a file
      {:ok, write_result} = MCP.handle("storage", ctx, %{
        "action" => "write",
        "path" => "mcp_workflow/data.json",
        "content" => Base.encode64(~s|{"status": "created"}|)
      })
      assert write_result.written == true

      # 3. List - should now contain the file
      {:ok, result} = MCP.handle("storage", ctx, %{"action" => "list", "path" => "mcp_workflow"})
      assert "data.json" in result.files

      # 4. Read - verify content
      {:ok, read_result} = MCP.handle("storage", ctx, %{
        "action" => "read",
        "path" => "mcp_workflow/data.json"
      })
      assert Base.decode64!(read_result.content) == ~s|{"status": "created"}|

      # 5. Delete - remove the file
      {:ok, delete_result} = MCP.handle("storage", ctx, %{
        "action" => "delete",
        "path" => "mcp_workflow/data.json"
      })
      assert delete_result.deleted == true

      # 6. Verify deletion (list should be empty again)
      {:ok, result} = MCP.handle("storage", ctx, %{"action" => "list", "path" => "mcp_workflow"})
      assert result.files == []
    end
  end

  # ============================================================================
  # Retention Workflow
  # ============================================================================

  describe "retention workflow: set settings → create data → cleanup → verify" do
    test "execution retention workflow", %{ctx: ctx} do
      # 1. Set retention to keep only 3 executions
      :ok = Retention.set_settings(ctx, %{"executions" => 3})

      # Verify settings
      settings = Retention.get_settings(ctx)
      assert settings["executions"] == 3

      # 2. Create 5 executions with different timestamps via SQLite
      for i <- 1..5 do
        timestamp = "2025-01-#{String.pad_leading("#{i}", 2, "0")}T10:00:00Z"
        {:ok, dt, _} = DateTime.from_iso8601(timestamp)

        Arca.Execution.record_start(%{
          id: "exec_#{i}",
          request_id: "req_test",
          user_id: ctx.user_id,
          reference: Jason.encode!(%{"local" => "test.wasm"}),
          component_type: "reagent",
          started_at: dt,
          status: "running"
        })
      end

      # Verify all 5 exist
      records = Arca.Execution.list(user_id: ctx.user_id, limit: 100)
      assert length(records) == 5

      # 3. Run cleanup (dry_run first)
      {:ok, dry_result} = Retention.cleanup_executions(ctx, dry_run: true)
      assert length(dry_result.would_delete) == 2
      assert dry_result.would_keep == 3

      # 4. Actually run cleanup
      {:ok, count} = Retention.cleanup_executions(ctx)
      assert count == 2

      # 5. Verify only 3 remain
      records = Arca.Execution.list(user_id: ctx.user_id, limit: 100)
      assert length(records) == 3

      # The 3 newest (exec_3, exec_4, exec_5) should remain
      ids = Enum.map(records, & &1.id)
      assert "exec_3" in ids
      assert "exec_4" in ids
      assert "exec_5" in ids
    end

    test "audit retention workflow", %{ctx: ctx} do
      # 1. Set retention to keep 7 days of audit logs
      :ok = Retention.set_settings(ctx, %{"audit_days" => 7})

      # 2. Create audit events spanning 30 days via SQLite
      # Use 5 days (clearly within 7-day window) instead of 7 to avoid boundary issues
      for days_ago <- [0, 3, 5, 14, 21, 28] do
        timestamp = DateTime.utc_now() |> DateTime.add(-days_ago * 86400, :second)

        Arca.AuditEvent.record(%{
          id: "audit_#{:rand.uniform(999_999_999)}",
          user_id: ctx.user_id,
          timestamp: timestamp,
          event_type: "test",
          data: Jason.encode!(%{"event" => "test"})
        })
      end

      # Verify all 6 exist
      records = Arca.AuditEvent.list(user_id: ctx.user_id, limit: 100)
      assert length(records) == 6

      # 3. Dry run cleanup
      {:ok, dry_result} = Retention.cleanup_audit(ctx, dry_run: true)
      # Events older than 7 days should be marked for deletion (14, 21, 28 days old)
      assert length(dry_result.would_delete) == 3
      assert dry_result.would_keep == 3

      # 4. Run actual cleanup
      {:ok, count} = Retention.cleanup_audit(ctx)
      assert count == 3

      # 5. Verify only recent events remain
      records = Arca.AuditEvent.list(user_id: ctx.user_id, limit: 100)
      assert length(records) == 3
    end

    test "retention workflow via MCP", %{ctx: ctx} do
      # 1. Set retention via MCP
      {:ok, set_result} = MCP.handle("storage", ctx, %{
        "action" => "retention",
        "retention_action" => "set",
        "settings" => %{"executions" => 2}
      })
      assert set_result.updated == true
      assert set_result.settings["executions"] == 2

      # 2. Create 4 executions via SQLite
      for i <- 1..4 do
        timestamp = "2025-01-#{String.pad_leading("#{i}", 2, "0")}T10:00:00Z"
        {:ok, dt, _} = DateTime.from_iso8601(timestamp)

        Arca.Execution.record_start(%{
          id: "mcp_exec_#{i}",
          request_id: "req_test",
          user_id: ctx.user_id,
          reference: Jason.encode!(%{"local" => "test.wasm"}),
          component_type: "reagent",
          started_at: dt,
          status: "running"
        })
      end

      # 3. Dry run via MCP
      {:ok, dry_result} = MCP.handle("storage", ctx, %{
        "action" => "retention",
        "retention_action" => "cleanup",
        "cleanup_type" => "executions",
        "dry_run" => true
      })
      assert length(dry_result.would_delete) == 2
      assert dry_result.would_keep == 2

      # 4. Actual cleanup via MCP
      {:ok, cleanup_result} = MCP.handle("storage", ctx, %{
        "action" => "retention",
        "retention_action" => "cleanup",
        "cleanup_type" => "executions"
      })
      assert cleanup_result.deleted == 2

      # 5. Verify via MCP get
      {:ok, get_result} = MCP.handle("storage", ctx, %{
        "action" => "retention",
        "retention_action" => "get"
      })
      assert get_result.settings["executions"] == 2
    end
  end

  # ============================================================================
  # User Isolation
  # ============================================================================

  describe "user isolation" do
    test "different users cannot access each other's files" do
      user1_ctx = %Context{
        user_id: "user_alpha",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :personal,
        auth_method: :local,
        api_key_type: nil
      }

      user2_ctx = %Context{
        user_id: "user_beta",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :personal,
        auth_method: :local,
        api_key_type: nil
      }

      # User 1 creates a file
      :ok = Arca.put(user1_ctx, ["private", "secret.txt"], "user1 secret")

      # User 1 can read it
      {:ok, content} = Arca.get(user1_ctx, ["private", "secret.txt"])
      assert content == "user1 secret"

      # User 2 cannot read it (different user directory)
      {:error, :not_found} = Arca.get(user2_ctx, ["private", "secret.txt"])

      # User 2 creates their own file at same logical path
      :ok = Arca.put(user2_ctx, ["private", "secret.txt"], "user2 secret")

      # Each user sees their own content
      {:ok, u1_content} = Arca.get(user1_ctx, ["private", "secret.txt"])
      {:ok, u2_content} = Arca.get(user2_ctx, ["private", "secret.txt"])

      assert u1_content == "user1 secret"
      assert u2_content == "user2 secret"
    end

    test "user execution cleanup only affects their executions" do
      user1_ctx = %Context{
        user_id: "cleanup_user_1",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :personal,
        auth_method: :local,
        api_key_type: nil
      }

      user2_ctx = %Context{
        user_id: "cleanup_user_2",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :personal,
        auth_method: :local,
        api_key_type: nil
      }

      # Each user creates 3 executions via SQLite
      for i <- 1..3 do
        ts = "2025-01-0#{i}T10:00:00Z"
        {:ok, dt, _} = DateTime.from_iso8601(ts)

        Arca.Execution.record_start(%{
          id: "u1_exec_#{i}",
          request_id: "req_test",
          user_id: user1_ctx.user_id,
          reference: Jason.encode!(%{"local" => "test.wasm"}),
          component_type: "reagent",
          started_at: dt,
          status: "running"
        })

        Arca.Execution.record_start(%{
          id: "u2_exec_#{i}",
          request_id: "req_test",
          user_id: user2_ctx.user_id,
          reference: Jason.encode!(%{"local" => "test.wasm"}),
          component_type: "reagent",
          started_at: dt,
          status: "running"
        })
      end

      # User 1 cleans up, keeping only 1
      {:ok, count} = Retention.cleanup_executions(user1_ctx, keep: 1)
      assert count == 2

      # User 1 should have 1 execution
      u1_records = Arca.Execution.list(user_id: "cleanup_user_1", limit: 100)
      assert length(u1_records) == 1

      # User 2 should still have all 3 (unaffected)
      u2_records = Arca.Execution.list(user_id: "cleanup_user_2", limit: 100)
      assert length(u2_records) == 3
    end

    test "user retention settings are isolated" do
      user1_ctx = %Context{
        user_id: "settings_user_1",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :personal,
        auth_method: :local,
        api_key_type: nil
      }

      user2_ctx = %Context{
        user_id: "settings_user_2",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :personal,
        auth_method: :local,
        api_key_type: nil
      }

      # User 1 sets custom retention
      :ok = Retention.set_settings(user1_ctx, %{"executions" => 5})

      # User 2 gets defaults
      u1_settings = Retention.get_settings(user1_ctx)
      u2_settings = Retention.get_settings(user2_ctx)

      assert u1_settings["executions"] == 5
      assert u2_settings["executions"] == 10  # default
    end
  end

  # ============================================================================
  # Global vs User Paths
  # ============================================================================

  describe "global vs user path separation" do
    test "mcp_logs are shared across users", %{ctx: _ctx} do
      user1_ctx = %Context{
        user_id: "global_user_1",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :personal,
        auth_method: :local,
        api_key_type: nil
      }

      user2_ctx = %Context{
        user_id: "global_user_2",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :personal,
        auth_method: :local,
        api_key_type: nil
      }

      # User 1 writes to mcp_logs
      :ok = Arca.put(user1_ctx, ["mcp_logs", "shared_log.json"], ~s|{"from": "user1"}|)

      # User 2 can read it (global path)
      {:ok, content} = Arca.get(user2_ctx, ["mcp_logs", "shared_log.json"])
      assert content == ~s|{"from": "user1"}|

      # User 2 can list it
      {:ok, files} = Arca.list(user2_ctx, ["mcp_logs"])
      assert "shared_log.json" in files
    end

    test "cache is shared across users", %{ctx: _ctx} do
      user1_ctx = %Context{
        user_id: "cache_user_1",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :personal,
        auth_method: :local,
        api_key_type: nil
      }

      user2_ctx = %Context{
        user_id: "cache_user_2",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :personal,
        auth_method: :local,
        api_key_type: nil
      }

      # User 1 caches a blob
      :ok = Arca.put(user1_ctx, ["cache", "oci", "sha256_abc"], "cached blob")

      # User 2 can read the cached blob
      {:ok, content} = Arca.get(user2_ctx, ["cache", "oci", "sha256_abc"])
      assert content == "cached blob"
    end

    test "executions in SQLite are user-scoped" do
      user1_ctx = %Context{
        user_id: "exec_user_1",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :personal,
        auth_method: :local,
        api_key_type: nil
      }

      _user2_ctx = %Context{
        user_id: "exec_user_2",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :personal,
        auth_method: :local,
        api_key_type: nil
      }

      # User 1 creates an execution via SQLite
      Arca.Execution.record_start(%{
        id: "my_exec",
        request_id: "req_test",
        user_id: user1_ctx.user_id,
        reference: Jason.encode!(%{"id" => "my_exec"}),
        component_type: "reagent",
        started_at: DateTime.utc_now(),
        status: "running"
      })

      # User 1 can see it
      u1_records = Arca.Execution.list(user_id: "exec_user_1", limit: 100)
      assert length(u1_records) == 1

      # User 2 cannot see it (different user_id)
      u2_records = Arca.Execution.list(user_id: "exec_user_2", limit: 100)
      assert u2_records == []
    end
  end

  # ============================================================================
  # JSON Helpers
  # ============================================================================

  describe "JSON helper workflow" do
    test "put_json and get_json roundtrip", %{ctx: ctx} do
      data = %{
        "name" => "test",
        "count" => 42,
        "nested" => %{"a" => 1, "b" => 2},
        "list" => [1, 2, 3]
      }

      :ok = Arca.put_json(ctx, ["json_test", "data.json"], data)

      {:ok, read_data} = Arca.get_json(ctx, ["json_test", "data.json"])

      assert read_data == data
    end

    test "append_json adds to JSONL file", %{ctx: ctx} do
      path = ["json_test", "events.jsonl"]

      :ok = Arca.append_json(ctx, path, %{"event" => "first"})
      :ok = Arca.append_json(ctx, path, %{"event" => "second"})
      :ok = Arca.append_json(ctx, path, %{"event" => "third"})

      {:ok, content} = Arca.get(ctx, path)
      lines = String.split(content, "\n", trim: true)

      assert length(lines) == 3
      assert Jason.decode!(Enum.at(lines, 0))["event"] == "first"
      assert Jason.decode!(Enum.at(lines, 1))["event"] == "second"
      assert Jason.decode!(Enum.at(lines, 2))["event"] == "third"
    end

    test "get_json returns error for missing file", %{ctx: ctx} do
      {:error, :not_found} = Arca.get_json(ctx, ["json_test", "nonexistent.json"])
    end

    test "get_json returns error for invalid JSON", %{ctx: ctx} do
      :ok = Arca.put(ctx, ["json_test", "invalid.json"], "not valid json {{{")

      {:error, %Jason.DecodeError{}} = Arca.get_json(ctx, ["json_test", "invalid.json"])
    end
  end
end
