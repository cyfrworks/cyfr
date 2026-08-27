# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RetentionTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Cyfr.Retention
  alias Sanctum.Context

  setup do
    # Use a test-specific base path for file-based operations (blobs)
    rand_id = :rand.uniform(100_000)
    test_path = Path.join(System.tmp_dir!(), "retention_test_#{rand_id}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    # Checkout Ecto sandbox for SQLite-based operations
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # Retention settings live on the athanor row, so the athanor must exist.
    Arca.TenantTestHelper.ensure_athanor_row("ath_retention_#{rand_id}")

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
  # The roster
  # ============================================================================

  describe "kinds/0" do
    test "every kind implements the behaviour, with a unique key" do
      kinds = Retention.kinds()
      assert kinds != []

      for kind <- kinds do
        assert is_binary(kind.key())
        assert kind.default() > 0
        assert kind.unit() in [:keep, :days]
      end

      keys = Enum.map(kinds, & &1.key())
      assert keys == Enum.uniq(keys)
    end

    test "config :cyfr, Cyfr.Retention overrides a kind's default" do
      Application.put_env(:cyfr, Cyfr.Retention, executions: 5, builds: 3)

      assert Cyfr.Retention.Executions.default() == 5
      assert Cyfr.Retention.Builds.default() == 3
      assert Cyfr.Retention.McpLogs.default() == 30

      Application.delete_env(:cyfr, Cyfr.Retention)
      assert Cyfr.Retention.Executions.default() == 10_000
    end
  end

  # ============================================================================
  # Settings
  # ============================================================================

  describe "get_settings/set_settings" do
    test "defaults cover every kind when nothing is configured", %{ctx: ctx} do
      {:ok, settings} = Retention.get_settings(ctx)

      for kind <- Retention.kinds() do
        assert settings[kind.key()] == kind.default()
      end
    end

    test "set_settings persists and get_settings retrieves", %{ctx: ctx} do
      :ok = Retention.set_settings(ctx, %{"executions" => 5, "builds" => 3})

      {:ok, settings} = Retention.get_settings(ctx)
      assert settings["executions"] == 5
      assert settings["builds"] == 3
    end

    test "partial update preserves other settings", %{ctx: ctx} do
      :ok = Retention.set_settings(ctx, %{"executions" => 5, "builds" => 3})
      :ok = Retention.set_settings(ctx, %{"executions" => 20})

      {:ok, settings} = Retention.get_settings(ctx)
      assert settings["executions"] == 20
      assert settings["builds"] == 3
    end

    test "a missing athanor row means never configured: defaults, no error" do
      ctx =
        Context.build(
          user_id: "user_rowless",
          athanor_id: "ath_rowless_#{:rand.uniform(100_000)}",
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )

      {:ok, settings} = Retention.get_settings(ctx)
      assert settings["executions"] == 10_000

      # But nothing can be persisted without a row.
      assert {:error, :not_found} = Retention.set_settings(ctx, %{"executions" => 5})
    end

    test "handles a corrupt settings document gracefully", %{ctx: ctx} do
      # Corrupt the row's settings JSON directly, past the changeset.
      from(a in Arca.Schemas.Athanor, where: a.id == ^ctx.athanor_id)
      |> Arca.Repo.update_all(set: [settings: "not valid json {{{"])

      # Should return defaults
      {:ok, settings} = Retention.get_settings(ctx)
      assert settings["executions"] == 10_000
      assert settings["builds"] == 100
    end

    test "settings are isolated across athanors" do
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

      assert {:ok, %{"executions" => 5}} = Retention.get_settings(ath_a_ctx)
      assert {:ok, %{"executions" => 15}} = Retention.get_settings(ath_b_ctx)
    end

    test "refuses invalid values and unknown keys, typed", %{ctx: ctx} do
      # Every key drives destructive cleanup — a bad value refuses rather
      # than silently keeping the old one, so the caller learns.
      assert {:error, {:invalid_setting, "executions"}} =
               Retention.set_settings(ctx, %{"executions" => -5})

      assert {:error, {:invalid_setting, "executions"}} =
               Retention.set_settings(ctx, %{"executions" => "nope"})

      assert {:error, {:unknown_setting, "made_up"}} =
               Retention.set_settings(ctx, %{"made_up" => 3})

      {:ok, settings} = Retention.get_settings(ctx)
      assert settings["executions"] == 10_000
    end

    test "coerces integer strings", %{ctx: ctx} do
      :ok = Retention.set_settings(ctx, %{"executions" => "7"})

      {:ok, settings} = Retention.get_settings(ctx)
      assert settings["executions"] == 7
    end
  end

  # ============================================================================
  # cleanup/3 — one verb, every kind
  # ============================================================================

  describe "cleanup/3 executions" do
    test "returns 0 when no executions exist", %{ctx: ctx} do
      assert {:ok, 0} = Retention.cleanup(ctx, "executions")
    end

    test "an unknown kind refuses typed", %{ctx: ctx} do
      assert {:error, {:unknown_kind, "nonsense"}} = Retention.cleanup(ctx, "nonsense")
    end

    test "keeps executions when count is below limit", %{ctx: ctx} do
      for i <- 1..3 do
        create_execution_with_timestamp(ctx, "exec_#{i}", "2025-01-0#{i}T10:00:00Z")
      end

      assert {:ok, 0} = Retention.cleanup(ctx, "executions", value: 10)
      assert length(Arca.Execution.list(limit: 100, athanor_id: ctx.athanor_id)) == 3
    end

    test "deletes oldest executions past the athanor's configured value", %{ctx: ctx} do
      :ok = Retention.set_settings(ctx, %{"executions" => 3})

      for i <- 1..5 do
        create_execution_with_timestamp(ctx, "exec_#{i}", "2025-01-0#{i}T10:00:00Z")
      end

      assert {:ok, 2} = Retention.cleanup(ctx, "executions")

      records = Arca.Execution.list(limit: 100, athanor_id: ctx.athanor_id)
      ids = Enum.map(records, & &1.id)
      assert length(records) == 3
      refute "exec_1" in ids
      refute "exec_2" in ids
    end

    test "dry_run counts without deleting", %{ctx: ctx} do
      for i <- 1..5 do
        create_execution_with_timestamp(ctx, "exec_#{i}", "2025-01-0#{i}T10:00:00Z")
      end

      assert {:ok, 2} = Retention.cleanup(ctx, "executions", value: 3, dry_run: true)
      assert length(Arca.Execution.list(limit: 100, athanor_id: ctx.athanor_id)) == 5
    end
  end

  describe "cleanup/3 builds" do
    test "returns 0 when no builds exist", %{ctx: ctx} do
      assert {:ok, 0} = Retention.cleanup(ctx, "builds")
    end

    test "deletes oldest builds when over limit", %{ctx: ctx} do
      for i <- 1..5 do
        create_build_with_timestamp(ctx, "build_#{i}", "2025-01-0#{i}T10:00:00Z")
      end

      assert {:ok, 2} = Retention.cleanup(ctx, "builds", value: 3)
      assert build_ids(ctx) == ["build_3", "build_4", "build_5"]
    end

    test "dry_run counts the oldest builds without deleting", %{ctx: ctx} do
      for i <- 1..4 do
        create_build_with_timestamp(ctx, "build_#{i}", "2025-01-0#{i}T10:00:00Z")
      end

      assert {:ok, 2} = Retention.cleanup(ctx, "builds", value: 2, dry_run: true)
      assert length(build_ids(ctx)) == 4
    end
  end

  describe "cleanup/3 mcp_log_days" do
    test "returns 0 when no logs exist", %{ctx: ctx} do
      assert {:ok, 0} = Retention.cleanup(ctx, "mcp_log_days")
    end

    test "deletes logs older than the value in days", %{ctx: ctx} do
      old_ts = DateTime.utc_now() |> DateTime.add(-60 * 86_400, :second)
      recent_ts = DateTime.utc_now() |> DateTime.add(-1 * 86_400, :second)

      create_mcp_log("old_log_1", old_ts, ctx)
      create_mcp_log("old_log_2", old_ts, ctx)
      create_mcp_log("recent_log_1", recent_ts, ctx)

      assert {:ok, 2} = Retention.cleanup(ctx, "mcp_log_days", value: 30)

      assert Arca.Repo.get(Arca.McpLog, "recent_log_1") != nil
      assert Arca.Repo.get(Arca.McpLog, "old_log_1") == nil
    end

    test "dry_run counts without deleting", %{ctx: ctx} do
      old_ts = DateTime.utc_now() |> DateTime.add(-60 * 86_400, :second)
      create_mcp_log("dry_log_1", old_ts, ctx)
      create_mcp_log("dry_log_2", old_ts, ctx)

      assert {:ok, 2} = Retention.cleanup(ctx, "mcp_log_days", value: 30, dry_run: true)

      assert Arca.Repo.get(Arca.McpLog, "dry_log_1") != nil
      assert Arca.Repo.get(Arca.McpLog, "dry_log_2") != nil
    end
  end

  # ============================================================================
  # cleanup_all/1 — every kind, every active athanor, own settings
  # ============================================================================

  describe "cleanup_all/1" do
    test "answers per-kind totals and an errors list" do
      {:ok, result} = Retention.cleanup_all()

      assert is_integer(result.tenants)
      assert is_list(result.errors)

      for kind <- Retention.kinds() do
        assert is_integer(result.deleted[kind.key()])
      end
    end

    test "prunes each active athanor by its own settings, per athanor not per member" do
      {:ok, athanor} =
        Sanctum.Tenancy.Athanors.create(%{
          kind: "group",
          name: "Sweep",
          slug: "sweep-#{System.unique_integer([:positive])}",
          created_by: "test"
        })

      ctx = Sanctum.internal_context(user_id: "system", athanor_id: athanor.id, scope: :athanor)
      :ok = Retention.set_settings(ctx, %{"executions" => 2, "builds" => 2})

      # Two different users in the SAME athanor: retention keeps N per
      # athanor, members are interchangeable.
      for i <- 1..5 do
        ts = "2025-01-0#{i}T10:00:00Z"
        create_execution_with_timestamp(%{ctx | user_id: "u1"}, "u1_exec_#{i}", ts)
        create_execution_with_timestamp(%{ctx | user_id: "u2"}, "u2_exec_#{i}", ts)
      end

      for i <- 1..4 do
        create_build_with_timestamp(ctx, "build_#{i}", "2025-01-0#{i}T10:00:00Z")
      end

      {:ok, result} = Retention.cleanup_all()

      assert result.errors == []
      assert result.deleted["executions"] >= 8
      assert result.deleted["builds"] >= 2

      assert length(Arca.Execution.list(athanor_id: athanor.id, limit: 100)) == 2
      assert build_ids(ctx) == ["build_3", "build_4"]
    end
  end

  # ============================================================================
  # Test Helpers
  # ============================================================================

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
    :ok = Cyfr.BuildRecords.record_started(ctx, id, "reagent:local.test:0.1.0")

    # Pin started_at so ordering is the fixture's, not the insert order's.
    {:ok, pinned, 0} = DateTime.from_iso8601(timestamp)

    {1, _} =
      Arca.Repo.update_all(
        from(b in Arca.Schemas.BuildRecord, where: b.id == ^id),
        set: [started_at: pinned]
      )

    :ok
  end

  defp build_ids(ctx) do
    from(b in Arca.Schemas.BuildRecord, select: b.id)
    |> Arca.QueryHelpers.where_tenant(ctx)
    |> Arca.Repo.all()
    |> Enum.sort()
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
