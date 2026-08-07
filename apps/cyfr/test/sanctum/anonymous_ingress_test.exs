# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.AnonymousIngressTest do
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.Secrets

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp anonymous_exec_ctx do
    # Exactly what a public tincture invocation mints
    Sanctum.build_tincture_context(
      Context.build(authenticated: false, scope: :project),
      %{publisher: "alice", name: "widget"}
    )
  end

  describe "credential plane denies anonymous contexts" do
    test "by-name secret reads and writes are denied" do
      anon = anonymous_exec_ctx()

      assert {:error, :anonymous_denied} = Secrets.get(anon, "ANY")
      assert {:error, :anonymous_denied} = Secrets.list(anon)
      assert {:error, :anonymous_denied} = Secrets.set(anon, "ANY", "v")
      assert {:error, :anonymous_denied} = Secrets.delete(anon, "ANY")
      assert {:error, :anonymous_denied} = Secrets.grant(anon, "ANY", "c:local.x:1.0.0")
      assert {:error, :anonymous_denied} = Secrets.list_grants(anon, "ANY")
    end

    test "a secret-less component still resolves an empty map anonymously" do
      anon = anonymous_exec_ctx()

      assert {:ok, %{secrets: %{}}} =
               Secrets.resolve_granted_secrets(anon, "catalyst:local.no-secrets:1.0.0")
    end

    test "a granted component fails loudly at preload instead of leaking", %{ctx: ctx} do
      :ok = Secrets.set(ctx, "PUBLIC_LEAK", "sensitive")
      :ok = Secrets.grant(ctx, "PUBLIC_LEAK", "catalyst:local.granted-cat:1.0.0")

      anon = anonymous_exec_ctx()

      assert {:error, message} =
               Secrets.resolve_granted_secrets(anon, "catalyst:local.granted-cat:1.0.0")

      assert message =~ "anonymous_denied"
    end

    test "delegated OAuth tokens are never dispensed anonymously" do
      anon = anonymous_exec_ctx()

      assert {:error, message} =
               Sanctum.OAuth.get_access_token(anon, "catalyst:local.gmailish", "google")

      assert message =~ "authorization_required"
      assert message =~ "public invocations"
    end

    test "an authenticated invoker's tincture context is not anonymous", %{ctx: ctx} do
      invoked = Sanctum.build_tincture_context(ctx, %{publisher: "alice", name: "widget"})

      refute invoked.anonymous
      # Carries the invoker's own permissions, so their granted reads work
      :ok = Secrets.set(ctx, "OWNER_SECRET", "v")
      assert {:ok, "v"} = Secrets.get(invoked, "OWNER_SECRET")
    end
  end

  describe "Tenancy.user_active_in_org?/2" do
    test "true for any owner when no auth provider is configured" do
      assert Sanctum.Tenancy.user_active_in_org?("anyone", "any_org")
      assert Sanctum.Tenancy.user_active_in_org?(nil, "any_org")
    end

    test "membership-checked when an auth provider is configured" do
      Application.put_env(:cyfr, :auth_provider, Sanctum.Auth.OIDC)
      on_exit(fn -> Application.delete_env(:cyfr, :auth_provider) end)

      # Orphaned or missing owners are inactive
      refute Sanctum.Tenancy.user_active_in_org?(nil, "org_x")
      refute Sanctum.Tenancy.user_active_in_org?("", "org_x")
      refute Sanctum.Tenancy.user_active_in_org?("departed-user", "org_x")

      # An org membership grants its org, not others
      {:ok, _} = Sanctum.Tenancy.Orgs.create(%{id: "org_x", name: "Org X", slug: "org-x"})

      {:ok, _} =
        Sanctum.Tenancy.Memberships.ensure("member-user", scope: "org", org_id: "org_x")

      assert Sanctum.Tenancy.user_active_in_org?("member-user", "org_x")
      refute Sanctum.Tenancy.user_active_in_org?("member-user", "org_other")

      # A platform membership grants every org
      {:ok, _} = Sanctum.Tenancy.Memberships.ensure("admin-user", scope: "platform")
      assert Sanctum.Tenancy.user_active_in_org?("admin-user", "org_x")
      assert Sanctum.Tenancy.user_active_in_org?("admin-user", "org_other")
    end
  end
end
