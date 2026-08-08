# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule MultiTenantIsolationTest do
  @moduledoc """
  Cross-tenant isolation smoke test.

  In `:platform` mode, multiple orgs/projects share one database. The architectural
  invariant is that every read query is scoped via `Arca.QueryHelpers.where_tenant/2`
  (or its `where_org_id/2` + `where_project_id/2` cousins). A regression in
  any storage module that drops tenant filtering would let one tenant see
  another's rows — a confidentiality bug serious enough to warrant a
  dedicated test even though the helpers are well-covered in unit tests.

  This test exercises the *real* `Sanctum.Webhook` / `Arca.ApiKeyStorage`
  / `Sanctum.PolicyStore` API with two tenant contexts and confirms that
  reads from one context never return rows created by the other. Runs
  under both SQLite (single-user) and Postgres (multi-tenant) — same code path either way.
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
        permissions: [
          :execute,
          :storage_read,
          :storage_write,
          :secrets_read,
          :secrets_write,
          :admin
        ],
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
        permissions: [
          :execute,
          :storage_read,
          :storage_write,
          :secrets_read,
          :secrets_write,
          :admin
        ],
        scope: :project,
        auth_method: :api_key,
        namespace: "testns",
        authenticated: true
      )

    # Webhook creation validates target_ref existence tenant-scoped, so the
    # target must be registered in each tenant.
    Sanctum.Test.ComponentHelpers.register_test_component("h", "1.0.0", "formula", %{}, ctx_a)
    Sanctum.Test.ComponentHelpers.register_test_component("h", "1.0.0", "formula", %{}, ctx_b)

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

  describe "Sanctum.Secrets tenant isolation" do
    test "tenant_a cannot read or enumerate tenant_b's secrets", %{a: ctx_a, b: ctx_b} do
      :ok = Sanctum.Secrets.set(ctx_a, "SHARED_NAME", "value_a")
      :ok = Sanctum.Secrets.set(ctx_b, "SHARED_NAME", "value_b")
      :ok = Sanctum.Secrets.set(ctx_b, "B_ONLY", "secret_b")

      assert {:ok, "value_a"} = Sanctum.Secrets.get(ctx_a, "SHARED_NAME")
      assert {:error, :not_found} = Sanctum.Secrets.get(ctx_a, "B_ONLY")

      {:ok, names_a} = Sanctum.Secrets.list(ctx_a)
      refute "B_ONLY" in names_a
    end
  end

  describe "Sanctum.PolicyStore tenant isolation" do
    # put_type_default/3 has no component-registration dependency, so it
    # isolates the tenant-keying of the policies table cleanly.
    test "tenant_a cannot read tenant_b's stored type-default policy",
         %{a: ctx_a, b: ctx_b} do
      :ok =
        Sanctum.PolicyStore.put_type_default(ctx_b, :catalyst, %{
          allowed_domains: ["b-only.example"]
        })

      assert {:error, :not_found} = Sanctum.PolicyStore.get_type_default(ctx_a, :catalyst)
      assert {:ok, pol} = Sanctum.PolicyStore.get_type_default(ctx_b, :catalyst)
      assert pol.allowed_domains == ["b-only.example"]
    end
  end

  # The multi-tenant org-less collapse: an org_id-less context must never
  # reach the shared org_id="" bucket on a WRITE (insert_all has no R6
  # backstop — only the Sanctum-layer require_tenant!/require_org chokepoint
  # protects it). Proven here through the *real* Sanctum API, complementing
  # the storage-primitive-level r6_org_less_fail_closed_test.
  describe "org-less write/authorize is refused (fail-closed)" do
    setup do
      # An authenticated context that has not resolved an org — the org-less
      # shape (Context.build leaves org_id nil when none is supplied).
      {:ok,
       orgless:
         Sanctum.Context.build(
           user_id: "u1",
           namespace: "u1",
           org_id: nil,
           permissions: [:secrets_read, :secrets_write],
           authenticated: true
         )}
    end

    test "Sanctum.Secrets.set raises (S5 chokepoint)", %{orgless: ctx} do
      assert_raise Sanctum.UnauthorizedError, fn ->
        Sanctum.Secrets.set(ctx, "K", "v")
      end
    end

    test "Sanctum.PolicyStore writes raise (A5 chokepoint)", %{orgless: ctx} do
      assert_raise Sanctum.UnauthorizedError, fn ->
        Sanctum.PolicyStore.put_type_default(ctx, :catalyst, %{allowed_domains: ["x.example"]})
      end
    end

    test "Sanctum.Webhook.create raises (S5 chokepoint)", %{orgless: ctx} do
      assert_raise Sanctum.UnauthorizedError, fn ->
        Sanctum.Webhook.create(ctx, %{name: "wh", target_ref: "f:local.h"})
      end
    end

    test "Context.authorize rejects an org-less context on every shape (S4)",
         %{orgless: ctx} do
      record = %{user_id: "someone", org_id: "org_x", project_id: "p"}

      assert {:error, _} = Sanctum.Context.authorize(ctx, :write)
      assert {:error, _} = Sanctum.Context.authorize(ctx, :read, {:owned, record})
      assert {:error, _} = Sanctum.Context.authorize(ctx, :read, {:execution, record})
    end

    test "an org-scoped context is still allowed" do
      ctx = %{Sanctum.TestContext.local() | org_id: "org_pos", scope: :org}
      assert :ok = Sanctum.Secrets.set(ctx, "OK_KEY", "v")
      assert {:ok, "v"} = Sanctum.Secrets.get(ctx, "OK_KEY")
    end

    # A6: the require_tenant! chokepoint must EXEMPT scope: :platform. System
    # tasks (retention, audit, the registry CredentialStore that backs
    # Sanctum.Namespace.lookup/1) carry no org by design. Without the bypass
    # the S5 Secrets chokepoint *raises* for every system-context op in the
    # multi-tenant — which broke Namespace.lookup → context_from_metadata
    # → ALL production MCP-plug API-key auth.
    #
    # A6 is strictly "must not RAISE for platform scope". It is NOT about read
    # visibility: R6's where_org_id/2 still fail-closes an org-less *read* in
    # ext (keyed on org_id=="" , not scope) — pre-existing, intentional, and
    # orthogonal. (org-less *user* writes — scope :project — must still raise;
    # the A5/S5 invariant asserted above.)
    test "a platform/system context bypasses the require_tenant! chokepoint" do
      # Secrets now enforces its own permission gates, so the system context
      # must carry them explicitly (matching the CredentialStore precedent).
      sys = Sanctum.internal_context(permissions: [:execute, :secrets_read, :secrets_write])
      assert sys.scope == :platform

      # The core A6 invariant: no raise; context returned unchanged in ext.
      assert ^sys = Sanctum.Context.require_tenant!(sys)

      # The system Secrets path must not raise in ext (it did under S5).
      assert {:ok, _names} = Sanctum.Secrets.list(sys)
      assert :ok = Sanctum.Secrets.set(sys, "SYS_KEY", "v")

      # The exact regression that broke API-key auth: Namespace.lookup
      # (CredentialStore → Secrets.list under system_context) must not raise.
      result = Sanctum.Namespace.lookup("nobody|x|y")
      assert is_nil(result) or is_binary(result)
    end
  end

  describe "Sanctum.Permission tenant isolation (tenant-scoped by design)" do
    test "permissions set by tenant_a are not visible to tenant_b", %{a: ctx_a, b: ctx_b} do
      :ok = Sanctum.Permission.set(ctx_a, "alice", ["execute", "storage_read"])

      assert {:ok, ["execute", "storage_read"]} = Sanctum.Permission.get(ctx_a, "alice")
      assert {:ok, []} = Sanctum.Permission.get(ctx_b, "alice")

      {:ok, list_a} = Sanctum.Permission.list(ctx_a)
      {:ok, list_b} = Sanctum.Permission.list(ctx_b)
      assert Enum.any?(list_a, &(&1.subject == "alice"))
      refute Enum.any?(list_b, &(&1.subject == "alice"))
    end
  end
end
