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
  / `Sanctum.Vault` API with two tenant contexts and confirms that
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
          :vault_read,
          :vault_write,
          :admin
        ],
        scope: :project,
        auth_method: :oidc,
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
          :vault_read,
          :vault_write,
          :admin
        ],
        scope: :project,
        auth_method: :oidc,
        namespace: "testns",
        authenticated: true
      )

    # Webhook creation validates target_ref existence tenant-scoped, so the
    # target must be registered in each tenant — and binds a consented
    # profile, seeded per tenant (the consent source partitions by tenant).
    Sanctum.Test.ComponentHelpers.register_test_component("h", "1.0.0", "formula", %{}, ctx_a)
    Sanctum.Test.ComponentHelpers.register_test_component("h", "1.0.0", "formula", %{}, ctx_b)
    Sanctum.Test.ConsentFixtures.start_source!()
    Sanctum.Test.ConsentFixtures.bindable_profile(ctx_a, "f:local.h", profile_id: "prof-h")
    Sanctum.Test.ConsentFixtures.bindable_profile(ctx_b, "f:local.h", profile_id: "prof-h")

    {:ok, a: ctx_a, b: ctx_b}
  end

  describe "Sanctum.Webhook tenant isolation" do
    test "list/1 from tenant_a does not return webhooks created by tenant_b",
         %{a: ctx_a, b: ctx_b} do
      {:ok, _} =
        Sanctum.Webhook.create(ctx_a, %{
          name: "hk_a",
          target_ref: "f:local.h",
          profile_id: "prof-h"
        })

      {:ok, _} =
        Sanctum.Webhook.create(ctx_b, %{
          name: "hk_b",
          target_ref: "f:local.h",
          profile_id: "prof-h"
        })

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
      {:ok, _} =
        Sanctum.Webhook.create(ctx_b, %{
          name: "private",
          target_ref: "f:local.h",
          profile_id: "prof-h"
        })

      assert {:error, :not_found} = Sanctum.Webhook.get(ctx_a, "private")
    end

    test "same name in different tenants is allowed and they don't collide",
         %{a: ctx_a, b: ctx_b} do
      assert {:ok, %{slug: slug_a}} =
               Sanctum.Webhook.create(ctx_a, %{
                 name: "shared",
                 target_ref: "f:local.h",
                 profile_id: "prof-h"
               })

      assert {:ok, %{slug: slug_b}} =
               Sanctum.Webhook.create(ctx_b, %{
                 name: "shared",
                 target_ref: "f:local.h",
                 profile_id: "prof-h"
               })

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

  # The legacy Sanctum.Secrets plane retired; vault entries are the only
  # credential store, so the credential-store isolation smoke lives there now.
  describe "Sanctum.Vault tenant isolation" do
    test "tenant_a cannot read or enumerate tenant_b's vault entries", %{a: ctx_a, b: ctx_b} do
      {:ok, _} = Sanctum.Vault.create(ctx_a, %{name: "shared-name", kind: "api_key"})
      {:ok, _} = Sanctum.Vault.create(ctx_b, %{name: "shared-name", kind: "api_key"})
      {:ok, b_only} = Sanctum.Vault.create(ctx_b, %{name: "b-only", kind: "api_key"})

      {:ok, list_a} = Sanctum.Vault.list(ctx_a)
      names_a = Enum.map(list_a, & &1.name)
      assert "shared-name" in names_a
      refute "b-only" in names_a

      # Storage-level get is org-scoped: tenant_b's entry id is invisible
      # through tenant_a's org.
      assert {:error, :not_found} = Arca.VaultStorage.get(ctx_a.org_id, ctx_a.project_id, b_only.id)
      assert {:ok, _} = Arca.VaultStorage.get(ctx_b.org_id, ctx_b.project_id, b_only.id)
    end

    test "a project-scoped caller cannot reach a sibling project's entry by id",
         %{a: ctx_a} do
      ctx_p2 = %{ctx_a | project_id: "sibling"}
      {:ok, p2_entry} = Sanctum.Vault.create(ctx_p2, %{name: "p2-cred", kind: "api_key"})

      # Same org, different project: the id must not resolve through any
      # Sanctum.Vault verb — read, rename, revoke, rotate or delete.
      assert {:error, :not_found} = Sanctum.Vault.rename(ctx_a, p2_entry.id, "stolen")
      assert {:error, :not_found} = Sanctum.Vault.revoke(ctx_a, p2_entry.id)
      assert {:error, :not_found} = Sanctum.Vault.delete(ctx_a, p2_entry.id)

      assert {:error, _} =
               Sanctum.Vault.rotate(ctx_a, %{
                 id: p2_entry.id,
                 fields: %{"k" => "v"},
                 expected_payload_rev: 0
               })

      # And the consent walk cannot bind it: the commit-side entry fetch is
      # project-scoped too.
      assert {:error, :not_found} =
               Arca.VaultStorage.get(ctx_a.org_id, ctx_a.project_id, p2_entry.id)

      # The owner project still sees it untouched.
      assert {:ok, row} = Arca.VaultStorage.get(ctx_p2.org_id, "sibling", p2_entry.id)
      assert row.status == "active"
      assert row.name == "p2-cred"
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
           permissions: [:vault_read, :vault_write],
           authenticated: true
         )}
    end

    # The credential store (vault) has no in-module tenant gate: every
    # ingress that can reach Sanctum.Vault (the MCP session plug, the web
    # surface) must pass the require_tenant!/tenant_ok chokepoint first.
    # Pin both halves: the chokepoint refuses the org-less shape, and the
    # storage backstop canonicalizes a nil org to the seeded "local"
    # sentinel — an org-less write can never land in a shared org_id == ""
    # bucket (the historic collapse bug).
    test "an org-less context is refused at the vault ingress chokepoint", %{orgless: ctx} do
      assert {:error, :missing_tenant} = Sanctum.Context.tenant_ok(ctx)

      assert_raise Sanctum.UnauthorizedError, fn ->
        Sanctum.Context.require_tenant!(ctx)
      end

      {:ok, entry} =
        Arca.VaultStorage.put(%{
          org_id: nil,
          project_id: nil,
          name: "orgless-probe",
          kind: "api_key",
          status: "active",
          sealed_payload: <<3, 2, "k1", 0>>
        })

      assert entry.org_id == Arca.Tenant.local_org()
      refute entry.org_id == ""
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
      assert ^ctx = Sanctum.Context.require_tenant!(ctx)

      assert {:ok, view} = Sanctum.Vault.create(ctx, %{name: "ok-entry", kind: "api_key"})
      {:ok, listed} = Sanctum.Vault.list(ctx)
      assert Enum.any?(listed, &(&1.id == view.id))
    end

    # A6: the require_tenant! chokepoint must EXEMPT scope: :platform. System
    # tasks (retention, audit, the registry CredentialStore that backs
    # Sanctum.Namespace.lookup/1) carry no org by design. Without the bypass
    # the chokepoint *raises* for every system-context op in the
    # multi-tenant — which broke Namespace.lookup → context_from_metadata
    # → ALL production MCP-plug API-key auth.
    #
    # A6 is strictly "must not RAISE for platform scope". (org-less *user*
    # writes — scope :project — must still be refused; the A5 invariant
    # asserted above.)
    test "a platform/system context bypasses the require_tenant! chokepoint" do
      sys = Sanctum.internal_context(permissions: [:execute])
      assert sys.scope == :platform

      # The core A6 invariant: no raise; context returned unchanged.
      assert ^sys = Sanctum.Context.require_tenant!(sys)

      # A system-context read of the living credential store must not raise
      # (the org-less org normalizes to the local sentinel at storage).
      assert {:ok, _entries} = Sanctum.Vault.list(sys)

      # The exact regression that broke API-key auth: Namespace.lookup
      # (CredentialStore under system context) must not raise.
      result = Sanctum.Namespace.lookup("nobody|x|y")
      assert is_nil(result) or is_binary(result)
    end
  end
end
