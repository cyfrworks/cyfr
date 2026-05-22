# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.OAuthCharacterizationTest do
  @moduledoc """
  Behaviour-preserving net for the `Sanctum.OAuth` decomposition (Phase 3 #8).

  The pre-existing `oauth_test.exs` (R2 guards) covers only single-use state
  and the PKCE math. This pins the deterministic, fixture-free public-API
  contract the split must preserve: the tenant chokepoint (org-less ⇒ raise
  via `Sanctum.TenantScope`), the manifest-missing error paths, and the
  no-token result shapes.
  """
  use ExUnit.Case, async: false


  alias Sanctum.Context
  alias Sanctum.OAuth

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

    {:ok, org_ctx: org_ctx, orgless: Sanctum.TestContext.local()}
  end

  describe "tenant chokepoint (extract_scope → TenantScope) under strict policy" do
    test "get_access_token/3 raises for an org-less context", %{orgless: ctx} do
      (fn ->         assert_raise Sanctum.UnauthorizedError, fn ->
          OAuth.get_access_token(ctx, "catalyst:local.x", "github")
        end
      end)
    end

    test "revoke/3 raises for an org-less context", %{orgless: ctx} do
      (fn ->         assert_raise Sanctum.UnauthorizedError, fn ->
          OAuth.revoke(ctx, "catalyst:local.x", "github")
        end
      end)
    end

    test "a resolved-org context passes the gate (get_access_token → no token)",
         %{org_ctx: ctx} do
      (fn ->         assert {:error, msg} = OAuth.get_access_token(ctx, "catalyst:local.x", "github")
        assert msg =~ "authorization_required"
      end)
    end
  end

  describe "deterministic API contract (no fixtures)" do
    test "get_access_token/3 with no stored token → authorization_required", %{org_ctx: ctx} do
      assert {:error, msg} = OAuth.get_access_token(ctx, "catalyst:local.nope", "github")
      assert msg =~ "authorization_required"
      assert msg =~ "catalyst:local.nope"
    end

    test "revoke/3 is idempotent when nothing is stored", %{org_ctx: ctx} do
      assert OAuth.revoke(ctx, "catalyst:local.nope", "github") == :ok
    end

    test "authorize_url/3 for an unknown component → {:error, _}", %{org_ctx: ctx} do
      assert {:error, _reason} = OAuth.authorize_url(ctx, "catalyst:local.unknown", "github")
    end

    test "status/2 for an unknown component → {:error, _}", %{org_ctx: ctx} do
      assert {:error, _reason} = OAuth.status(ctx, "catalyst:local.unknown")
    end

    test "exchange_code/3 with an unknown state is rejected" do
      assert {:error, "invalid or expired state parameter"} =
               OAuth.exchange_code("no-such-state-#{System.unique_integer()}", "code", "uri")
    end
  end
end
