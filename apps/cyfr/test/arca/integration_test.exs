# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

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

  alias Emissary.MCP.Tools.RecordsProvider, as: MCP
  alias Cyfr.Retention
  alias Sanctum.Context

  setup do
    rand_id = :rand.uniform(100_000)
    test_path = Path.join(System.tmp_dir!(), "arca_integration_#{rand_id}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    # Checkout Ecto sandbox for SQLite-based operations
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # Retention settings live on the athanor row, so the athanor must exist.
    Arca.TenantTestHelper.ensure_athanor_row("ath_integration_#{rand_id}")

    # Use a unique athanor per test: execution retention/listing is
    # per-athanor, so a unique id isolates each test from shared-state pollution.
    ctx =
      Context.build(
        user_id: "integration_test_user_#{rand_id}",
        namespace: "integration_test_user_#{rand_id}",
        athanor_id: "ath_integration_#{rand_id}",
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    actor = Sanctum.Context.actor(ctx)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: ctx, actor: actor, test_path: test_path}
  end

  # ============================================================================
  # Full CRUD Workflow
  # ============================================================================

  describe "list → write → read → delete workflow" do
    test "complete file lifecycle via Arca API", %{actor: actor} do
      # 1. List - should start empty
      {:ok, files} = Arca.list(actor, ["data", "workflow"])
      assert files == []

      # 2. Write - create a file
      :ok = Arca.put(actor, ["data", "workflow", "test.txt"], "hello world")

      # 3. List - should now contain the file
      {:ok, files} = Arca.list(actor, ["data", "workflow"])
      assert "test.txt" in files

      # 4. Read - verify content
      {:ok, content} = Arca.get(actor, ["data", "workflow", "test.txt"])
      assert content == "hello world"

      # 5. Exists - verify existence
      assert Arca.exists?(actor, ["data", "workflow", "test.txt"])

      # 6. Delete - remove the file
      :ok = Arca.delete(actor, ["data", "workflow", "test.txt"])

      # 7. Verify deletion
      refute Arca.exists?(actor, ["data", "workflow", "test.txt"])

      {:error, :not_found} =
        Arca.get(actor, ["data", "workflow", "test.txt"])
    end
  end

  # A member of `athanor`, as the identity domain would establish them.
  defp member_ctx(user_id, athanor_id) do
    Context.build(
      user_id: user_id,
      namespace: user_id,
      athanor_id: athanor_id,
      permissions: [:*],
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  # ============================================================================
  # Retention Workflow
  # ============================================================================

  describe "retention workflow: set settings → create data → cleanup → verify" do
    test "execution retention workflow", %{ctx: ctx, actor: actor} do
      # 1. Set retention to keep only 3 executions
      :ok = Retention.set_settings(ctx, %{"executions" => 3})

      # Verify settings
      {:ok, settings} = Retention.get_settings(ctx)
      assert settings["executions"] == 3

      # 2. Create 5 executions with different timestamps via SQLite
      for i <- 1..5 do
        timestamp = "2025-01-#{String.pad_leading("#{i}", 2, "0")}T10:00:00Z"
        {:ok, dt, _} = DateTime.from_iso8601(timestamp)

        Arca.Execution.record_start(%{
          id: "exec_#{i}",
          request_id: "req_test",
          user_id: actor.user_id,
          athanor_id: actor.athanor_id,
          reference: "reagent:local.test:0.1.0",
          component_type: "reagent",
          started_at: dt,
          # Terminal: retention never prunes a row still running.
          status: "completed"
        })
      end

      # Verify all 5 exist
      records =
        Arca.Execution.list(
          user_id: actor.user_id,
          limit: 100,
          athanor_id: actor.athanor_id
        )

      assert length(records) == 5

      # 3. Run cleanup (dry_run first — counts, deletes nothing)
      assert {:ok, 2} = Retention.cleanup(ctx, "executions", dry_run: true)

      # 4. Actually run cleanup
      assert {:ok, 2} = Retention.cleanup(ctx, "executions")

      # 5. Verify only 3 remain
      records =
        Arca.Execution.list(
          user_id: actor.user_id,
          limit: 100,
          athanor_id: actor.athanor_id
        )

      assert length(records) == 3

      # The 3 newest (exec_3, exec_4, exec_5) should remain
      ids = Enum.map(records, & &1.id)
      assert "exec_3" in ids
      assert "exec_4" in ids
      assert "exec_5" in ids
    end

    test "retention workflow via MCP", %{ctx: ctx, actor: actor} do
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
          user_id: actor.user_id,
          athanor_id: actor.athanor_id,
          reference: "reagent:local.test:0.1.0",
          component_type: "reagent",
          started_at: dt,
          # Terminal: retention never prunes a row still running.
          status: "completed"
        })
      end

      # 3. Dry run via MCP
      {:ok, dry_result} =
        MCP.handle("retention", ctx, %{
          "action" => "cleanup",
          "cleanup_type" => "executions",
          "dry_run" => true
        })

      assert dry_result.would_delete == 2

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
    test "members of the same athanor share files; different athanors are isolated" do
      # Same athanor, different users — interchangeable members share storage.
      member1 = Cyfr.Actor.in_athanor("ath_test")

      member2 = Cyfr.Actor.in_athanor("ath_test")

      # A different athanor must remain isolated.
      other_tenant = Cyfr.Actor.in_athanor("ath_other")

      :ok = Arca.put(member1, ["data", "private", "secret.txt"], "shared secret")

      # A fellow member reads the same file (members are interchangeable).
      {:ok, content} = Arca.get(member2, ["data", "private", "secret.txt"])
      assert content == "shared secret"

      # A different tenant cannot.
      {:error, :not_found} = Arca.get(other_tenant, ["data", "private", "secret.txt"])
    end

    test "execution cleanup is per-athanor (affects all members' executions)" do
      rand_id = :rand.uniform(100_000)
      athanor = "ath_cleanup_#{rand_id}"

      user1_ctx = %Context{
        user_id: "cleanup_user_1",
        namespace: "cleanup_user_1",
        athanor_id: athanor,
        permissions: MapSet.new([:*]),
        scope: :athanor,
        auth_method: :oidc,
        api_key_type: nil
      }

      user2_ctx = %Context{
        user_id: "cleanup_user_2",
        namespace: "cleanup_user_2",
        athanor_id: athanor,
        permissions: MapSet.new([:*]),
        scope: :athanor,
        auth_method: :oidc,
        api_key_type: nil
      }

      # Each user creates 3 executions in the SAME athanor (6 total)
      for i <- 1..3 do
        ts = "2025-01-0#{i}T10:00:00Z"
        {:ok, dt, _} = DateTime.from_iso8601(ts)

        Arca.Execution.record_start(%{
          id: "u1_exec_#{rand_id}_#{i}",
          request_id: "req_test",
          user_id: user1_ctx.user_id,
          athanor_id: athanor,
          reference: "reagent:local.test:0.1.0",
          component_type: "reagent",
          started_at: dt,
          # Terminal: retention never prunes a row still running.
          status: "completed"
        })

        Arca.Execution.record_start(%{
          id: "u2_exec_#{rand_id}_#{i}",
          request_id: "req_test",
          user_id: user2_ctx.user_id,
          athanor_id: athanor,
          reference: "reagent:local.test:0.1.0",
          component_type: "reagent",
          started_at: dt,
          # Terminal: retention never prunes a row still running.
          status: "completed"
        })
      end

      # A member cleans up keeping 2 — retention is per-athanor, so it applies
      # to the whole athanor's executions (6 → 2), regardless of creator.
      assert {:ok, 4} = Retention.cleanup(user1_ctx, "executions", value: 2)

      remaining = Arca.Execution.list(athanor_id: athanor, limit: 100)

      assert length(remaining) == 2
    end

    test "retention settings are shared within an athanor; isolated across athanors" do
      # Retention is a Cyfr-layer verb and still takes the context; only
      # the storage facades under it take the actor it projects.
      member1 = member_ctx("user_alpha", "ath_test")
      member2 = member_ctx("user_beta", "ath_test")
      other_tenant = member_ctx("user_gamma", "ath_other")

      :ok = Retention.set_settings(member1, %{"executions" => 5})

      # Shared within the tenant — a fellow member sees the same setting.
      assert {:ok, %{"executions" => 5}} = Retention.get_settings(member2)
      # A different tenant (no row: never configured) keeps its own default.
      assert {:ok, %{"executions" => 10_000}} = Retention.get_settings(other_tenant)
    end
  end

  # ============================================================================
  # Global vs User Paths
  # ============================================================================

  describe "global vs user path separation" do
    test "the cache is the server's, shared by its internal contexts and closed to tenants",
         %{actor: _ctx} do
      user_ctx = %Context{
        user_id: "cache_user_1",
        namespace: "cache_user_1",
        athanor_id: "ath_test",
        permissions: MapSet.new([:*]),
        scope: :athanor,
        auth_method: :oidc,
        api_key_type: nil,
        authenticated: true
      }

      # The server caches a blob under the global root...
      :ok = Arca.put(Cyfr.Actor.system(), ["cache", "oci", "sha256_abc"], "cached blob")

      # ...another internal context reads it back...
      {:ok, content} =
        Arca.get(%{Cyfr.Actor.system() | user_id: "_probe"}, ["cache", "oci", "sha256_abc"])

      assert content == "cached blob"

      # ...and a tenant context, whatever its athanor, cannot reach it.
      assert {:error, :forbidden} =
               Arca.get(Sanctum.Context.actor(user_ctx), ["cache", "oci", "sha256_abc"])

      assert {:error, :forbidden} =
               Arca.put(Sanctum.Context.actor(user_ctx), ["cache", "oci", "x"], "nope")
    end

    test "executions in SQLite are user-scoped" do
      user1_ctx = %Context{
        user_id: "exec_user_1",
        namespace: "exec_user_1",
        athanor_id: "ath_test",
        permissions: MapSet.new([:*]),
        scope: :athanor,
        auth_method: :oidc,
        api_key_type: nil
      }

      _user2_ctx = %Context{
        user_id: "exec_user_2",
        namespace: "exec_user_2",
        athanor_id: "ath_test",
        permissions: MapSet.new([:*]),
        scope: :athanor,
        auth_method: :oidc,
        api_key_type: nil
      }

      # User 1 creates an execution via SQLite
      Arca.Execution.record_start(%{
        id: "my_exec",
        request_id: "req_test",
        user_id: user1_ctx.user_id,
        athanor_id: user1_ctx.athanor_id,
        reference: Jason.encode!(%{"id" => "my_exec"}),
        component_type: "reagent",
        started_at: DateTime.utc_now(),
        status: "running"
      })

      # User 1 can see it
      u1_records =
        Arca.Execution.list(
          user_id: "exec_user_1",
          limit: 100,
          athanor_id: "ath_test"
        )

      assert length(u1_records) == 1

      # User 2 cannot see it (different user_id)
      u2_records =
        Arca.Execution.list(
          user_id: "exec_user_2",
          limit: 100,
          athanor_id: "ath_test"
        )

      assert u2_records == []
    end
  end

  # ============================================================================
  # JSON Helpers
  # ============================================================================

  describe "JSON helper workflow" do
    test "put_json and get_json roundtrip", %{actor: actor} do
      data = %{
        "name" => "test",
        "count" => 42,
        "nested" => %{"a" => 1, "b" => 2},
        "list" => [1, 2, 3]
      }

      :ok = Arca.put_json(actor, ["data", "json_test", "data.json"], data)

      {:ok, read_data} =
        Arca.get_json(actor, ["data", "json_test", "data.json"])

      assert read_data == data
    end

    test "get_json returns error for missing file", %{actor: actor} do
      {:error, :not_found} =
        Arca.get_json(actor, ["data", "json_test", "nonexistent.json"])
    end

    test "get_json returns error for invalid JSON", %{actor: actor} do
      :ok =
        Arca.put(
          actor,
          ["data", "json_test", "invalid.json"],
          "not valid json {{{"
        )

      # Return the shared :invalid_json error for corrupt stored JSON.
      assert {:error, :invalid_json} =
               Arca.get_json(actor, ["data", "json_test", "invalid.json"])
    end
  end
end
