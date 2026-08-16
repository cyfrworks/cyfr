# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule MultiTenantIsolationTest do
  @moduledoc """
  Cross-athanor isolation smoke test.

  Every athanor on a server shares one database and one blob store. The
  architectural invariant is that every read is scoped by the caller's
  `athanor_id` — through `Arca.QueryHelpers.where_tenant/2` for rows and
  `Arca.Storage.tenant_segments/1` + `authorize_path/2` for blobs. A
  regression in any storage module that drops that filter would let one
  athanor see another's data — a confidentiality bug serious enough to
  warrant a dedicated test even though the helpers are well-covered in unit
  tests.

  This test exercises the *real* `Sanctum.Webhook` / `Sanctum.ApiKey` /
  `Sanctum.Vault` / `Arca` API with two athanor contexts and confirms that
  reads from one never return what the other created. Runs under both
  SQLite and Postgres — same code path either way.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Tenancy.Athanors

  @permissions [:execute, :storage_read, :storage_write, :vault_read, :vault_write, :admin]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {:ok, athanor_a} =
      Athanors.create(%{kind: "group", name: "Alpha", slug: "alpha", created_by: "u_a"})

    {:ok, athanor_b} =
      Athanors.create(%{kind: "group", name: "Beta", slug: "beta", created_by: "u_b"})

    # Two athanor contexts; the same namespace on both, because identity is
    # not what separates them.
    ctx_a =
      Sanctum.Context.build(
        user_id: "u_a",
        athanor_id: athanor_a.id,
        permissions: @permissions,
        scope: :athanor,
        auth_method: :oidc,
        namespace: "testns",
        authenticated: true
      )

    ctx_b =
      Sanctum.Context.build(
        user_id: "u_b",
        athanor_id: athanor_b.id,
        permissions: @permissions,
        scope: :athanor,
        auth_method: :oidc,
        namespace: "testns",
        authenticated: true
      )

    # Webhook creation validates target_ref existence athanor-scoped, so the
    # target must be registered in each athanor — and binds a consented
    # profile, seeded per athanor (the consent source partitions by athanor).
    Sanctum.Test.ComponentHelpers.register_test_component("h", "1.0.0", "formula", %{}, ctx_a)
    Sanctum.Test.ComponentHelpers.register_test_component("h", "1.0.0", "formula", %{}, ctx_b)
    Sanctum.Test.ConsentFixtures.start_source!()
    Sanctum.Test.ConsentFixtures.bindable_profile(ctx_a, "f:local.h", profile_id: "prof-h")
    Sanctum.Test.ConsentFixtures.bindable_profile(ctx_b, "f:local.h", profile_id: "prof-h")

    {:ok, a: ctx_a, b: ctx_b}
  end

  describe "Sanctum.Webhook isolation" do
    test "list/1 from athanor A does not return webhooks created in athanor B",
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

    test "get/2 from athanor A returns :not_found for athanor B's webhook",
         %{a: ctx_a, b: ctx_b} do
      {:ok, _} =
        Sanctum.Webhook.create(ctx_b, %{
          name: "private",
          target_ref: "f:local.h",
          profile_id: "prof-h"
        })

      assert {:error, :not_found} = Sanctum.Webhook.get(ctx_a, "private")
    end

    test "the same name in two athanors is allowed and the two never collide",
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

  describe "Sanctum.ApiKey isolation" do
    test "list/1 from athanor A does not return athanor B's keys", %{a: ctx_a, b: ctx_b} do
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

    test "the same key name is allowed in both athanors", %{a: ctx_a, b: ctx_b} do
      attrs = %{name: "same", type: :application, scope: []}
      assert {:ok, _} = Sanctum.ApiKey.create(ctx_a, attrs)
      assert {:ok, _} = Sanctum.ApiKey.create(ctx_b, attrs)
    end
  end

  describe "Arca.Execution isolation" do
    test "list/1 for athanor A never returns athanor B's executions",
         %{a: ctx_a, b: ctx_b} do
      common_user = "user_shared"

      {:ok, _} =
        Arca.Execution.record_start(%{
          id: "exec_t1_" <> Integer.to_string(System.unique_integer([:positive])),
          reference: "f:local.h",
          input_hash: "ih1",
          user_id: common_user,
          athanor_id: ctx_a.athanor_id,
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
          athanor_id: ctx_b.athanor_id,
          status: "running",
          component_type: "formula",
          started_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        })

      list_a = Arca.Execution.list(athanor_id: ctx_a.athanor_id)
      list_b = Arca.Execution.list(athanor_id: ctx_b.athanor_id)

      assert list_a != []
      assert list_b != []
      assert Enum.all?(list_a, &(&1.athanor_id == ctx_a.athanor_id))
      assert Enum.all?(list_b, &(&1.athanor_id == ctx_b.athanor_id))
    end

    test "list/1 without an athanor is a caller error, not a cross-athanor read" do
      assert_raise KeyError, fn -> Arca.Execution.list([]) end
    end
  end

  # Vault entries are the only credential store, so the credential-store
  # isolation smoke lives here.
  describe "Sanctum.Vault isolation" do
    test "athanor A cannot read or enumerate athanor B's vault entries", %{a: ctx_a, b: ctx_b} do
      {:ok, _} = Sanctum.Vault.create(ctx_a, %{name: "shared-name", kind: "api_key"})
      {:ok, _} = Sanctum.Vault.create(ctx_b, %{name: "shared-name", kind: "api_key"})
      {:ok, b_only} = Sanctum.Vault.create(ctx_b, %{name: "b-only", kind: "api_key"})

      {:ok, list_a} = Sanctum.Vault.list(ctx_a)
      names_a = Enum.map(list_a, & &1.name)
      assert "shared-name" in names_a
      refute "b-only" in names_a

      # Storage-level get is athanor-keyed: B's entry id is invisible
      # through A's athanor.
      assert {:error, :not_found} = Arca.VaultStorage.get(ctx_a.athanor_id, b_only.id)
      assert {:ok, _} = Arca.VaultStorage.get(ctx_b.athanor_id, b_only.id)
    end

    test "no Sanctum.Vault verb reaches another athanor's entry by id",
         %{a: ctx_a, b: ctx_b} do
      {:ok, b_entry} = Sanctum.Vault.create(ctx_b, %{name: "b-cred", kind: "api_key"})

      # The id must not resolve through any verb — read, rename, revoke,
      # rotate or delete.
      assert {:error, :not_found} = Sanctum.Vault.rename(ctx_a, b_entry.id, "stolen")
      assert {:error, :not_found} = Sanctum.Vault.revoke(ctx_a, b_entry.id)
      assert {:error, :not_found} = Sanctum.Vault.delete(ctx_a, b_entry.id)

      assert {:error, _} =
               Sanctum.Vault.rotate(ctx_a, %{
                 id: b_entry.id,
                 fields: %{"k" => "v"},
                 expected_payload_rev: 0
               })

      # And the consent walk cannot bind it: the commit-side entry fetch is
      # athanor-keyed too.
      assert {:error, :not_found} = Arca.VaultStorage.get(ctx_a.athanor_id, b_entry.id)

      # The owner athanor still sees it untouched.
      assert {:ok, row} = Arca.VaultStorage.get(ctx_b.athanor_id, b_entry.id)
      assert row.status == "active"
      assert row.name == "b-cred"
    end
  end

  describe "Arca blob isolation" do
    test "an athanor's private tree is invisible to another athanor", %{a: ctx_a, b: ctx_b} do
      :ok = Arca.put(ctx_a, ["notes", "secret.txt"], "for A only")

      assert {:ok, "for A only"} = Arca.get(ctx_a, ["notes", "secret.txt"])
      assert {:error, :not_found} = Arca.get(ctx_b, ["notes", "secret.txt"])
      refute Arca.exists?(ctx_b, ["notes", "secret.txt"])
    end

    test "the components tree is pinned per athanor: another athanor's path is forbidden",
         %{a: ctx_a, b: ctx_b} do
      path = ["components", ctx_a.athanor_id, "catalysts", "local", "tool", "1.0.0", "x.txt"]
      :ok = Arca.put(ctx_a, path, "compiled")

      assert {:ok, "compiled"} = Arca.get(ctx_a, path)
      assert {:error, :forbidden} = Arca.get(ctx_b, path)
      assert {:error, :forbidden} = Arca.put(ctx_b, path, "overwrite")
      assert {:error, :forbidden} = Arca.delete(ctx_b, path)
      refute Arca.exists?(ctx_b, path)
      assert {:ok, "compiled"} = Arca.get(ctx_a, path)
    end

    test "the seed bundle is readable only by the system", %{a: ctx_a} do
      path = ["components", "_bundle", "catalysts", "local", "seed", "1.0.0", "manifest.json"]
      assert {:error, :forbidden} = Arca.get(ctx_a, path)
      assert {:error, :forbidden} = Arca.put(ctx_a, path, "{}")
    end
  end

  # An athanor-less context must never reach a shared bucket on a WRITE
  # (insert has no query-side backstop — only the Sanctum-layer
  # require_tenant!/tenant_ok chokepoint and the NOT NULL column protect
  # it). Proven here through the *real* Sanctum API.
  describe "athanor-less write/authorize is refused (fail-closed)" do
    setup do
      # An authenticated context that has not resolved an athanor
      # (Context.build leaves athanor_id nil when none is supplied).
      {:ok,
       unresolved:
         Sanctum.Context.build(
           user_id: "u1",
           namespace: "u1",
           permissions: [:vault_read, :vault_write],
           authenticated: true
         )}
    end

    # The credential store (vault) has no in-module tenant gate: every
    # ingress that can reach Sanctum.Vault (the MCP session plug, the web
    # surface) must pass the require_tenant!/tenant_ok chokepoint first.
    # Pin both halves: the chokepoint refuses the unresolved shape, and the
    # storage layer has no fallback tenant — an athanor-less write cannot
    # land anywhere.
    test "an athanor-less context is refused at the vault ingress chokepoint",
         %{unresolved: ctx} do
      assert {:error, :missing_tenant} = Sanctum.Context.tenant_ok(ctx)

      assert_raise Sanctum.UnauthorizedError, fn ->
        Sanctum.Context.require_tenant!(ctx)
      end

      assert_raise KeyError, fn ->
        Arca.VaultStorage.put(%{
          name: "unresolved-probe",
          kind: "api_key",
          status: "active",
          sealed_payload: <<4, 2, "k1", 0>>
        })
      end

      refute match?(
               {:ok, _},
               Arca.VaultStorage.put(%{
                 athanor_id: nil,
                 name: "unresolved-probe",
                 kind: "api_key",
                 status: "active",
                 sealed_payload: <<4, 2, "k1", 0>>
               })
             )
    end

    test "Sanctum.Webhook.create raises at the chokepoint", %{unresolved: ctx} do
      assert_raise Sanctum.UnauthorizedError, fn ->
        Sanctum.Webhook.create(ctx, %{name: "wh", target_ref: "f:local.h"})
      end
    end

    test "Context.authorize rejects an athanor-less context on every shape",
         %{unresolved: ctx} do
      record = %{user_id: "someone", athanor_id: "ath_x"}

      assert {:error, _} = Sanctum.Context.authorize(ctx, :write)
      assert {:error, _} = Sanctum.Context.authorize(ctx, :read, {:owned, record})
      assert {:error, _} = Sanctum.Context.authorize(ctx, :read, {:execution, record})
    end

    test "Arca refuses an athanor-less blob path", %{unresolved: ctx} do
      assert_raise ArgumentError, fn -> Arca.put(ctx, ["notes", "x"], "y") end
    end

    test "an athanor-scoped context is still allowed", %{a: ctx} do
      assert ^ctx = Sanctum.Context.require_tenant!(ctx)

      assert {:ok, view} = Sanctum.Vault.create(ctx, %{name: "ok-entry", kind: "api_key"})
      {:ok, listed} = Sanctum.Vault.list(ctx)
      assert Enum.any?(listed, &(&1.id == view.id))
    end

    # The require_tenant! chokepoint must EXEMPT scope: :platform. System
    # tasks (retention, audit, the registry CredentialStore that backs
    # Sanctum.Namespace.lookup/1) carry no athanor by design. Without the
    # bypass the chokepoint would *raise* for every system-context op —
    # which would break Namespace.lookup → context_from_metadata → ALL
    # production MCP-plug API-key auth.
    test "a platform/system context bypasses the require_tenant! chokepoint" do
      sys = Sanctum.internal_context(permissions: [:execute])
      assert sys.scope == :platform
      assert is_nil(sys.athanor_id)

      # No raise; context returned unchanged.
      assert ^sys = Sanctum.Context.require_tenant!(sys)

      # The exact regression that broke API-key auth: Namespace.lookup
      # (CredentialStore under system context) must not raise.
      result = Sanctum.Namespace.lookup("nobody|x|y")
      assert is_nil(result) or is_binary(result)
    end
  end
end
