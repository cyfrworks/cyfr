# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RetentionTest do
  use ExUnit.Case, async: false

  alias Cyfr.Retention
  alias Sanctum.Context

  setup do
    # Use a test-specific base path for file-based operations (builds, settings)
    rand_id = :rand.uniform(100_000)
    test_path = Path.join(System.tmp_dir!(), "retention_test_#{rand_id}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    # Checkout Ecto sandbox for SQLite-based operations
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # Use a unique athanor per test: execution retention is per-athanor, so
    # a unique id isolates each test's executions from cross-test pollution.
    ctx =
      Context.build(
        user_id: "retention_test_user_#{rand_id}",
        namespace: "retention_test_user_#{rand_id}",
        athanor_id: "ath_retention_#{rand_id}",
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: ctx, test_path: test_path}
  end

  # ============================================================================
  # Settings
  # ============================================================================

  describe "settings/0" do
    test "returns default settings" do
      settings = Retention.settings()

      assert settings.executions == 10_000
      assert settings.builds == 100
    end

    test "respects config overrides" do
      Application.put_env(:cyfr, Cyfr.Retention, executions: 5, builds: 3)

      settings = Retention.settings()
      assert settings.executions == 5
      assert settings.builds == 3

      Application.delete_env(:cyfr, Cyfr.Retention)
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
      records =
        Arca.Execution.list(limit: 100, athanor_id: ctx.athanor_id)

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
      records =
        Arca.Execution.list(limit: 100, athanor_id: ctx.athanor_id)

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
      records =
        Arca.Execution.list(limit: 100, athanor_id: ctx.athanor_id)

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
    test "returns summary map with errors key", %{ctx: ctx} do
      {:ok, result} = Retention.cleanup_all_executions(ctx)
      assert is_integer(result.tenants)
      assert is_integer(result.deleted)
      assert is_list(result.errors)
    end

    test "keeps N per athanor across all its members", %{ctx: ctx} do
      rand_id = :rand.uniform(100_000)

      # Two different users in the SAME athanor.
      u1 = %{ctx | user_id: "cleanup_all_u1_#{rand_id}"}
      u2 = %{ctx | user_id: "cleanup_all_u2_#{rand_id}"}

      # Create 5 executions for each user — 10 total in the one athanor.
      for i <- 1..5 do
        ts = "2025-01-0#{i}T10:00:00Z"
        create_execution_with_timestamp(u1, "u1_#{rand_id}_exec_#{i}", ts)
        create_execution_with_timestamp(u2, "u2_#{rand_id}_exec_#{i}", ts)
      end

      all = Arca.Execution.list(athanor_id: ctx.athanor_id, limit: 100)
      assert length(all) == 10

      # Sweep, keeping 2 per athanor (not per user).
      {:ok, result} = Retention.cleanup_all_executions(ctx, keep: 2)

      assert result.tenants == 1
      assert result.deleted == 8

      remaining = Arca.Execution.list(athanor_id: ctx.athanor_id, limit: 100)
      assert length(remaining) == 2
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
      # unchanged
      assert settings["builds"] == 3
    end

    test "returns defaults when no user settings exist", %{ctx: ctx} do
      settings = Retention.get_settings(ctx)

      assert settings["executions"] == 10_000
      assert settings["builds"] == 100
    end

    test "handles corrupt settings file gracefully", %{ctx: ctx} do
      # Write corrupt JSON directly
      user_config_path =
        Arca.Adapters.Local.build_path(ctx, ["config", "retention.json"])

      File.mkdir_p!(Path.dirname(user_config_path))
      File.write!(user_config_path, "not valid json {{{")

      # Should return defaults
      settings = Retention.get_settings(ctx)
      assert settings["executions"] == 10_000
      assert settings["builds"] == 100
    end

    test "settings are isolated across athanors", %{ctx: _ctx, test_path: _test_path} do
      # Within an athanor, members share settings (one config); the isolation
      # boundary is the athanor, not the user.
      ath_a_ctx =
        Context.build(
          user_id: "user_1",
          namespace: "user_1",
          athanor_id: "ath_a",
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc
        )

      ath_b_ctx =
        Context.build(
          user_id: "user_2",
          namespace: "user_2",
          athanor_id: "ath_b",
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc
        )

      :ok = Retention.set_settings(ath_a_ctx, %{"executions" => 5})
      :ok = Retention.set_settings(ath_b_ctx, %{"executions" => 15})

      assert Retention.get_settings(ath_a_ctx)["executions"] == 5
      assert Retention.get_settings(ath_b_ctx)["executions"] == 15
    end

    test "rejects invalid values", %{ctx: ctx} do
      :ok = Retention.set_settings(ctx, %{"executions" => -5})

      # Should use previous value (default 10_000) due to validation
      settings = Retention.get_settings(ctx)
      assert settings["executions"] == 10_000
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
      assert Arca.Repo.get(Arca.McpLog, "recent_log_1") != nil
      assert Arca.Repo.get(Arca.McpLog, "old_log_1") == nil
    end

    test "dry_run returns count without deleting", %{ctx: ctx} do
      old_ts = DateTime.utc_now() |> DateTime.add(-60 * 86_400, :second)
      create_mcp_log("dry_log_1", old_ts, ctx)
      create_mcp_log("dry_log_2", old_ts, ctx)

      {:ok, result} = Retention.cleanup_mcp_logs(ctx, days: 30, dry_run: true)
      assert result.would_delete == 2

      # Verify nothing was deleted
      assert Arca.Repo.get(Arca.McpLog, "dry_log_1") != nil
      assert Arca.Repo.get(Arca.McpLog, "dry_log_2") != nil
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

      create_execution_with_timestamp(
        ctx,
        id,
        "2025-01-15T#{String.pad_leading("#{i}", 2, "0")}:00:00Z"
      )
    end
  end

  defp create_execution_with_timestamp(ctx, id, timestamp) do
    {:ok, dt, _} = DateTime.from_iso8601(timestamp)

    Arca.Execution.record_start(%{
      id: id,
      request_id: "req_test",
      user_id: ctx.user_id,
      athanor_id: ctx.athanor_id,
      reference: "reagent:local.test:0.1.0",
      component_type: "reagent",
      started_at: dt,
      status: "running"
    })
  end

  defp create_build_with_timestamp(ctx, id, timestamp) do
    :ok =
      Arca.put_json(ctx, ["builds", id, "started.json"], %{
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
      athanor_id: ctx.athanor_id,
      timestamp: timestamp,
      status: "success",
      tool: "test",
      action: "test"
    })
  end
end
