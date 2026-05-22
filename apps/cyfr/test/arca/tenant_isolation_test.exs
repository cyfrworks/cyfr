# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.TenantIsolationTest do
  use ExUnit.Case, async: false

  alias Arca.TenantTestHelper

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_dir = Path.join(System.tmp_dir!(), "tenant_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    Application.put_env(:cyfr, :base_path, test_dir)
    Application.put_env(:cyfr, :components_path, Path.join(test_dir, "components"))

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    :ok
  end

  # ============================================================================
  # ComponentStorage Isolation
  # ============================================================================

  describe "ComponentStorage tenant isolation" do
    test "create as A, B cannot see" do
      {ctx_a, ctx_b} = TenantTestHelper.two_contexts()

      attrs = %{
        id: "comp_tenant_test_1",
        name: "tenant-widget",
        version: "1.0.0",
        component_type: "reagent",
        description: "A's widget",
        tags: "[]",
        digest: "sha256:aaa",
        size: 100,
        exports: "[]",
        manifest: nil,
        publisher: "local",
        publisher_id: ctx_a.user_id,
        org_id: ctx_a.org_id,
        project_id: ctx_a.project_id,
        source: "published",
        signature_verified: false,
        signer_identity: nil,
        signer_issuer: nil,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      {:ok, _} = Arca.ComponentStorage.put_component(ctx_a, attrs)

      # A can see it
      {:ok, comp} = Arca.ComponentStorage.get_component(ctx_a, "tenant-widget", "1.0.0")
      assert comp.name == "tenant-widget"

      # B cannot see it
      {:error, :not_found} = Arca.ComponentStorage.get_component(ctx_b, "tenant-widget", "1.0.0")

      # list_components for A includes it
      {:ok, a_list} = Arca.ComponentStorage.list_components(ctx_a)
      assert Enum.any?(a_list, &(&1.name == "tenant-widget"))

      # list_components for B does NOT include it
      {:ok, b_list} = Arca.ComponentStorage.list_components(ctx_b)
      refute Enum.any?(b_list, &(&1.name == "tenant-widget"))
    end

    test "same org, different projects are isolated" do
      {ctx_a, ctx_b} = TenantTestHelper.same_org_contexts()

      attrs = %{
        id: "comp_sameorg_test",
        name: "shared-org-widget",
        version: "1.0.0",
        component_type: "reagent",
        description: "Org-shared widget in proj_1",
        tags: "[]",
        digest: "sha256:bbb",
        size: 100,
        exports: "[]",
        manifest: nil,
        publisher: "local",
        publisher_id: ctx_a.user_id,
        org_id: ctx_a.org_id,
        project_id: ctx_a.project_id,
        source: "published",
        signature_verified: false,
        signer_identity: nil,
        signer_issuer: nil,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      {:ok, _} = Arca.ComponentStorage.put_component(ctx_a, attrs)

      # Same org but different project cannot see it
      {:error, :not_found} =
        Arca.ComponentStorage.get_component(ctx_b, "shared-org-widget", "1.0.0")
    end

    test "exists? respects tenant boundary" do
      {ctx_a, ctx_b} = TenantTestHelper.two_contexts()

      attrs = %{
        id: "comp_exists_test",
        name: "exists-widget",
        version: "1.0.0",
        component_type: "reagent",
        description: "exists check",
        tags: "[]",
        digest: "sha256:ccc",
        size: 100,
        exports: "[]",
        manifest: nil,
        publisher: "local",
        publisher_id: ctx_a.user_id,
        org_id: ctx_a.org_id,
        project_id: ctx_a.project_id,
        source: "published",
        signature_verified: false,
        signer_identity: nil,
        signer_issuer: nil,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      {:ok, _} = Arca.ComponentStorage.put_component(ctx_a, attrs)

      assert Arca.ComponentStorage.exists?(ctx_a, "exists-widget", "1.0.0")
      refute Arca.ComponentStorage.exists?(ctx_b, "exists-widget", "1.0.0")
    end

    test "delete respects tenant boundary" do
      {ctx_a, ctx_b} = TenantTestHelper.two_contexts()

      attrs = %{
        id: "comp_delete_test",
        name: "delete-widget",
        version: "1.0.0",
        component_type: "reagent",
        description: "delete check",
        tags: "[]",
        digest: "sha256:ddd",
        size: 100,
        exports: "[]",
        manifest: nil,
        publisher: "local",
        publisher_id: ctx_a.user_id,
        org_id: ctx_a.org_id,
        project_id: ctx_a.project_id,
        source: "published",
        signature_verified: false,
        signer_identity: nil,
        signer_issuer: nil,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      {:ok, _} = Arca.ComponentStorage.put_component(ctx_a, attrs)

      # B tries to delete — should not affect A's component
      Arca.ComponentStorage.delete_component(ctx_b, "delete-widget", "1.0.0")

      # A can still see it
      assert Arca.ComponentStorage.exists?(ctx_a, "delete-widget", "1.0.0")
    end
  end

  # ============================================================================
  # PolicyStorage Isolation
  # ============================================================================

  describe "PolicyStorage tenant isolation" do
    test "create as A, B cannot see" do
      {ctx_a, ctx_b} = TenantTestHelper.two_contexts()

      now = DateTime.to_iso8601(DateTime.utc_now())

      attrs = %{
        id: "pol_tenant_test_1",
        component_ref: "catalyst:local.tenant-pol-widget:1.0.0",
        component_type: "catalyst",
        allowed_domains: "[\"example.com\"]",
        allowed_methods: "[]",
        timeout: "30s",
        max_memory_bytes: 67_108_864,
        max_request_size: 1_048_576,
        max_response_size: 5_242_880,
        allowed_tools: "[]",
        allowed_paths: "[]",
        allowed_actions: "[]",
        batch_timeout: "5m",
        max_concurrent_tasks: 10,
        allowed_private_ips: "[]",
        inserted_at: now,
        updated_at: now
      }

      {:ok, _} = Arca.PolicyStorage.put_policy(ctx_a, attrs)

      # A can see it
      {:ok, pol} = Arca.PolicyStorage.get_policy(ctx_a, "catalyst:local.tenant-pol-widget:1.0.0")
      assert pol.component_ref == "catalyst:local.tenant-pol-widget:1.0.0"

      # B cannot see it
      {:error, :not_found} =
        Arca.PolicyStorage.get_policy(ctx_b, "catalyst:local.tenant-pol-widget:1.0.0")

      # list_policies for A includes it
      {:ok, a_list} = Arca.PolicyStorage.list_policies(ctx_a)
      assert Enum.any?(a_list, &(&1.component_ref == "catalyst:local.tenant-pol-widget:1.0.0"))

      # list_policies for B does NOT include it
      {:ok, b_list} = Arca.PolicyStorage.list_policies(ctx_b)
      refute Enum.any?(b_list, &(&1.component_ref == "catalyst:local.tenant-pol-widget:1.0.0"))
    end

    test "delete respects tenant boundary" do
      {ctx_a, ctx_b} = TenantTestHelper.two_contexts()

      now = DateTime.to_iso8601(DateTime.utc_now())

      attrs = %{
        id: "pol_delete_test",
        component_ref: "catalyst:local.pol-delete-widget:1.0.0",
        component_type: "catalyst",
        allowed_domains: "[]",
        allowed_methods: "[]",
        timeout: "30s",
        max_memory_bytes: 67_108_864,
        max_request_size: 1_048_576,
        max_response_size: 5_242_880,
        allowed_tools: "[]",
        allowed_paths: "[]",
        allowed_actions: "[]",
        batch_timeout: "5m",
        max_concurrent_tasks: 10,
        allowed_private_ips: "[]",
        inserted_at: now,
        updated_at: now
      }

      {:ok, _} = Arca.PolicyStorage.put_policy(ctx_a, attrs)

      # B tries to delete — should not affect A's policy
      Arca.PolicyStorage.delete_policy(ctx_b, "catalyst:local.pol-delete-widget:1.0.0")

      # A can still see it
      {:ok, _} = Arca.PolicyStorage.get_policy(ctx_a, "catalyst:local.pol-delete-widget:1.0.0")
    end

    test "same org, different projects are isolated" do
      {ctx_a, ctx_b} = TenantTestHelper.same_org_contexts()

      now = DateTime.to_iso8601(DateTime.utc_now())

      attrs = %{
        id: "pol_sameorg_test",
        component_ref: "catalyst:local.sameorg-pol:1.0.0",
        component_type: "catalyst",
        allowed_domains: "[]",
        allowed_methods: "[]",
        timeout: "30s",
        max_memory_bytes: 67_108_864,
        max_request_size: 1_048_576,
        max_response_size: 5_242_880,
        allowed_tools: "[]",
        allowed_paths: "[]",
        allowed_actions: "[]",
        batch_timeout: "5m",
        max_concurrent_tasks: 10,
        allowed_private_ips: "[]",
        inserted_at: now,
        updated_at: now
      }

      {:ok, _} = Arca.PolicyStorage.put_policy(ctx_a, attrs)

      # Same org but different project cannot see it
      {:error, :not_found} =
        Arca.PolicyStorage.get_policy(ctx_b, "catalyst:local.sameorg-pol:1.0.0")
    end
  end

  # ============================================================================
  # Execution Isolation
  # ============================================================================

  describe "Execution get_tenant/2 tenant isolation" do
    test "cross-tenant get returns nil" do
      {ctx_a, ctx_b} = TenantTestHelper.two_contexts()

      {:ok, _} =
        Arca.Execution.record_start(%{
          id: "exec_cross_a",
          reference: "reagent:local.test:0.1.0",
          user_id: ctx_a.user_id,
          org_id: ctx_a.org_id,
          project_id: ctx_a.project_id,
          component_type: "reagent",
          started_at: DateTime.utc_now(),
          status: "running"
        })

      # A can get their own execution
      assert %Arca.Execution{id: "exec_cross_a"} =
               Arca.Execution.get_tenant(ctx_a, "exec_cross_a")

      # B cannot get A's execution
      assert nil == Arca.Execution.get_tenant(ctx_b, "exec_cross_a")
    end

    test "same org, different project returns nil" do
      {ctx_a, ctx_b} = TenantTestHelper.same_org_contexts()

      {:ok, _} =
        Arca.Execution.record_start(%{
          id: "exec_sameorg_a",
          reference: "reagent:local.test:0.1.0",
          user_id: ctx_a.user_id,
          org_id: ctx_a.org_id,
          project_id: ctx_a.project_id,
          component_type: "reagent",
          started_at: DateTime.utc_now(),
          status: "running"
        })

      assert %Arca.Execution{} = Arca.Execution.get_tenant(ctx_a, "exec_sameorg_a")
      assert nil == Arca.Execution.get_tenant(ctx_b, "exec_sameorg_a")
    end

    test "platform scope bypasses tenant check" do
      {ctx_a, _ctx_b} = TenantTestHelper.two_contexts()

      {:ok, _} =
        Arca.Execution.record_start(%{
          id: "exec_platform_test",
          reference: "reagent:local.test:0.1.0",
          user_id: ctx_a.user_id,
          org_id: ctx_a.org_id,
          project_id: ctx_a.project_id,
          component_type: "reagent",
          started_at: DateTime.utc_now(),
          status: "running"
        })

      platform_ctx =
        Sanctum.Context.build(
          user_id: "platform_admin",
          permissions: [:*],
          scope: :platform,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      assert %Arca.Execution{id: "exec_platform_test"} =
               Arca.Execution.get_tenant(platform_ctx, "exec_platform_test")
    end
  end

  describe "Execution tenant filtering" do
    test "list filters by org_id and project_id" do
      {ctx_a, ctx_b} = TenantTestHelper.two_contexts()

      {:ok, _} =
        Arca.Execution.record_start(%{
          id: "exec_tenant_a",
          reference: "reagent:local.test:0.1.0",
          user_id: ctx_a.user_id,
          org_id: ctx_a.org_id,
          project_id: ctx_a.project_id,
          component_type: "reagent",
          started_at: DateTime.utc_now(),
          status: "running"
        })

      {:ok, _} =
        Arca.Execution.record_start(%{
          id: "exec_tenant_b",
          reference: "reagent:local.test:0.1.0",
          user_id: ctx_b.user_id,
          org_id: ctx_b.org_id,
          project_id: ctx_b.project_id,
          component_type: "reagent",
          started_at: DateTime.utc_now(),
          status: "running"
        })

      # Query with A's tenant filters
      a_results = Arca.Execution.list(org_id: ctx_a.org_id, project_id: ctx_a.project_id)
      assert length(a_results) == 1
      assert hd(a_results).id == "exec_tenant_a"

      # Query with B's tenant filters
      b_results = Arca.Execution.list(org_id: ctx_b.org_id, project_id: ctx_b.project_id)
      assert length(b_results) == 1
      assert hd(b_results).id == "exec_tenant_b"
    end
  end

  # ============================================================================
  # CronSchedule Isolation
  # ============================================================================

  describe "CronSchedule tenant isolation" do
    test "list_by_user scoped to tenant" do
      {ctx_a, ctx_b} = TenantTestHelper.two_contexts()

      {:ok, _} =
        Arca.CronSchedule.create(%{
          user_id: ctx_a.user_id,
          name: "sched-a",
          cron_expression: "*/5 * * * *",
          reference: "reagent:local.test:0.1.0",
          org_id: ctx_a.org_id,
          project_id: ctx_a.project_id
        })

      {:ok, _} =
        Arca.CronSchedule.create(%{
          user_id: ctx_b.user_id,
          name: "sched-b",
          cron_expression: "*/10 * * * *",
          reference: "reagent:local.test:0.1.0",
          org_id: ctx_b.org_id,
          project_id: ctx_b.project_id
        })

      a_schedules = Arca.CronSchedule.list_by_user(ctx_a)
      assert length(a_schedules) == 1
      assert hd(a_schedules).name == "sched-a"

      b_schedules = Arca.CronSchedule.list_by_user(ctx_b)
      assert length(b_schedules) == 1
      assert hd(b_schedules).name == "sched-b"
    end

    test "count_by_user scoped to tenant" do
      {ctx_a, ctx_b} = TenantTestHelper.two_contexts()

      {:ok, _} =
        Arca.CronSchedule.create(%{
          user_id: ctx_a.user_id,
          name: "count-sched-a",
          cron_expression: "*/5 * * * *",
          reference: "reagent:local.test:0.1.0",
          org_id: ctx_a.org_id,
          project_id: ctx_a.project_id
        })

      assert Arca.CronSchedule.count_by_user(ctx_a) == 1
      assert Arca.CronSchedule.count_by_user(ctx_b) == 0
    end

    test "get_by_user scoped to tenant" do
      {ctx_a, ctx_b} = TenantTestHelper.two_contexts()

      {:ok, sched} =
        Arca.CronSchedule.create(%{
          user_id: ctx_a.user_id,
          name: "get-sched-a",
          cron_expression: "*/5 * * * *",
          reference: "reagent:local.test:0.1.0",
          org_id: ctx_a.org_id,
          project_id: ctx_a.project_id
        })

      # A can find by name
      assert Arca.CronSchedule.get_by_user(ctx_a, "get-sched-a") != nil

      # B cannot find A's schedule even by ID
      assert Arca.CronSchedule.get_by_user(ctx_b, sched.id) == nil
    end
  end

  # ============================================================================
  # Component ID Collision (1a)
  # ============================================================================

  describe "Component ID includes tenant fields" do
    test "two tenants registering same component get different IDs" do
      {ctx_a, ctx_b} = TenantTestHelper.two_contexts()
      now = DateTime.utc_now()

      attrs_a = %{
        id: make_component_id("local", "shared-tool", "1.0.0", "reagent", ctx_a),
        name: "shared-tool",
        version: "1.0.0",
        component_type: "reagent",
        description: "Same component, tenant A",
        tags: "[]",
        digest: "sha256:same_digest",
        size: 100,
        exports: "[]",
        manifest: nil,
        publisher: "local",
        publisher_id: ctx_a.user_id,
        org_id: Arca.QueryHelpers.normalize_org_id(ctx_a.org_id),
        project_id: ctx_a.project_id || "default",
        source: "published",
        signature_verified: false,
        signer_identity: nil,
        signer_issuer: nil,
        inserted_at: now,
        updated_at: now
      }

      attrs_b = %{
        id: make_component_id("local", "shared-tool", "1.0.0", "reagent", ctx_b),
        name: "shared-tool",
        version: "1.0.0",
        component_type: "reagent",
        description: "Same component, tenant B",
        tags: "[]",
        digest: "sha256:same_digest",
        size: 100,
        exports: "[]",
        manifest: nil,
        publisher: "local",
        publisher_id: ctx_b.user_id,
        org_id: Arca.QueryHelpers.normalize_org_id(ctx_b.org_id),
        project_id: ctx_b.project_id || "default",
        source: "published",
        signature_verified: false,
        signer_identity: nil,
        signer_issuer: nil,
        inserted_at: now,
        updated_at: now
      }

      # IDs must differ
      assert attrs_a.id != attrs_b.id

      # Both rows survive in the database
      {:ok, _} = Arca.ComponentStorage.put_component(ctx_a, attrs_a)
      {:ok, _} = Arca.ComponentStorage.put_component(ctx_b, attrs_b)

      {:ok, comp_a} = Arca.ComponentStorage.get_component(ctx_a, "shared-tool", "1.0.0")
      {:ok, comp_b} = Arca.ComponentStorage.get_component(ctx_b, "shared-tool", "1.0.0")

      assert comp_a.description == "Same component, tenant A"
      assert comp_b.description == "Same component, tenant B"
      assert comp_a.id != comp_b.id
    end
  end

  # ============================================================================
  # DependencyStorage Isolation (1b)
  # ============================================================================

  describe "DependencyStorage tenant isolation" do
    test "tenant A's dependencies invisible to tenant B" do
      {ctx_a, ctx_b} = TenantTestHelper.two_contexts()

      comp_id = insert_stub_component(ctx_a, "dep-vis-comp", "comp_aaa")

      {:ok, 1} =
        Arca.DependencyStorage.put_dependencies(ctx_a, comp_id, [
          %{
            "dependency_ref" => "reagent:local.helper:1.0.0",
            "dep_type" => "reagent",
            "dep_namespace" => "local",
            "dep_name" => "helper",
            "dep_version" => "1.0.0",
            "optional" => 0,
            "reason" => nil
          }
        ])

      # A can see it
      {:ok, deps_a} = Arca.DependencyStorage.get_dependencies(ctx_a, comp_id)
      assert length(deps_a) == 1

      # B cannot see it
      {:ok, deps_b} = Arca.DependencyStorage.get_dependencies(ctx_b, comp_id)
      assert deps_b == []
    end

    test "delete scoped to tenant" do
      {ctx_a, ctx_b} = TenantTestHelper.two_contexts()

      comp_id = insert_stub_component(ctx_a, "dep-del-comp", "comp_del_dep")

      {:ok, 1} =
        Arca.DependencyStorage.put_dependencies(ctx_a, comp_id, [
          %{
            "dependency_ref" => "reagent:local.x:1.0.0",
            "dep_type" => "reagent",
            "dep_namespace" => "local",
            "dep_name" => "x",
            "dep_version" => "1.0.0",
            "optional" => 0,
            "reason" => nil
          }
        ])

      # B tries to delete — should not affect A's dependencies
      :ok = Arca.DependencyStorage.delete_dependencies(ctx_b, comp_id)

      {:ok, deps_a} = Arca.DependencyStorage.get_dependencies(ctx_a, comp_id)
      assert length(deps_a) == 1
    end

    test "reverse dependencies scoped to tenant" do
      {ctx_a, ctx_b} = TenantTestHelper.two_contexts()

      comp_id = insert_stub_component(ctx_a, "dep-rev-comp", "comp_rev")

      {:ok, 1} =
        Arca.DependencyStorage.put_dependencies(ctx_a, comp_id, [
          %{
            "dependency_ref" => "reagent:local.target:2.0.0",
            "dep_type" => "reagent",
            "dep_namespace" => "local",
            "dep_name" => "target",
            "dep_version" => "2.0.0",
            "optional" => 0,
            "reason" => nil
          }
        ])

      {:ok, rev_a} = Arca.DependencyStorage.get_reverse_dependencies(ctx_a, "target", "2.0.0")
      assert length(rev_a) == 1

      {:ok, rev_b} = Arca.DependencyStorage.get_reverse_dependencies(ctx_b, "target", "2.0.0")
      assert rev_b == []
    end
  end

  # ============================================================================
  # SecretStorage.delete_grants_for_component Isolation (1c)
  # ============================================================================

  describe "SecretStorage.delete_grants_for_component tenant isolation" do
    test "delete scoped to tenant — other tenant's grants survive" do
      {ctx_a, ctx_b} = TenantTestHelper.two_contexts()

      component_ref = "reagent:local.shared-comp:1.0.0"

      # Grant for tenant A
      :ok =
        Arca.SecretStorage.put_grant(
          "secret_a",
          component_ref,
          "project",
          ctx_a.org_id,
          ctx_a.project_id || "default"
        )

      # Grant for tenant B
      :ok =
        Arca.SecretStorage.put_grant(
          "secret_b",
          component_ref,
          "project",
          ctx_b.org_id,
          ctx_b.project_id || "default"
        )

      # Delete grants for tenant A only
      :ok = Arca.SecretStorage.delete_grants_for_component(ctx_a, component_ref)

      # A's grant is gone
      {:ok, grants_a} =
        Arca.SecretStorage.grants_for_component(
          component_ref,
          "project",
          ctx_a.org_id,
          ctx_a.project_id
        )

      assert grants_a == []

      # B's grant survives
      {:ok, grants_b} =
        Arca.SecretStorage.grants_for_component(
          component_ref,
          "project",
          ctx_b.org_id,
          ctx_b.project_id
        )

      assert grants_b == ["secret_b"]
    end
  end

  # ============================================================================
  # MCP Log Retention Isolation (1d)
  # ============================================================================

  describe "MCP log retention tenant isolation" do
    test "cleanup for one tenant doesn't affect another" do
      {ctx_a, ctx_b} = TenantTestHelper.two_contexts()

      old_time = DateTime.utc_now() |> DateTime.add(-60 * 86_400, :second)

      # Insert old log for tenant A
      {:ok, _} =
        Arca.McpLog.record(%{
          id: "log_tenant_a",
          user_id: ctx_a.user_id,
          org_id: Arca.QueryHelpers.normalize_org_id(ctx_a.org_id),
          project_id: ctx_a.project_id || "default",
          timestamp: old_time,
          status: "success",
          tool: "test",
          action: "run"
        })

      # Insert old log for tenant B
      {:ok, _} =
        Arca.McpLog.record(%{
          id: "log_tenant_b",
          user_id: ctx_b.user_id,
          org_id: Arca.QueryHelpers.normalize_org_id(ctx_b.org_id),
          project_id: ctx_b.project_id || "default",
          timestamp: old_time,
          status: "success",
          tool: "test",
          action: "run"
        })

      # Cleanup for tenant A with 1-day retention
      {:ok, count} = Arca.Retention.cleanup_mcp_logs(ctx_a, days: 1)
      assert count == 1

      # Tenant A's log is gone
      assert Arca.Repo.get(Arca.McpLog, "log_tenant_a") == nil

      # Tenant B's log survives
      assert Arca.Repo.get(Arca.McpLog, "log_tenant_b") != nil
    end

    test "dry_run scoped to tenant" do
      {ctx_a, ctx_b} = TenantTestHelper.two_contexts()

      old_time = DateTime.utc_now() |> DateTime.add(-60 * 86_400, :second)

      {:ok, _} =
        Arca.McpLog.record(%{
          id: "log_dry_a",
          user_id: ctx_a.user_id,
          org_id: Arca.QueryHelpers.normalize_org_id(ctx_a.org_id),
          project_id: ctx_a.project_id || "default",
          timestamp: old_time,
          status: "success"
        })

      {:ok, _} =
        Arca.McpLog.record(%{
          id: "log_dry_b",
          user_id: ctx_b.user_id,
          org_id: Arca.QueryHelpers.normalize_org_id(ctx_b.org_id),
          project_id: ctx_b.project_id || "default",
          timestamp: old_time,
          status: "success"
        })

      {:ok, %{would_delete: count_a}} =
        Arca.Retention.cleanup_mcp_logs(ctx_a, days: 1, dry_run: true)

      assert count_a == 1

      {:ok, %{would_delete: count_b}} =
        Arca.Retention.cleanup_mcp_logs(ctx_b, days: 1, dry_run: true)

      assert count_b == 1
    end
  end

  # ============================================================================
  # Execution Retention Tenant Isolation (Tier 1a)
  # ============================================================================

  describe "Execution retention tenant isolation" do
    test "cleanup for one tenant doesn't affect another" do
      {ctx_a, ctx_b} = TenantTestHelper.two_contexts()

      # Create 5 executions for each tenant
      for i <- 1..5 do
        {:ok, _} =
          Arca.Execution.record_start(%{
            id: "ret_a_#{i}",
            reference: "reagent:local.test:0.1.0",
            user_id: ctx_a.user_id,
            org_id: ctx_a.org_id,
            project_id: ctx_a.project_id,
            component_type: "reagent",
            started_at: DateTime.utc_now() |> DateTime.add(-i * 60, :second),
            status: "completed"
          })

        {:ok, _} =
          Arca.Execution.record_start(%{
            id: "ret_b_#{i}",
            reference: "reagent:local.test:0.1.0",
            user_id: ctx_b.user_id,
            org_id: ctx_b.org_id,
            project_id: ctx_b.project_id,
            component_type: "reagent",
            started_at: DateTime.utc_now() |> DateTime.add(-i * 60, :second),
            status: "completed"
          })
      end

      # Cleanup tenant A, keeping 2
      {:ok, count} = Arca.Retention.cleanup_executions(ctx_a, keep: 2)
      assert count == 3

      # Tenant A has 2
      a_results =
        Arca.Execution.list(org_id: ctx_a.org_id, project_id: ctx_a.project_id, limit: 100)

      assert length(a_results) == 2

      # Tenant B still has 5
      b_results =
        Arca.Execution.list(org_id: ctx_b.org_id, project_id: ctx_b.project_id, limit: 100)

      assert length(b_results) == 5
    end

    test "cleanup_all_executions scoped to tenant" do
      {ctx_a, ctx_b} = TenantTestHelper.two_contexts()

      for i <- 1..4 do
        {:ok, _} =
          Arca.Execution.record_start(%{
            id: "all_a_#{i}",
            reference: "reagent:local.test:0.1.0",
            user_id: ctx_a.user_id,
            org_id: ctx_a.org_id,
            project_id: ctx_a.project_id,
            component_type: "reagent",
            started_at: DateTime.utc_now() |> DateTime.add(-i * 60, :second),
            status: "completed"
          })

        {:ok, _} =
          Arca.Execution.record_start(%{
            id: "all_b_#{i}",
            reference: "reagent:local.test:0.1.0",
            user_id: ctx_b.user_id,
            org_id: ctx_b.org_id,
            project_id: ctx_b.project_id,
            component_type: "reagent",
            started_at: DateTime.utc_now() |> DateTime.add(-i * 60, :second),
            status: "completed"
          })
      end

      # Cleanup all executions scoped to tenant A
      {:ok, result} = Arca.Retention.cleanup_all_executions(ctx_a, keep: 1)
      assert result.deleted == 3

      # Tenant B unaffected
      b_results =
        Arca.Execution.list(org_id: ctx_b.org_id, project_id: ctx_b.project_id, limit: 100)

      assert length(b_results) == 4
    end

    test "dry_run scoped to tenant" do
      {ctx_a, ctx_b} = TenantTestHelper.two_contexts()

      for i <- 1..3 do
        {:ok, _} =
          Arca.Execution.record_start(%{
            id: "dry_a_#{i}",
            reference: "reagent:local.test:0.1.0",
            user_id: ctx_a.user_id,
            org_id: ctx_a.org_id,
            project_id: ctx_a.project_id,
            component_type: "reagent",
            started_at: DateTime.utc_now() |> DateTime.add(-i * 60, :second),
            status: "completed"
          })

        {:ok, _} =
          Arca.Execution.record_start(%{
            id: "dry_b_#{i}",
            reference: "reagent:local.test:0.1.0",
            user_id: ctx_b.user_id,
            org_id: ctx_b.org_id,
            project_id: ctx_b.project_id,
            component_type: "reagent",
            started_at: DateTime.utc_now() |> DateTime.add(-i * 60, :second),
            status: "completed"
          })
      end

      {:ok, result} = Arca.Retention.cleanup_executions(ctx_a, keep: 1, dry_run: true)
      assert length(result.would_delete) == 2
      assert result.would_keep == 1

      # All records still exist
      all_a = Arca.Execution.list(org_id: ctx_a.org_id, project_id: ctx_a.project_id, limit: 100)
      assert length(all_a) == 3
    end

    test "same org different projects isolated" do
      {ctx_a, ctx_b} = TenantTestHelper.same_org_contexts()

      for i <- 1..4 do
        {:ok, _} =
          Arca.Execution.record_start(%{
            id: "proj_a_#{i}",
            reference: "reagent:local.test:0.1.0",
            user_id: ctx_a.user_id,
            org_id: ctx_a.org_id,
            project_id: ctx_a.project_id,
            component_type: "reagent",
            started_at: DateTime.utc_now() |> DateTime.add(-i * 60, :second),
            status: "completed"
          })

        {:ok, _} =
          Arca.Execution.record_start(%{
            id: "proj_b_#{i}",
            reference: "reagent:local.test:0.1.0",
            user_id: ctx_b.user_id,
            org_id: ctx_b.org_id,
            project_id: ctx_b.project_id,
            component_type: "reagent",
            started_at: DateTime.utc_now() |> DateTime.add(-i * 60, :second),
            status: "completed"
          })
      end

      # Cleanup project A, keep 1
      {:ok, count} = Arca.Retention.cleanup_executions(ctx_a, keep: 1)
      assert count == 3

      # Project B unaffected
      b_results =
        Arca.Execution.list(org_id: ctx_b.org_id, project_id: ctx_b.project_id, limit: 100)

      assert length(b_results) == 4
    end
  end

  # ============================================================================
  # McpLog Tenant Isolation
  # ============================================================================

  describe "McpLog.get_tenant/2 tenant isolation" do
    test "cross-tenant get returns nil" do
      {ctx_a, ctx_b} = TenantTestHelper.two_contexts()

      {:ok, _} =
        Arca.McpLog.record(%{
          id: "mlog_cross_a",
          user_id: ctx_a.user_id,
          org_id: Arca.QueryHelpers.normalize_org_id(ctx_a.org_id),
          project_id: ctx_a.project_id || "default",
          timestamp: DateTime.utc_now(),
          status: "success",
          tool: "test",
          action: "run"
        })

      # A can get their own log
      assert %Arca.McpLog{id: "mlog_cross_a"} = Arca.McpLog.get_tenant(ctx_a, "mlog_cross_a")

      # B cannot get A's log
      assert nil == Arca.McpLog.get_tenant(ctx_b, "mlog_cross_a")
    end

    test "platform scope bypasses tenant check" do
      {ctx_a, _ctx_b} = TenantTestHelper.two_contexts()

      {:ok, _} =
        Arca.McpLog.record(%{
          id: "mlog_platform_test",
          user_id: ctx_a.user_id,
          org_id: Arca.QueryHelpers.normalize_org_id(ctx_a.org_id),
          project_id: ctx_a.project_id || "default",
          timestamp: DateTime.utc_now(),
          status: "success"
        })

      platform_ctx =
        Sanctum.Context.build(
          user_id: "platform_admin",
          permissions: [:*],
          scope: :platform,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      assert %Arca.McpLog{id: "mlog_platform_test"} =
               Arca.McpLog.get_tenant(platform_ctx, "mlog_platform_test")
    end
  end

  # ============================================================================
  # PolicyLog Tenant Isolation
  # ============================================================================

  describe "PolicyLog.get_tenant/2 tenant isolation" do
    test "cross-tenant get returns nil" do
      {ctx_a, ctx_b} = TenantTestHelper.two_contexts()

      {:ok, _} =
        Arca.PolicyLog.record(%{
          id: "plog_cross_a",
          user_id: ctx_a.user_id,
          org_id: Arca.QueryHelpers.normalize_org_id(ctx_a.org_id),
          project_id: ctx_a.project_id || "default",
          timestamp: DateTime.utc_now(),
          event_type: "policy_consultation",
          request_id: "req_plog_a"
        })

      # A can get their own log
      assert %Arca.PolicyLog{id: "plog_cross_a"} =
               Arca.PolicyLog.get_tenant(ctx_a, "plog_cross_a")

      # B cannot get A's log
      assert nil == Arca.PolicyLog.get_tenant(ctx_b, "plog_cross_a")
    end

    test "platform scope bypasses tenant check" do
      {ctx_a, _ctx_b} = TenantTestHelper.two_contexts()

      {:ok, _} =
        Arca.PolicyLog.record(%{
          id: "plog_platform_test",
          user_id: ctx_a.user_id,
          org_id: Arca.QueryHelpers.normalize_org_id(ctx_a.org_id),
          project_id: ctx_a.project_id || "default",
          timestamp: DateTime.utc_now(),
          event_type: "policy_consultation"
        })

      platform_ctx =
        Sanctum.Context.build(
          user_id: "platform_admin",
          permissions: [:*],
          scope: :platform,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      assert %Arca.PolicyLog{id: "plog_platform_test"} =
               Arca.PolicyLog.get_tenant(platform_ctx, "plog_platform_test")
    end
  end

  describe "PolicyLog.get_by_request_id_tenant/2 tenant isolation" do
    test "cross-tenant returns nil" do
      {ctx_a, ctx_b} = TenantTestHelper.two_contexts()

      {:ok, _} =
        Arca.PolicyLog.record(%{
          id: "plog_reqid_a",
          user_id: ctx_a.user_id,
          org_id: Arca.QueryHelpers.normalize_org_id(ctx_a.org_id),
          project_id: ctx_a.project_id || "default",
          timestamp: DateTime.utc_now(),
          event_type: "policy_consultation",
          request_id: "req_cross_tenant_123"
        })

      # A can find by request_id
      assert %Arca.PolicyLog{} =
               Arca.PolicyLog.get_by_request_id_tenant(ctx_a, "req_cross_tenant_123")

      # B cannot find A's log by request_id
      assert nil == Arca.PolicyLog.get_by_request_id_tenant(ctx_b, "req_cross_tenant_123")
    end

    test "platform scope bypasses tenant check" do
      {ctx_a, _ctx_b} = TenantTestHelper.two_contexts()

      {:ok, _} =
        Arca.PolicyLog.record(%{
          id: "plog_reqid_plat",
          user_id: ctx_a.user_id,
          org_id: Arca.QueryHelpers.normalize_org_id(ctx_a.org_id),
          project_id: ctx_a.project_id || "default",
          timestamp: DateTime.utc_now(),
          event_type: "policy_consultation",
          request_id: "req_platform_456"
        })

      platform_ctx =
        Sanctum.Context.build(
          user_id: "platform_admin",
          permissions: [:*],
          scope: :platform,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      assert %Arca.PolicyLog{} =
               Arca.PolicyLog.get_by_request_id_tenant(platform_ctx, "req_platform_456")
    end
  end

  # ============================================================================
  # McpLog.stats Tenant Isolation
  # ============================================================================

  describe "McpLog.stats tenant scoping" do
    test "stats scoped to tenant" do
      {ctx_a, ctx_b} = TenantTestHelper.two_contexts()

      now = DateTime.utc_now()

      # Insert 3 logs for tenant A
      for i <- 1..3 do
        {:ok, _} =
          Arca.McpLog.record(%{
            id: "stats_a_#{i}",
            user_id: ctx_a.user_id,
            org_id: Arca.QueryHelpers.normalize_org_id(ctx_a.org_id),
            project_id: ctx_a.project_id || "default",
            timestamp: now,
            status: "success",
            duration_ms: 100
          })
      end

      # Insert 2 logs for tenant B
      for i <- 1..2 do
        {:ok, _} =
          Arca.McpLog.record(%{
            id: "stats_b_#{i}",
            user_id: ctx_b.user_id,
            org_id: Arca.QueryHelpers.normalize_org_id(ctx_b.org_id),
            project_id: ctx_b.project_id || "default",
            timestamp: now,
            status: "success",
            duration_ms: 200
          })
      end

      # Stats for A should show 3
      stats_a =
        Arca.McpLog.stats(
          org_id: Arca.QueryHelpers.normalize_org_id(ctx_a.org_id),
          project_id: ctx_a.project_id || "default"
        )

      assert stats_a.total == 3

      # Stats for B should show 2
      stats_b =
        Arca.McpLog.stats(
          org_id: Arca.QueryHelpers.normalize_org_id(ctx_b.org_id),
          project_id: ctx_b.project_id || "default"
        )

      assert stats_b.total == 2
    end
  end

  # ============================================================================
  # API Key Tenant Isolation
  # ============================================================================

  describe "ApiKeyStorage tenant isolation" do
    test "get_key_by_hash/1 returns the key's own org (tenant binding is Context-layer, R1)" do
      key_hash = :crypto.hash(:sha256, "test_key_cross_org_#{:rand.uniform(100_000)}")

      # Create key for org_alpha
      :ok =
        Arca.ApiKeyStorage.create_key(%{
          name: "cross-org-key",
          key_hash: key_hash,
          key_prefix: "cyfr_sk_",
          type: "secret",
          scope: "[]",
          rate_limit: nil,
          ip_allowlist: nil,
          created_by: "user_a",
          scope_type: "project",
          org_id: "org_alpha"
        })

      # API keys are project credentials: the (now sole) hash lookup returns
      # the key's OWN org from the row. The former tenant-scoped
      # get_key_by_hash/3 was removed in R1 — cross-tenant rejection now
      # happens on the resulting Sanctum.Context (require_tenant!), covered by
      # Arca.R6OrgLessFailClosedTest and Sanctum.ApiKeyTest "API-key project
      # scoping".
      {:ok, row} = Arca.ApiKeyStorage.get_key_by_hash(key_hash)
      assert row.org_id == "org_alpha"
    end

    test "key's org_id flows through build_key_metadata" do
      key_hash = :crypto.hash(:sha256, "test_key_metadata_#{:rand.uniform(100_000)}")

      :ok =
        Arca.ApiKeyStorage.create_key(%{
          name: "metadata-key",
          key_hash: key_hash,
          key_prefix: "cyfr_sk_",
          type: "secret",
          scope: "[]",
          rate_limit: nil,
          ip_allowlist: nil,
          created_by: "user_a",
          scope_type: "project",
          org_id: "org_gamma"
        })

      # Verify the row returned by get_key_by_hash includes org_id
      {:ok, row} = Arca.ApiKeyStorage.get_key_by_hash(key_hash)
      assert row.org_id == "org_gamma"
    end
  end

  # ============================================================================
  # SessionStorage Tenant Isolation
  # ============================================================================

  describe "SessionStorage list_active_sessions tenant isolation" do
    test "sessions scoped to tenant" do
      hash_a = :crypto.hash(:sha256, "sess_iso_a_#{:rand.uniform(100_000)}")
      hash_b = :crypto.hash(:sha256, "sess_iso_b_#{:rand.uniform(100_000)}")

      :ok =
        Arca.SessionStorage.create_session(hash_a, %{
          user_id: "user_a",
          email: "a@test.com",
          provider: "github",
          permissions: "[]",
          session_id: Ecto.UUID.generate(),
          org_id: "org_alpha",
          project_id: "proj_1",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          token_prefix: "sess_a_"
        })

      :ok =
        Arca.SessionStorage.create_session(hash_b, %{
          user_id: "user_b",
          email: "b@test.com",
          provider: "github",
          permissions: "[]",
          session_id: Ecto.UUID.generate(),
          org_id: "org_beta",
          project_id: "proj_2",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          token_prefix: "sess_b_"
        })

      {:ok, sessions_a} =
        Arca.SessionStorage.list_active_sessions(
          org_id: "org_alpha",
          project_id: "proj_1"
        )

      assert length(sessions_a) == 1
      assert hd(sessions_a).user_id == "user_a"

      {:ok, sessions_b} =
        Arca.SessionStorage.list_active_sessions(
          org_id: "org_beta",
          project_id: "proj_2"
        )

      assert length(sessions_b) == 1
      assert hd(sessions_b).user_id == "user_b"
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp make_component_id(publisher, name, version, component_type, ctx) do
    org = Arca.QueryHelpers.normalize_org_id(ctx.org_id)
    proj = ctx.project_id || "default"

    hash =
      :crypto.hash(:sha256, "#{org}:#{proj}:#{publisher}:#{name}:#{version}:#{component_type}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "comp_#{hash}"
  end

  defp insert_stub_component(ctx, name, id) do
    now = DateTime.utc_now()

    attrs = %{
      id: id,
      name: name,
      version: "1.0.0",
      component_type: "reagent",
      description: "stub",
      tags: "[]",
      digest: "sha256:stub_#{id}",
      size: 100,
      exports: "[]",
      manifest: nil,
      publisher: "local",
      publisher_id: ctx.user_id,
      org_id: Arca.QueryHelpers.normalize_org_id(ctx.org_id),
      project_id: ctx.project_id || "default",
      source: "published",
      signature_verified: false,
      signer_identity: nil,
      signer_issuer: nil,
      inserted_at: now,
      updated_at: now
    }

    {:ok, _} = Arca.ComponentStorage.put_component(ctx, attrs)
    id
  end
end
