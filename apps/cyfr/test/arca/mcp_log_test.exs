# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.McpLogTest do
  use ExUnit.Case, async: false

  alias Arca.McpLog
  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  defp log_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        id: "req_#{:rand.uniform(1_000_000)}",
        user_id: "user_1",
        athanor_id: "ath_test",
        timestamp: DateTime.utc_now(),
        status: "pending",
        tool: "execution",
        action: "run",
        method: "tools/call",
        request_id: "req_chain_1"
      },
      overrides
    )
  end

  describe "record/1" do
    test "inserts a valid MCP log" do
      attrs = log_attrs()
      assert {:ok, log} = McpLog.record(attrs)
      assert log.id == attrs.id
      assert log.status == "pending"
      assert log.tool == "execution"
    end

    test "validates status inclusion" do
      assert {:error, changeset} = McpLog.record(log_attrs(%{status: "bogus"}))
      refute changeset.valid?
      assert {"is invalid", _} = changeset.errors[:status]
    end

    test "rejects missing required fields" do
      assert {:error, changeset} = McpLog.record(%{})
      refute changeset.valid?
    end
  end

  describe "record_update/3" do
    test "updates an existing log" do
      {:ok, log} = McpLog.record(log_attrs(%{id: "req_upd_1"}))

      ctx =
        Context.build(
          scope: :platform,
          user_id: "admin",
          permissions: [:*],
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      assert {:ok, updated} =
               McpLog.record_update(ctx, log.id, %{status: "success", duration_ms: 42})

      assert updated.status == "success"
      assert updated.duration_ms == 42
    end

    test "returns not_found for missing log" do
      ctx =
        Context.build(
          scope: :platform,
          user_id: "admin",
          permissions: [:*],
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      assert {:error, :not_found} =
               McpLog.record_update(ctx, "req_nonexistent", %{status: "success"})
    end

    test "cross-tenant update returns not_found" do
      {:ok, _} =
        McpLog.record(log_attrs(%{id: "req_cross", athanor_id: "ath_a"}))

      ctx_other =
        Context.build(
          user_id: "u",
          athanor_id: "ath_b",
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      assert {:error, :not_found} =
               McpLog.record_update(ctx_other, "req_cross", %{status: "success"})
    end
  end

  describe "list/1" do
    test "returns logs ordered by timestamp desc" do
      t1 = DateTime.add(DateTime.utc_now(), -60, :second)
      t2 = DateTime.utc_now()

      {:ok, _} = McpLog.record(log_attrs(%{id: "req_l1", timestamp: t1}))
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_l2", timestamp: t2}))

      logs = McpLog.list(athanor_id: "ath_test")
      ids = Enum.map(logs, & &1.id)
      assert "req_l2" in ids
      assert "req_l1" in ids
      idx1 = Enum.find_index(ids, &(&1 == "req_l2"))
      idx2 = Enum.find_index(ids, &(&1 == "req_l1"))
      assert idx1 < idx2
    end

    test "filters by user_id" do
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_fu1", user_id: "alice"}))
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_fu2", user_id: "bob"}))

      logs = McpLog.list(athanor_id: "ath_test", user_id: "alice")
      assert Enum.all?(logs, &(&1.user_id == "alice"))
    end

    test "filters by status" do
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_fs1", status: "success"}))
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_fs2", status: "error"}))

      logs = McpLog.list(athanor_id: "ath_test", status: "error")
      assert logs != []
      assert Enum.all?(logs, &(&1.status == "error"))
    end

    # The chain key: an ingress request and every in-chain call beneath it
    # share one `request_id` while each row keeps its own `id`.
    test "filters by request_id, returning a whole chain" do
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_root_a", request_id: "req_root_a"}))
      {:ok, _} = McpLog.record(log_attrs(%{id: "call_a1", request_id: "req_root_a"}))
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_root_b", request_id: "req_root_b"}))

      logs = McpLog.list(athanor_id: "ath_test", request_id: "req_root_a")
      assert logs != []
      assert length(logs) == 2
      assert Enum.all?(logs, &(&1.request_id == "req_root_a"))
      assert Enum.sort(Enum.map(logs, & &1.id)) == ["call_a1", "req_root_a"]
    end

    test "filters by tool" do
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_ft1", tool: "storage"}))
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_ft2", tool: "execution"}))

      logs = McpLog.list(athanor_id: "ath_test", tool: "storage")
      assert logs != []
      assert Enum.all?(logs, &(&1.tool == "storage"))
    end

    test "filters by since" do
      old_time = DateTime.add(DateTime.utc_now(), -3600, :second)
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_since1", timestamp: old_time}))
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_since2", timestamp: DateTime.utc_now()}))

      cutoff = DateTime.add(DateTime.utc_now(), -60, :second)
      logs = McpLog.list(athanor_id: "ath_test", since: cutoff)
      ids = Enum.map(logs, & &1.id)
      assert "req_since2" in ids
      refute "req_since1" in ids
    end

    test "respects limit" do
      for i <- 1..5 do
        {:ok, _} = McpLog.record(log_attrs(%{id: "req_lim_#{i}"}))
      end

      logs = McpLog.list(athanor_id: "ath_test", limit: 2)
      assert length(logs) <= 2
    end
  end

  describe "get_tenant/2" do
    test "platform scope returns log without tenant filtering" do
      {:ok, log} =
        McpLog.record(log_attrs(%{id: "req_plat", athanor_id: "ath_x"}))

      platform_ctx =
        Context.build(
          scope: :platform,
          user_id: "admin",
          permissions: [:*],
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      assert %McpLog{id: "req_plat"} = McpLog.get_tenant(platform_ctx, log.id)
    end

    test "athanor scope filters by tenant" do
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_t1", athanor_id: "ath_a"}))

      ctx_match =
        Context.build(
          user_id: "u",
          athanor_id: "ath_a",
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      ctx_miss =
        Context.build(
          user_id: "u",
          athanor_id: "ath_b",
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      assert %McpLog{} = McpLog.get_tenant(ctx_match, "req_t1")
      assert is_nil(McpLog.get_tenant(ctx_miss, "req_t1"))
    end
  end

  describe "delete_before/2" do
    test "deletes logs before cutoff scoped by tenant" do
      old_time = DateTime.add(DateTime.utc_now(), -7200, :second)
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_del1", timestamp: old_time}))
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_del2", timestamp: DateTime.utc_now()}))

      cutoff = DateTime.add(DateTime.utc_now(), -60, :second)
      {count, _} = McpLog.delete_before(cutoff, athanor_id: "ath_test")
      assert count >= 1

      platform_ctx =
        Context.build(
          scope: :platform,
          user_id: "admin",
          permissions: [:*],
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      assert is_nil(McpLog.get_tenant(platform_ctx, "req_del1"))
      assert %McpLog{} = McpLog.get_tenant(platform_ctx, "req_del2")
    end

    test "respects tenant scoping" do
      old_time = DateTime.add(DateTime.utc_now(), -7200, :second)

      {:ok, _} =
        McpLog.record(
          log_attrs(%{
            id: "req_delt1",
            timestamp: old_time,
            athanor_id: "ath_a"
          })
        )

      {:ok, _} =
        McpLog.record(
          log_attrs(%{
            id: "req_delt2",
            timestamp: old_time,
            athanor_id: "ath_b"
          })
        )

      cutoff = DateTime.add(DateTime.utc_now(), -60, :second)
      {count, _} = McpLog.delete_before(cutoff, athanor_id: "ath_a")
      assert count >= 1

      platform_ctx =
        Context.build(
          scope: :platform,
          user_id: "admin",
          permissions: [:*],
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      # ath_a record deleted
      assert is_nil(McpLog.get_tenant(platform_ctx, "req_delt1"))
      # ath_b record untouched
      assert %McpLog{} = McpLog.get_tenant(platform_ctx, "req_delt2")
    end
  end

  describe "stats/1" do
    test "returns aggregated stats" do
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_st1", status: "success", duration_ms: 100}))
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_st2", status: "success", duration_ms: 200}))
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_st3", status: "error", duration_ms: 50}))

      stats = McpLog.stats(athanor_id: "ath_test")
      assert stats.total >= 3
      assert stats.errors >= 1
      assert is_integer(stats.avg_duration_ms)
    end

    test "filters by since" do
      old_time = DateTime.add(DateTime.utc_now(), -7200, :second)

      {:ok, _} =
        McpLog.record(log_attrs(%{id: "req_sts1", timestamp: old_time, status: "success"}))

      {:ok, _} =
        McpLog.record(
          log_attrs(%{id: "req_sts2", timestamp: DateTime.utc_now(), status: "success"})
        )

      cutoff = DateTime.add(DateTime.utc_now(), -60, :second)
      stats = McpLog.stats(athanor_id: "ath_test", since: cutoff)
      # Only recent log should be counted
      assert stats.total >= 1
    end
  end

  describe "tenant isolation" do
    test "list/1 only returns logs from the specified tenant" do
      {ctx_a, ctx_b} = Arca.TenantTestHelper.two_contexts()

      {:ok, _} =
        McpLog.record(log_attrs(%{id: "req_iso_a", athanor_id: ctx_a.athanor_id}))

      {:ok, _} =
        McpLog.record(log_attrs(%{id: "req_iso_b", athanor_id: ctx_b.athanor_id}))

      logs_a = McpLog.list(athanor_id: ctx_a.athanor_id)
      logs_b = McpLog.list(athanor_id: ctx_b.athanor_id)

      ids_a = Enum.map(logs_a, & &1.id)
      ids_b = Enum.map(logs_b, & &1.id)

      assert "req_iso_a" in ids_a
      refute "req_iso_b" in ids_a
      assert "req_iso_b" in ids_b
      refute "req_iso_a" in ids_b
    end

    test "stats/1 respects tenant boundaries" do
      {ctx_a, ctx_b} = Arca.TenantTestHelper.two_contexts()

      {:ok, _} =
        McpLog.record(
          log_attrs(%{
            id: "req_iso_s1",
            athanor_id: ctx_a.athanor_id,
            status: "error"
          })
        )

      {:ok, _} =
        McpLog.record(
          log_attrs(%{
            id: "req_iso_s2",
            athanor_id: ctx_b.athanor_id,
            status: "success"
          })
        )

      stats_a = McpLog.stats(athanor_id: ctx_a.athanor_id)
      stats_b = McpLog.stats(athanor_id: ctx_b.athanor_id)

      assert stats_a.errors >= 1
      assert stats_b.errors == 0
    end
  end
end
