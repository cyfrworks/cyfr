# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PolicyLogTest do
  use ExUnit.Case, async: false

  alias Arca.PolicyLog
  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  defp log_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        id: "pl_#{:rand.uniform(1_000_000)}",
        user_id: "user_1",
        org_id: "local",
        project_id: "default",
        timestamp: DateTime.utc_now(),
        event_type: "policy_consultation",
        component_ref: "math:1.0.0",
        component_type: "formula",
        decision: "allowed",
        decision_reason: "default policy"
      },
      overrides
    )
  end

  describe "record/1" do
    test "inserts a valid policy log" do
      attrs = log_attrs()
      assert {:ok, log} = PolicyLog.record(attrs)
      assert log.id == attrs.id
      assert log.user_id == "user_1"
      assert log.event_type == "policy_consultation"
      assert log.decision == "allowed"
    end

    test "rejects missing required fields" do
      assert {:error, changeset} = PolicyLog.record(%{})
      refute changeset.valid?
    end
  end

  describe "list/1" do
    test "returns logs ordered by timestamp desc" do
      t1 = DateTime.add(DateTime.utc_now(), -60, :second)
      t2 = DateTime.utc_now()

      {:ok, _} = PolicyLog.record(log_attrs(%{id: "pl_list_1", timestamp: t1}))
      {:ok, _} = PolicyLog.record(log_attrs(%{id: "pl_list_2", timestamp: t2}))

      logs = PolicyLog.list(org_id: "local", project_id: "default")
      ids = Enum.map(logs, & &1.id)
      assert "pl_list_2" in ids
      assert "pl_list_1" in ids
      # Most recent first
      idx1 = Enum.find_index(ids, &(&1 == "pl_list_2"))
      idx2 = Enum.find_index(ids, &(&1 == "pl_list_1"))
      assert idx1 < idx2
    end

    test "filters by user_id" do
      {:ok, _} = PolicyLog.record(log_attrs(%{id: "pl_u1", user_id: "alice"}))
      {:ok, _} = PolicyLog.record(log_attrs(%{id: "pl_u2", user_id: "bob"}))

      logs = PolicyLog.list(org_id: "local", project_id: "default", user_id: "alice")
      assert Enum.all?(logs, &(&1.user_id == "alice"))
    end

    test "filters by request_id" do
      {:ok, _} = PolicyLog.record(log_attrs(%{id: "pl_r1", request_id: "req_123"}))
      {:ok, _} = PolicyLog.record(log_attrs(%{id: "pl_r2", request_id: "req_456"}))

      logs = PolicyLog.list(org_id: "local", project_id: "default", request_id: "req_123")
      assert logs != []
      assert Enum.all?(logs, &(&1.request_id == "req_123"))
    end

    test "filters by execution_id" do
      {:ok, _} = PolicyLog.record(log_attrs(%{id: "pl_e1", execution_id: "exec_1"}))
      {:ok, _} = PolicyLog.record(log_attrs(%{id: "pl_e2", execution_id: "exec_2"}))

      logs = PolicyLog.list(org_id: "local", project_id: "default", execution_id: "exec_1")
      assert logs != []
      assert Enum.all?(logs, &(&1.execution_id == "exec_1"))
    end

    test "filters by event_type" do
      {:ok, _} = PolicyLog.record(log_attrs(%{id: "pl_et1", event_type: "denied"}))
      {:ok, _} = PolicyLog.record(log_attrs(%{id: "pl_et2", event_type: "violation"}))

      logs = PolicyLog.list(org_id: "local", project_id: "default", event_type: "denied")
      assert logs != []
      assert Enum.all?(logs, &(&1.event_type == "denied"))
    end

    test "respects limit" do
      for i <- 1..5 do
        {:ok, _} = PolicyLog.record(log_attrs(%{id: "pl_lim_#{i}"}))
      end

      logs = PolicyLog.list(org_id: "local", project_id: "default", limit: 2)
      assert length(logs) <= 2
    end
  end

  describe "get_tenant/2" do
    test "platform scope returns log without tenant filtering" do
      {:ok, log} =
        PolicyLog.record(log_attrs(%{id: "pl_plat", org_id: "org_x", project_id: "proj_x"}))

      platform_ctx =
        Context.build(
          scope: :platform,
          user_id: "admin",
          permissions: [:*],
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      assert %PolicyLog{id: "pl_plat"} = PolicyLog.get_tenant(platform_ctx, log.id)
    end

    test "project scope filters by tenant" do
      {:ok, _} =
        PolicyLog.record(log_attrs(%{id: "pl_t1", org_id: "org_a", project_id: "proj_1"}))

      ctx_match =
        Context.build(
          user_id: "u",
          org_id: "org_a",
          project_id: "proj_1",
          permissions: [:*],
          scope: :project,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      ctx_miss =
        Context.build(
          user_id: "u",
          org_id: "org_b",
          project_id: "proj_2",
          permissions: [:*],
          scope: :project,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      assert %PolicyLog{} = PolicyLog.get_tenant(ctx_match, "pl_t1")
      assert is_nil(PolicyLog.get_tenant(ctx_miss, "pl_t1"))
    end
  end

  describe "get_by_request_id_tenant/2" do
    test "platform scope returns log by request_id" do
      {:ok, _} = PolicyLog.record(log_attrs(%{id: "pl_br1", request_id: "req_plat"}))

      platform_ctx =
        Context.build(
          scope: :platform,
          user_id: "admin",
          permissions: [:*],
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      assert %PolicyLog{request_id: "req_plat"} =
               PolicyLog.get_by_request_id_tenant(platform_ctx, "req_plat")
    end

    test "project scope filters by tenant" do
      {:ok, _} =
        PolicyLog.record(
          log_attrs(%{
            id: "pl_br2",
            request_id: "req_scoped",
            org_id: "org_a",
            project_id: "proj_1"
          })
        )

      ctx_match =
        Context.build(
          user_id: "u",
          org_id: "org_a",
          project_id: "proj_1",
          permissions: [:*],
          scope: :project,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      ctx_miss =
        Context.build(
          user_id: "u",
          org_id: "org_b",
          project_id: "proj_2",
          permissions: [:*],
          scope: :project,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      assert %PolicyLog{} = PolicyLog.get_by_request_id_tenant(ctx_match, "req_scoped")
      assert is_nil(PolicyLog.get_by_request_id_tenant(ctx_miss, "req_scoped"))
    end
  end

  describe "tenant isolation" do
    test "list/1 only returns logs from the specified tenant" do
      {ctx_a, ctx_b} = Arca.TenantTestHelper.two_contexts()

      {:ok, _} =
        PolicyLog.record(
          log_attrs(%{id: "pl_iso_a", org_id: ctx_a.org_id, project_id: ctx_a.project_id})
        )

      {:ok, _} =
        PolicyLog.record(
          log_attrs(%{id: "pl_iso_b", org_id: ctx_b.org_id, project_id: ctx_b.project_id})
        )

      logs_a = PolicyLog.list(org_id: ctx_a.org_id, project_id: ctx_a.project_id)
      logs_b = PolicyLog.list(org_id: ctx_b.org_id, project_id: ctx_b.project_id)

      ids_a = Enum.map(logs_a, & &1.id)
      ids_b = Enum.map(logs_b, & &1.id)

      assert "pl_iso_a" in ids_a
      refute "pl_iso_b" in ids_a
      assert "pl_iso_b" in ids_b
      refute "pl_iso_a" in ids_b
    end
  end
end
