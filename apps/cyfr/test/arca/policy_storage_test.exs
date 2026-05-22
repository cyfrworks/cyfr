# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PolicyStorageTest do
  use ExUnit.Case, async: false

  alias Arca.PolicyStorage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()

    {:ok, ctx: ctx}
  end

  defp sample_policy(ctx, ref \\ "catalyst:local.test-widget:1.0.0") do
    now = DateTime.to_iso8601(DateTime.utc_now())

    %{
      id: Ecto.UUID.generate(),
      component_ref: ref,
      component_type: "catalyst",
      allowed_domains: "[\"example.com\"]",
      allowed_methods: "[\"GET\",\"POST\"]",
      rate_limit_requests: 50,
      rate_limit_window_seconds: 60,
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
      org_id: Arca.QueryHelpers.normalize_org_id(ctx.org_id),
      project_id: ctx.project_id || "default",
      inserted_at: now,
      updated_at: now
    }
  end

  describe "put_policy/2 and get_policy/2" do
    test "stores and retrieves a policy", %{ctx: ctx} do
      attrs = sample_policy(ctx)
      assert {:ok, _} = PolicyStorage.put_policy(ctx, attrs)

      assert {:ok, policy} = PolicyStorage.get_policy(ctx, attrs.component_ref)
      assert policy.component_ref == attrs.component_ref
      assert policy.timeout == "30s"
      assert policy.rate_limit_requests == 50
    end

    test "upserts on conflict", %{ctx: ctx} do
      attrs = sample_policy(ctx, "catalyst:local.upsert-test:1.0.0")
      {:ok, _} = PolicyStorage.put_policy(ctx, attrs)

      updated = %{
        attrs
        | timeout: "60s",
          max_memory_bytes: 134_217_728,
          updated_at: DateTime.to_iso8601(DateTime.utc_now())
      }

      {:ok, _} = PolicyStorage.put_policy(ctx, updated)

      {:ok, policy} = PolicyStorage.get_policy(ctx, attrs.component_ref)
      assert policy.timeout == "60s"
      assert policy.max_memory_bytes == 134_217_728
    end
  end

  describe "delete_policy/2" do
    test "deletes a policy", %{ctx: ctx} do
      attrs = sample_policy(ctx, "catalyst:local.delete-test:1.0.0")
      {:ok, _} = PolicyStorage.put_policy(ctx, attrs)

      assert :ok = PolicyStorage.delete_policy(ctx, attrs.component_ref)
      assert {:error, :not_found} = PolicyStorage.get_policy(ctx, attrs.component_ref)
    end

    test "succeeds for nonexistent policy", %{ctx: ctx} do
      assert :ok = PolicyStorage.delete_policy(ctx, "catalyst:local.nope:1.0.0")
    end
  end

  describe "list_policies/1" do
    test "lists all policies for tenant", %{ctx: ctx} do
      {:ok, _} = PolicyStorage.put_policy(ctx, sample_policy(ctx, "catalyst:local.list-a:1.0.0"))
      {:ok, _} = PolicyStorage.put_policy(ctx, sample_policy(ctx, "catalyst:local.list-b:1.0.0"))

      {:ok, policies} = PolicyStorage.list_policies(ctx)
      refs = Enum.map(policies, & &1.component_ref)
      assert "catalyst:local.list-a:1.0.0" in refs
      assert "catalyst:local.list-b:1.0.0" in refs
    end

    test "returns empty list when no policies exist", %{ctx: ctx} do
      {:ok, policies} = PolicyStorage.list_policies(ctx)
      assert policies == []
    end
  end

  describe "cache invalidation" do
    test "put_policy invalidates cache", %{ctx: ctx} do
      attrs = sample_policy(ctx, "catalyst:local.cache-test:1.0.0")
      {:ok, _} = PolicyStorage.put_policy(ctx, attrs)

      # Prime cache
      {:ok, _} = PolicyStorage.get_policy(ctx, attrs.component_ref)

      # Update should invalidate cache
      updated = %{attrs | timeout: "120s", updated_at: DateTime.to_iso8601(DateTime.utc_now())}
      {:ok, _} = PolicyStorage.put_policy(ctx, updated)

      {:ok, policy} = PolicyStorage.get_policy(ctx, attrs.component_ref)
      assert policy.timeout == "120s"
    end
  end

  describe "tenant isolation" do
    test "tenant A cannot see tenant B's policies", %{ctx: _ctx} do
      {ctx_a, ctx_b} = Arca.TenantTestHelper.two_contexts()

      {:ok, _} =
        PolicyStorage.put_policy(ctx_a, sample_policy(ctx_a, "catalyst:local.isolated:1.0.0"))

      assert {:ok, _} = PolicyStorage.get_policy(ctx_a, "catalyst:local.isolated:1.0.0")

      assert {:error, :not_found} =
               PolicyStorage.get_policy(ctx_b, "catalyst:local.isolated:1.0.0")
    end
  end
end
