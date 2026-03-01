defmodule Arca.RetentionTest do
  use ExUnit.Case, async: false

  alias Arca.Retention
  alias Sanctum.Context

  setup do
    # Use a test-specific base path for file-based operations (builds, settings)
    test_path = Path.join(System.tmp_dir!(), "retention_test_#{:rand.uniform(100_000)}")
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
  # Settings
  # ============================================================================

  describe "settings/0" do
    test "returns default settings" do
      settings = Retention.settings()

      assert settings.executions == 10
      assert settings.builds == 10
    end

    test "respects config overrides" do
      Application.put_env(:arca, Arca.Retention, executions: 5, builds: 3)

      settings = Retention.settings()
      assert settings.executions == 5
      assert settings.builds == 3

      Application.delete_env(:arca, Arca.Retention)
    end
  end

  # ============================================================================
  # Execution Cleanup
  # ============================================================================

  describe "cleanup_executions/2" do
    test "returns 0 when no executions exist", %{ctx: ctx} do
      {:ok, count} = Retention.cleanup_executions(ctx)
      assert count == 0
    end

    test "keeps executions when count is below limit", %{ctx: ctx} do
      # Create 3 executions
      create_test_executions(ctx, 3)

      {:ok, count} = Retention.cleanup_executions(ctx, keep: 10)
      assert count == 0

      # Verify all still exist
      records = Arca.Execution.list(user_id: ctx.user_id, limit: 100)
      assert length(records) == 3
    end

    test "deletes oldest executions when over limit", %{ctx: ctx} do
      # Create 5 executions with different timestamps
      for i <- 1..5 do
        create_execution_with_timestamp(ctx, "exec_#{i}", "2025-01-0#{i}T10:00:00Z")
      end

      {:ok, count} = Retention.cleanup_executions(ctx, keep: 3)
      assert count == 2

      # Verify the 3 newest remain
      records = Arca.Execution.list(user_id: ctx.user_id, limit: 100)
      assert length(records) == 3
      ids = Enum.map(records, & &1.id)

      # The oldest (exec_1, exec_2) should be gone
      refute "exec_1" in ids
      refute "exec_2" in ids
    end

    test "dry_run returns what would be deleted without deleting", %{ctx: ctx} do
      # Create 5 executions
      for i <- 1..5 do
        create_execution_with_timestamp(ctx, "exec_#{i}", "2025-01-0#{i}T10:00:00Z")
      end

      {:ok, result} = Retention.cleanup_executions(ctx, keep: 3, dry_run: true)

      assert is_map(result)
      assert length(result.would_delete) == 2
      assert "exec_1" in result.would_delete
      assert "exec_2" in result.would_delete
      assert result.would_keep == 3

      # Verify nothing was actually deleted
      records = Arca.Execution.list(user_id: ctx.user_id, limit: 100)
      assert length(records) == 5
    end
  end

  # ============================================================================
  # Build Cleanup
  # ============================================================================

  describe "cleanup_builds/2" do
    test "returns 0 when no builds exist", %{ctx: ctx} do
      {:ok, count} = Retention.cleanup_builds(ctx)
      assert count == 0
    end

    test "deletes oldest builds when over limit", %{ctx: ctx} do
      # Create 5 builds (file-based)
      for i <- 1..5 do
        create_build_with_timestamp(ctx, "build_#{i}", "2025-01-0#{i}T10:00:00Z")
      end

      {:ok, count} = Retention.cleanup_builds(ctx, keep: 3)
      assert count == 2

      {:ok, remaining} = Arca.list(ctx, ["builds"])
      assert length(remaining) == 3
    end
  end

  # ============================================================================
  # All-User Execution Cleanup
  # ============================================================================

  describe "cleanup_all_executions/2" do
    test "returns 0 when no executions exist", %{ctx: ctx} do
      {:ok, result} = Retention.cleanup_all_executions(ctx)
      assert result.users == 0
      assert result.deleted == 0
    end

    test "cleans up executions for all users", %{ctx: _ctx, test_path: _test_path} do
      user1_ctx = %Context{
        user_id: "cleanup_all_user1",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :personal,
        auth_method: :local,
        api_key_type: nil
      }

      user2_ctx = %Context{
        user_id: "cleanup_all_user2",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :personal,
        auth_method: :local,
        api_key_type: nil
      }

      # Create 5 executions for each user
      for i <- 1..5 do
        ts = "2025-01-0#{i}T10:00:00Z"
        create_execution_with_timestamp(user1_ctx, "u1_exec_#{i}", ts)
        create_execution_with_timestamp(user2_ctx, "u2_exec_#{i}", ts)
      end

      # Verify each has 5
      u1_records = Arca.Execution.list(user_id: "cleanup_all_user1", limit: 100)
      u2_records = Arca.Execution.list(user_id: "cleanup_all_user2", limit: 100)
      assert length(u1_records) == 5
      assert length(u2_records) == 5

      # Run cleanup for all users, keeping 2 each
      {:ok, result} = Retention.cleanup_all_executions(user1_ctx, keep: 2)

      assert result.users == 2
      assert result.deleted == 6  # 3 deleted from each user

      # Verify each now has 2
      u1_records = Arca.Execution.list(user_id: "cleanup_all_user1", limit: 100)
      u2_records = Arca.Execution.list(user_id: "cleanup_all_user2", limit: 100)
      assert length(u1_records) == 2
      assert length(u2_records) == 2
    end
  end

  # ============================================================================
  # User Settings Persistence
  # ============================================================================

  describe "get_settings/set_settings persistence" do
    test "set_settings persists and get_settings retrieves", %{ctx: ctx} do
      # Set custom settings
      :ok = Retention.set_settings(ctx, %{"executions" => 5, "builds" => 3})

      # Retrieve and verify
      settings = Retention.get_settings(ctx)
      assert settings["executions"] == 5
      assert settings["builds"] == 3
    end

    test "partial update preserves other settings", %{ctx: ctx} do
      # Set initial settings
      :ok = Retention.set_settings(ctx, %{"executions" => 5, "builds" => 3})

      # Update only executions
      :ok = Retention.set_settings(ctx, %{"executions" => 20})

      settings = Retention.get_settings(ctx)
      assert settings["executions"] == 20
      assert settings["builds"] == 3  # unchanged
    end

    test "returns defaults when no user settings exist", %{ctx: ctx} do
      settings = Retention.get_settings(ctx)

      assert settings["executions"] == 10
      assert settings["builds"] == 10
    end

    test "handles corrupt settings file gracefully", %{ctx: ctx, test_path: test_path} do
      # Write corrupt JSON directly
      user_config_path = Path.join([test_path, "users", ctx.user_id, "config", "retention.json"])
      File.mkdir_p!(Path.dirname(user_config_path))
      File.write!(user_config_path, "not valid json {{{")

      # Should return defaults
      settings = Retention.get_settings(ctx)
      assert settings["executions"] == 10
      assert settings["builds"] == 10
    end

    test "different users have isolated settings", %{ctx: _ctx, test_path: _test_path} do
      user1_ctx = %Context{
        user_id: "user_1",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :personal,
        auth_method: :local,
        api_key_type: nil
      }

      user2_ctx = %Context{
        user_id: "user_2",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :personal,
        auth_method: :local,
        api_key_type: nil
      }

      # Set different settings for each user
      :ok = Retention.set_settings(user1_ctx, %{"executions" => 5})
      :ok = Retention.set_settings(user2_ctx, %{"executions" => 15})

      # Verify isolation
      assert Retention.get_settings(user1_ctx)["executions"] == 5
      assert Retention.get_settings(user2_ctx)["executions"] == 15
    end

    test "rejects invalid values", %{ctx: ctx} do
      :ok = Retention.set_settings(ctx, %{"executions" => -5})

      # Should use previous value (default 10) due to validation
      settings = Retention.get_settings(ctx)
      assert settings["executions"] == 10
    end

    test "handles string values", %{ctx: ctx} do
      :ok = Retention.set_settings(ctx, %{"executions" => "7"})

      settings = Retention.get_settings(ctx)
      assert settings["executions"] == 7
    end
  end

  # ============================================================================
  # MCP Log Cleanup
  # ============================================================================

  describe "cleanup_mcp_logs/2" do
    test "returns 0 when no logs exist", %{ctx: ctx} do
      {:ok, count} = Retention.cleanup_mcp_logs(ctx)
      assert count == 0
    end

    test "deletes logs older than configured days", %{ctx: ctx} do
      old_ts = DateTime.utc_now() |> DateTime.add(-60 * 86_400, :second)
      recent_ts = DateTime.utc_now() |> DateTime.add(-1 * 86_400, :second)

      create_mcp_log("old_log_1", old_ts, ctx)
      create_mcp_log("old_log_2", old_ts, ctx)
      create_mcp_log("recent_log_1", recent_ts, ctx)

      {:ok, count} = Retention.cleanup_mcp_logs(ctx, days: 30)
      assert count == 2

      # Recent log should remain
      assert Arca.McpLog.get("recent_log_1") != nil
      assert Arca.McpLog.get("old_log_1") == nil
    end

    test "dry_run returns count without deleting", %{ctx: ctx} do
      old_ts = DateTime.utc_now() |> DateTime.add(-60 * 86_400, :second)
      create_mcp_log("dry_log_1", old_ts, ctx)
      create_mcp_log("dry_log_2", old_ts, ctx)

      {:ok, result} = Retention.cleanup_mcp_logs(ctx, days: 30, dry_run: true)
      assert result.would_delete == 2

      # Verify nothing was deleted
      assert Arca.McpLog.get("dry_log_1") != nil
      assert Arca.McpLog.get("dry_log_2") != nil
    end
  end

  # ============================================================================
  # MCP Log Settings
  # ============================================================================

  describe "mcp_log_days in settings" do
    test "settings/0 returns default mcp_log_days" do
      settings = Retention.settings()
      assert settings.mcp_log_days == 30
    end

    test "get_settings includes mcp_log_days", %{ctx: ctx} do
      settings = Retention.get_settings(ctx)
      assert settings["mcp_log_days"] == 30
    end

    test "set_settings persists mcp_log_days", %{ctx: ctx} do
      :ok = Retention.set_settings(ctx, %{"mcp_log_days" => 14})
      settings = Retention.get_settings(ctx)
      assert settings["mcp_log_days"] == 14
    end
  end

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp create_test_executions(ctx, count) do
    for i <- 1..count do
      id = "exec_test_#{i}"
      create_execution_with_timestamp(ctx, id, "2025-01-15T#{String.pad_leading("#{i}", 2, "0")}:00:00Z")
    end
  end

  defp create_execution_with_timestamp(ctx, id, timestamp) do
    {:ok, dt, _} = DateTime.from_iso8601(timestamp)

    Arca.Execution.record_start(%{
      id: id,
      request_id: "req_test",
      user_id: ctx.user_id,
      reference: "reagent:local.test:0.1.0",
      component_type: "reagent",
      started_at: dt,
      status: "running"
    })
  end

  defp create_build_with_timestamp(ctx, id, timestamp) do
    :ok = Arca.put_json(ctx, ["builds", id, "started.json"], %{
      "build_id" => id,
      "started_at" => timestamp,
      "source" => %{"local" => "./src"},
      "target" => "reagent"
    })
  end

  defp create_mcp_log(id, %DateTime{} = timestamp, ctx) do
    Arca.McpLog.record(%{
      id: id,
      user_id: ctx.user_id,
      timestamp: timestamp,
      status: "success",
      tool: "test",
      action: "test"
    })
  end

end
