# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.S1TenantScopeSSOTTest do
  @moduledoc """
  Webhook + ApiKey derive their athanor through the single tenant gate
  (`Sanctum.Context.require_tenant!/1` → `Sanctum.TenantPolicy`), and the
  storage layer scopes every query through `Arca.QueryHelpers.where_tenant/2`.

  Equivalence: normal-context behaviour is unchanged. Gap-closure: an
  athanor-less (pre-resolution) context must be refused, never silently
  scoped to some default bucket — there is none.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 1]

  alias Sanctum.{ApiKey, Context, Webhook}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx =
      Context.build(
        user_id: "u",
        namespace: "ns",
        athanor_id: "ath_acme",
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    # An authenticated context that has not resolved an athanor yet (the
    # transient pre-resolution auth state) — the shape the tenant gate exists
    # to refuse.
    unresolved =
      Context.build(
        user_id: "u-unresolved",
        namespace: "ns",
        athanor_id: nil,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, ctx: ctx, unresolved: unresolved}
  end

  describe "equivalence — normal context behaviour unchanged" do
    test "ApiKey create/get/list still work and are tenant-scoped", %{ctx: ctx} do
      {:ok, %{name: "k1"}} = ApiKey.create(ctx, %{name: "k1"})
      assert {:ok, _} = ApiKey.get(ctx, "k1")
      {:ok, list} = ApiKey.list(ctx)
      assert Enum.any?(list, &(&1.name == "k1"))
    end

    test "Webhook create/get/list still work", %{ctx: ctx} do
      Sanctum.Test.ComponentHelpers.register_test_component("h", "1.0.0", "formula", %{}, ctx)
      Sanctum.Test.ConsentFixtures.start_source!()
      profile = Sanctum.Test.ConsentFixtures.bindable_profile(ctx, "f:local.h")

      {:ok, %{name: "h1"}} =
        Webhook.create(ctx, %{name: "h1", target_ref: "f:local.h", profile_id: profile})

      assert {:ok, _} = Webhook.get(ctx, "h1")
      {:ok, list} = Webhook.list(ctx)
      assert Enum.any?(list, &(&1.name == "h1"))
    end
  end

  describe "ApiKey create/2 tenant gate" do
    test "athanor-less context → {:error, :athanor_required}", %{unresolved: ctx} do
      assert ApiKey.create(ctx, %{name: "nope"}) == {:error, :athanor_required}
    end
  end

  describe "ApiKey read/mutate paths enforce the tenant chokepoint" do
    test "get/list/revoke/rotate raise for an athanor-less context", %{unresolved: ctx} do
      assert_raise Sanctum.UnauthorizedError, fn -> ApiKey.get(ctx, "x") end
      assert_raise Sanctum.UnauthorizedError, fn -> ApiKey.list(ctx) end
      assert_raise Sanctum.UnauthorizedError, fn -> ApiKey.revoke(ctx, "x") end
      assert_raise Sanctum.UnauthorizedError, fn -> ApiKey.rotate(ctx, "x") end
    end

    test "a resolved context still works", %{ctx: ctx} do
      {:ok, _} = ApiKey.create(ctx, %{name: "ok"})
      assert {:ok, _} = ApiKey.get(ctx, "ok")
      assert {:ok, _} = ApiKey.list(ctx)
    end
  end

  describe "Webhook tenant chokepoint" do
    test "athanor-less context is refused", %{unresolved: ctx} do
      assert_raise Sanctum.UnauthorizedError, fn -> Webhook.list(ctx) end
      assert_raise Sanctum.UnauthorizedError, fn -> Webhook.get(ctx, "x") end
    end
  end

  describe "the storage backstops agree with the gate" do
    test "where_tenant/2 scopes by the context's athanor and raises when unresolved",
         %{ctx: ctx, unresolved: unresolved} do
      base = from(k in Arca.Schemas.ApiKey)

      scoped = Arca.QueryHelpers.where_tenant(base, ctx)
      assert inspect(scoped) =~ "athanor_id == ^\"ath_acme\""

      assert_raise ArgumentError, fn -> Arca.QueryHelpers.where_tenant(base, unresolved) end
    end

    test "tenant_segments/1 is the same athanor, and refuses the unresolved context",
         %{ctx: ctx, unresolved: unresolved} do
      assert Arca.Storage.tenant_segments(ctx) == ["ath_acme"]
      assert_raise ArgumentError, fn -> Arca.Storage.tenant_segments(unresolved) end
    end

    test "TenantPolicy is the gate both paths delegate to", %{unresolved: unresolved} do
      assert {:error, :missing_tenant} = Sanctum.TenantPolicy.require_athanor(unresolved)
      assert {:error, :missing_tenant} = Sanctum.Context.tenant_ok(unresolved)
    end
  end
end
