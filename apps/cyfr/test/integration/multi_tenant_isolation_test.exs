defmodule MultiTenantIsolationTest do
  @moduledoc """
  Cross-tenant isolation smoke test.

  In Arx mode, multiple orgs/projects share one database. The architectural
  invariant is that every read query is scoped via `Arca.QueryHelpers.where_tenant/2`
  (or its `where_org_id/2` + `where_project_id/2` cousins). A regression in
  any storage module that drops tenant filtering would let one tenant see
  another's rows — a confidentiality bug serious enough to warrant a
  dedicated test even though the helpers are well-covered in unit tests.

  This test exercises the *real* `Sanctum.Webhook` / `Arca.ApiKeyStorage`
  / `Sanctum.PolicyStore` API with two tenant contexts and confirms that
  reads from one context never return rows created by the other. Runs
  under both SQLite (Core) and Postgres (Arx) — same code path either way.
  """

  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # Two tenant contexts representing distinct (org, project) pairs.
    ctx_a =
      Sanctum.Context.build(
        user_id: "u_a",
        org_id: "org_a",
        project_id: "proj_x",
        permissions: [:execute, :storage_read, :storage_write, :admin],
        scope: :project,
        auth_method: :api_key,
        namespace: "testns",
        authenticated: true
      )

    ctx_b =
      Sanctum.Context.build(
        user_id: "u_b",
        org_id: "org_b",
        project_id: "proj_y",
        permissions: [:execute, :storage_read, :storage_write, :admin],
        scope: :project,
        auth_method: :api_key,
        namespace: "testns",
        authenticated: true
      )

    {:ok, a: ctx_a, b: ctx_b}
  end

  describe "Sanctum.Webhook tenant isolation" do
    test "list/1 from tenant_a does not return webhooks created by tenant_b",
         %{a: ctx_a, b: ctx_b} do
      {:ok, _} = Sanctum.Webhook.create(ctx_a, %{name: "hk_a", target_ref: "f:local.h"})
      {:ok, _} = Sanctum.Webhook.create(ctx_b, %{name: "hk_b", target_ref: "f:local.h"})

      {:ok, list_a} = Sanctum.Webhook.list(ctx_a)
      {:ok, list_b} = Sanctum.Webhook.list(ctx_b)

      names_a = Enum.map(list_a, & &1.name)
      names_b = Enum.map(list_b, & &1.name)

      assert "hk_a" in names_a
      refute "hk_b" in names_a

      assert "hk_b" in names_b
      refute "hk_a" in names_b
    end

    test "get/2 from tenant_a returns :not_found for tenant_b's webhook",
         %{a: ctx_a, b: ctx_b} do
      {:ok, _} = Sanctum.Webhook.create(ctx_b, %{name: "private", target_ref: "f:local.h"})

      assert {:error, :not_found} = Sanctum.Webhook.get(ctx_a, "private")
    end

    test "same name in different tenants is allowed and they don't collide",
         %{a: ctx_a, b: ctx_b} do
      assert {:ok, %{slug: slug_a}} =
               Sanctum.Webhook.create(ctx_a, %{name: "shared", target_ref: "f:local.h"})

      assert {:ok, %{slug: slug_b}} =
               Sanctum.Webhook.create(ctx_b, %{name: "shared", target_ref: "f:local.h"})

      refute slug_a == slug_b

      {:ok, hk_a} = Sanctum.Webhook.get(ctx_a, "shared")
      {:ok, hk_b} = Sanctum.Webhook.get(ctx_b, "shared")
      assert hk_a.slug == slug_a
      assert hk_b.slug == slug_b
    end
  end

  describe "Arca.ApiKeyStorage tenant isolation" do
    test "list_keys/3 from tenant_a does not return tenant_b's keys", %{a: ctx_a, b: ctx_b} do
      {:ok, _} = Sanctum.ApiKey.create(ctx_a, %{name: "key_a", type: :application, scope: []})
      {:ok, _} = Sanctum.ApiKey.create(ctx_b, %{name: "key_b", type: :application, scope: []})

      {:ok, list_a} = Sanctum.ApiKey.list(ctx_a)
      {:ok, list_b} = Sanctum.ApiKey.list(ctx_b)

      names_a = Enum.map(list_a, & &1.name)
      names_b = Enum.map(list_b, & &1.name)

      assert "key_a" in names_a
      refute "key_b" in names_a

      assert "key_b" in names_b
      refute "key_a" in names_b
    end
  end

  describe "Arca.Execution tenant isolation" do
    test "list/1 with tenant_a's org/project never returns tenant_b's executions",
         %{a: ctx_a, b: ctx_b} do
      common_user = "user_shared"

      {:ok, _} =
        Arca.Execution.record_start(%{
          id: "exec_t1_" <> Integer.to_string(System.unique_integer([:positive])),
          reference: "f:local.h",
          input_hash: "ih1",
          user_id: common_user,
          org_id: ctx_a.org_id,
          project_id: ctx_a.project_id,
          status: "running",
          component_type: "formula",
          started_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        })

      {:ok, _} =
        Arca.Execution.record_start(%{
          id: "exec_t2_" <> Integer.to_string(System.unique_integer([:positive])),
          reference: "f:local.h",
          input_hash: "ih2",
          user_id: common_user,
          org_id: ctx_b.org_id,
          project_id: ctx_b.project_id,
          status: "running",
          component_type: "formula",
          started_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        })

      list_a = Arca.Execution.list(org_id: ctx_a.org_id, project_id: ctx_a.project_id)
      list_b = Arca.Execution.list(org_id: ctx_b.org_id, project_id: ctx_b.project_id)

      assert Enum.all?(list_a, &(&1.org_id == ctx_a.org_id and &1.project_id == ctx_a.project_id))
      assert Enum.all?(list_b, &(&1.org_id == ctx_b.org_id and &1.project_id == ctx_b.project_id))
    end
  end
end
