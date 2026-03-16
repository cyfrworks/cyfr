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
        org_id: "",
        project_id: "default",
        timestamp: DateTime.utc_now(),
        status: "pending",
        tool: "execution",
        action: "run",
        method: "tools/call",
        session_id: "sess_1"
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
      ctx = Context.build(scope: :platform, user_id: "admin", permissions: [:*], auth_method: :local, authenticated: true)

      assert {:ok, updated} = McpLog.record_update(ctx, log.id, %{status: "success", duration_ms: 42})
      assert updated.status == "success"
      assert updated.duration_ms == 42
    end

    test "returns not_found for missing log" do
      ctx = Context.build(scope: :platform, user_id: "admin", permissions: [:*], auth_method: :local, authenticated: true)
      assert {:error, :not_found} = McpLog.record_update(ctx, "req_nonexistent", %{status: "success"})
    end

    test "cross-tenant update returns not_found" do
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_cross", org_id: "org_a", project_id: "proj_1"}))

      ctx_other = Context.build(user_id: "u", org_id: "org_b", project_id: "proj_2", permissions: [:*], scope: :project, auth_method: :local, authenticated: true)
      assert {:error, :not_found} = McpLog.record_update(ctx_other, "req_cross", %{status: "success"})
    end
  end

  describe "list/1" do
    test "returns logs ordered by timestamp desc" do
      t1 = DateTime.add(DateTime.utc_now(), -60, :second)
      t2 = DateTime.utc_now()

      {:ok, _} = McpLog.record(log_attrs(%{id: "req_l1", timestamp: t1}))
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_l2", timestamp: t2}))

      logs = McpLog.list(org_id: "", project_id: "default")
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

      logs = McpLog.list(org_id: "", project_id: "default", user_id: "alice")
      assert Enum.all?(logs, &(&1.user_id == "alice"))
    end

    test "filters by status" do
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_fs1", status: "success"}))
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_fs2", status: "error"}))

      logs = McpLog.list(org_id: "", project_id: "default", status: "error")
      assert length(logs) >= 1
      assert Enum.all?(logs, &(&1.status == "error"))
    end

    test "filters by session_id" do
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_fss1", session_id: "sess_a"}))
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_fss2", session_id: "sess_b"}))

      logs = McpLog.list(org_id: "", project_id: "default", session_id: "sess_a")
      assert length(logs) >= 1
      assert Enum.all?(logs, &(&1.session_id == "sess_a"))
    end

    test "filters by tool" do
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_ft1", tool: "storage"}))
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_ft2", tool: "execution"}))

      logs = McpLog.list(org_id: "", project_id: "default", tool: "storage")
      assert length(logs) >= 1
      assert Enum.all?(logs, &(&1.tool == "storage"))
    end

    test "filters by since" do
      old_time = DateTime.add(DateTime.utc_now(), -3600, :second)
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_since1", timestamp: old_time}))
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_since2", timestamp: DateTime.utc_now()}))

      cutoff = DateTime.add(DateTime.utc_now(), -60, :second)
      logs = McpLog.list(org_id: "", project_id: "default", since: cutoff)
      ids = Enum.map(logs, & &1.id)
      assert "req_since2" in ids
      refute "req_since1" in ids
    end

    test "respects limit" do
      for i <- 1..5 do
        {:ok, _} = McpLog.record(log_attrs(%{id: "req_lim_#{i}"}))
      end

      logs = McpLog.list(org_id: "", project_id: "default", limit: 2)
      assert length(logs) <= 2
    end
  end

  describe "get_tenant/2" do
    test "platform scope returns log without tenant filtering" do
      {:ok, log} = McpLog.record(log_attrs(%{id: "req_plat", org_id: "org_x", project_id: "proj_x"}))

      platform_ctx = Context.build(scope: :platform, user_id: "admin", permissions: [:*], auth_method: :local, authenticated: true)
      assert %McpLog{id: "req_plat"} = McpLog.get_tenant(platform_ctx, log.id)
    end

    test "project scope filters by tenant" do
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_t1", org_id: "org_a", project_id: "proj_1"}))

      ctx_match = Context.build(user_id: "u", org_id: "org_a", project_id: "proj_1", permissions: [:*], scope: :project, auth_method: :local, authenticated: true)
      ctx_miss = Context.build(user_id: "u", org_id: "org_b", project_id: "proj_2", permissions: [:*], scope: :project, auth_method: :local, authenticated: true)

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
      {count, _} = McpLog.delete_before(cutoff, org_id: "", project_id: "default")
      assert count >= 1

      platform_ctx = Context.build(scope: :platform, user_id: "admin", permissions: [:*], auth_method: :local, authenticated: true)
      assert is_nil(McpLog.get_tenant(platform_ctx, "req_del1"))
      assert %McpLog{} = McpLog.get_tenant(platform_ctx, "req_del2")
    end

    test "respects tenant scoping" do
      old_time = DateTime.add(DateTime.utc_now(), -7200, :second)
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_delt1", timestamp: old_time, org_id: "org_a", project_id: "proj_1"}))
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_delt2", timestamp: old_time, org_id: "org_b", project_id: "proj_2"}))

      cutoff = DateTime.add(DateTime.utc_now(), -60, :second)
      {count, _} = McpLog.delete_before(cutoff, org_id: "org_a", project_id: "proj_1")
      assert count >= 1

      platform_ctx = Context.build(scope: :platform, user_id: "admin", permissions: [:*], auth_method: :local, authenticated: true)
      # org_a record deleted
      assert is_nil(McpLog.get_tenant(platform_ctx, "req_delt1"))
      # org_b record untouched
      assert %McpLog{} = McpLog.get_tenant(platform_ctx, "req_delt2")
    end
  end

  describe "stats/1" do
    test "returns aggregated stats" do
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_st1", status: "success", duration_ms: 100}))
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_st2", status: "success", duration_ms: 200}))
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_st3", status: "error", duration_ms: 50}))

      stats = McpLog.stats(org_id: "", project_id: "default")
      assert stats.total >= 3
      assert stats.errors >= 1
      assert is_integer(stats.avg_duration_ms)
    end

    test "filters by since" do
      old_time = DateTime.add(DateTime.utc_now(), -7200, :second)
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_sts1", timestamp: old_time, status: "success"}))
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_sts2", timestamp: DateTime.utc_now(), status: "success"}))

      cutoff = DateTime.add(DateTime.utc_now(), -60, :second)
      stats = McpLog.stats(org_id: "", project_id: "default", since: cutoff)
      # Only recent log should be counted
      assert stats.total >= 1
    end
  end

  describe "tenant isolation" do
    test "list/1 only returns logs from the specified tenant" do
      {ctx_a, ctx_b} = Arca.TenantTestHelper.two_contexts()

      {:ok, _} = McpLog.record(log_attrs(%{id: "req_iso_a", org_id: ctx_a.org_id, project_id: ctx_a.project_id}))
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_iso_b", org_id: ctx_b.org_id, project_id: ctx_b.project_id}))

      logs_a = McpLog.list(org_id: ctx_a.org_id, project_id: ctx_a.project_id)
      logs_b = McpLog.list(org_id: ctx_b.org_id, project_id: ctx_b.project_id)

      ids_a = Enum.map(logs_a, & &1.id)
      ids_b = Enum.map(logs_b, & &1.id)

      assert "req_iso_a" in ids_a
      refute "req_iso_b" in ids_a
      assert "req_iso_b" in ids_b
      refute "req_iso_a" in ids_b
    end

    test "stats/1 respects tenant boundaries" do
      {ctx_a, ctx_b} = Arca.TenantTestHelper.two_contexts()

      {:ok, _} = McpLog.record(log_attrs(%{id: "req_iso_s1", org_id: ctx_a.org_id, project_id: ctx_a.project_id, status: "error"}))
      {:ok, _} = McpLog.record(log_attrs(%{id: "req_iso_s2", org_id: ctx_b.org_id, project_id: ctx_b.project_id, status: "success"}))

      stats_a = McpLog.stats(org_id: ctx_a.org_id, project_id: ctx_a.project_id)
      stats_b = McpLog.stats(org_id: ctx_b.org_id, project_id: ctx_b.project_id)

      assert stats_a.errors >= 1
      assert stats_b.errors == 0
    end
  end
end
