# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.S1TenantScopeSSOTTest do
  @moduledoc """
  Phase 2 S1: Webhook + ApiKey derive {scope, org_id, project_id} via the
  single `Sanctum.TenantScope` chokepoint (as Secrets/OAuth already do).

  Equivalence: normal-context behaviour is unchanged. Gap-closure: ApiKey
  get/list/revoke/rotate previously skipped the tenant gate — an org-less
  (pre-resolution) context must be refused, not silently scoped to the
  "" sentinel bucket.
  """
  use ExUnit.Case, async: false

  alias Sanctum.{ApiKey, Context, Webhook}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    org_ctx =
      Context.build(
        user_id: "u",
        namespace: "ns",
        org_id: "acme",
        project_id: "default",
        permissions: [:*],
        scope: :project,
        auth_method: :oidc,
        authenticated: true
      )

    # An authenticated context that has not resolved an org yet (the transient
    # pre-resolution auth state) — the shape the tenant gate exists to refuse.
    orgless =
      Context.build(
        user_id: "u-unresolved",
        namespace: "ns",
        org_id: nil,
        permissions: [:*],
        scope: :project,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, org_ctx: org_ctx, orgless: orgless}
  end

  describe "equivalence — normal context behaviour unchanged" do
    test "ApiKey create/get/list still work and are tenant-scoped", %{org_ctx: ctx} do
      {:ok, %{name: "k1"}} = ApiKey.create(ctx, %{name: "k1"})
      assert {:ok, _} = ApiKey.get(ctx, "k1")
      {:ok, list} = ApiKey.list(ctx)
      assert Enum.any?(list, &(&1.name == "k1"))
    end

    test "Webhook create/get/list still work", %{org_ctx: ctx} do
      Sanctum.Test.ComponentHelpers.register_test_component("h", "1.0.0", "formula", %{}, ctx)

      {:ok, %{name: "h1"}} = Webhook.create(ctx, %{name: "h1", target_ref: "f:local.h"})
      assert {:ok, _} = Webhook.get(ctx, "h1")
      {:ok, list} = Webhook.list(ctx)
      assert Enum.any?(list, &(&1.name == "h1"))
    end
  end

  describe "ApiKey create/2 tenant gate (unchanged contract)" do
    test "org-less context → {:error, :org_id_required}", %{orgless: ctx} do
      assert ApiKey.create(ctx, %{name: "nope"}) == {:error, :org_id_required}
    end
  end

  describe "ApiKey read/mutate paths now enforce the tenant chokepoint (gap-closure)" do
    test "get/list/revoke/rotate raise for an org-less context", %{orgless: ctx} do
      assert_raise Sanctum.UnauthorizedError, fn -> ApiKey.get(ctx, "x") end
      assert_raise Sanctum.UnauthorizedError, fn -> ApiKey.list(ctx) end
      assert_raise Sanctum.UnauthorizedError, fn -> ApiKey.revoke(ctx, "x") end
      assert_raise Sanctum.UnauthorizedError, fn -> ApiKey.rotate(ctx, "x") end
    end

    test "a resolved-org context still works", %{org_ctx: ctx} do
      {:ok, _} = ApiKey.create(ctx, %{name: "ok"})
      assert {:ok, _} = ApiKey.get(ctx, "ok")
      assert {:ok, _} = ApiKey.list(ctx)
    end
  end

  describe "Webhook tenant chokepoint (was already correct — pin it)" do
    test "org-less context is refused", %{orgless: ctx} do
      assert_raise Sanctum.UnauthorizedError, fn -> Webhook.list(ctx) end
      assert_raise Sanctum.UnauthorizedError, fn -> Webhook.get(ctx, "x") end
    end
  end
end
