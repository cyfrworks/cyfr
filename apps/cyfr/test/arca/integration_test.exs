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
    rand_id = :rand.uniform(100_000)
    test_path = Path.join(System.tmp_dir!(), "arca_integration_#{rand_id}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    # Checkout Ecto sandbox for SQLite-based operations
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # Use a unique user_id per test to avoid shared-state pollution
    ctx =
      Context.build(
        user_id: "integration_test_user_#{rand_id}",
        namespace: "integration_test_user_#{rand_id}",
        project_id: "default",
        permissions: [:*],
        scope: :project,
        auth_method: :local,
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

    # Note: The storage MCP tool was removed in favor of the cyfr:storage/files
    # host function for catalysts. File operations are tested via the Arca API test above.
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
          reference: "reagent:local.test:0.1.0",
          component_type: "reagent",
          started_at: dt,
          status: "running"
        })
      end

      # Verify all 5 exist
      records =
        Arca.Execution.list(user_id: ctx.user_id, limit: 100, org_id: "", project_id: "default")

      assert length(records) == 5

      # 3. Run cleanup (dry_run first)
      {:ok, dry_result} = Retention.cleanup_executions(ctx, dry_run: true)
      assert length(dry_result.would_delete) == 2
      assert dry_result.would_keep == 3

      # 4. Actually run cleanup
      {:ok, count} = Retention.cleanup_executions(ctx)
      assert count == 2

      # 5. Verify only 3 remain
      records =
        Arca.Execution.list(user_id: ctx.user_id, limit: 100, org_id: "", project_id: "default")

      assert length(records) == 3

      # The 3 newest (exec_3, exec_4, exec_5) should remain
      ids = Enum.map(records, & &1.id)
      assert "exec_3" in ids
      assert "exec_4" in ids
      assert "exec_5" in ids
    end

    test "retention workflow via MCP", %{ctx: ctx} do
      # 1. Set retention via MCP
      {:ok, set_result} =
        MCP.handle("retention", ctx, %{
          "action" => "set",
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
          reference: "reagent:local.test:0.1.0",
          component_type: "reagent",
          started_at: dt,
          status: "running"
        })
      end

      # 3. Dry run via MCP
      {:ok, dry_result} =
        MCP.handle("retention", ctx, %{
          "action" => "cleanup",
          "cleanup_type" => "executions",
          "dry_run" => true
        })

      assert length(dry_result.would_delete) == 2
      assert dry_result.would_keep == 2

      # 4. Actual cleanup via MCP
      {:ok, cleanup_result} =
        MCP.handle("retention", ctx, %{
          "action" => "cleanup",
          "cleanup_type" => "executions"
        })

      assert cleanup_result.deleted == 2

      # 5. Verify via MCP get
      {:ok, get_result} =
        MCP.handle("retention", ctx, %{
          "action" => "get"
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
        namespace: "user_alpha",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :project,
        auth_method: :local,
        api_key_type: nil
      }

      user2_ctx = %Context{
        user_id: "user_beta",
        namespace: "user_beta",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :project,
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
        namespace: "cleanup_user_1",
        org_id: nil,
        project_id: "default",
        permissions: MapSet.new([:*]),
        scope: :project,
        auth_method: :local,
        api_key_type: nil
      }

      user2_ctx = %Context{
        user_id: "cleanup_user_2",
        namespace: "cleanup_user_2",
        org_id: nil,
        project_id: "default",
        permissions: MapSet.new([:*]),
        scope: :project,
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
          reference: "reagent:local.test:0.1.0",
          component_type: "reagent",
          started_at: dt,
          status: "running"
        })

        Arca.Execution.record_start(%{
          id: "u2_exec_#{i}",
          request_id: "req_test",
          user_id: user2_ctx.user_id,
          reference: "reagent:local.test:0.1.0",
          component_type: "reagent",
          started_at: dt,
          status: "running"
        })
      end

      # User 1 cleans up, keeping only 1
      {:ok, count} = Retention.cleanup_executions(user1_ctx, keep: 1)
      assert count == 2

      # User 1 should have 1 execution
      u1_records =
        Arca.Execution.list(
          user_id: "cleanup_user_1",
          limit: 100,
          org_id: "",
          project_id: "default"
        )

      assert length(u1_records) == 1

      # User 2 should still have all 3 (unaffected)
      u2_records =
        Arca.Execution.list(
          user_id: "cleanup_user_2",
          limit: 100,
          org_id: "",
          project_id: "default"
        )

      assert length(u2_records) == 3
    end

    test "user retention settings are isolated" do
      user1_ctx = %Context{
        user_id: "settings_user_1",
        namespace: "settings_user_1",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :project,
        auth_method: :local,
        api_key_type: nil
      }

      user2_ctx = %Context{
        user_id: "settings_user_2",
        namespace: "settings_user_2",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :project,
        auth_method: :local,
        api_key_type: nil
      }

      # User 1 sets custom retention
      :ok = Retention.set_settings(user1_ctx, %{"executions" => 5})

      # User 2 gets defaults
      u1_settings = Retention.get_settings(user1_ctx)
      u2_settings = Retention.get_settings(user2_ctx)

      assert u1_settings["executions"] == 5
      # default
      assert u2_settings["executions"] == 10
    end
  end

  # ============================================================================
  # Global vs User Paths
  # ============================================================================

  describe "global vs user path separation" do
    test "cache is shared across users", %{ctx: _ctx} do
      user1_ctx = %Context{
        user_id: "cache_user_1",
        namespace: "cache_user_1",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :project,
        auth_method: :local,
        api_key_type: nil
      }

      user2_ctx = %Context{
        user_id: "cache_user_2",
        namespace: "cache_user_2",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :project,
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
        namespace: "exec_user_1",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :project,
        auth_method: :local,
        api_key_type: nil
      }

      _user2_ctx = %Context{
        user_id: "exec_user_2",
        namespace: "exec_user_2",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :project,
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
      u1_records =
        Arca.Execution.list(user_id: "exec_user_1", limit: 100, org_id: "", project_id: "default")

      assert length(u1_records) == 1

      # User 2 cannot see it (different user_id)
      u2_records =
        Arca.Execution.list(user_id: "exec_user_2", limit: 100, org_id: "", project_id: "default")

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
