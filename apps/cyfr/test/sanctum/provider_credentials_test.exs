# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ProviderCredentialsTest do
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.ProviderCredentials

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp narrow_ctx(permissions) do
    Context.build(
      user_id: "narrow",
      org_id: "local",
      project_id: "default",
      scope: :project,
      permissions: permissions,
      authenticated: true
    )
  end

  describe "put/4 + fetch_for_oauth/4" do
    test "round-trips client credentials through the sealed store", %{ctx: ctx} do
      assert :ok = ProviderCredentials.put(ctx, "google", "client-abc", "secret-xyz")

      assert {:ok, %{"client_id" => "client-abc", "client_secret" => "secret-xyz"}} =
               ProviderCredentials.fetch_for_oauth(ctx.org_id, ctx.project_id, "google")
    end

    test "public clients store a nil client_secret", %{ctx: ctx} do
      assert :ok = ProviderCredentials.put(ctx, "github", "public-client")

      assert {:ok, %{"client_id" => "public-client", "client_secret" => nil}} =
               ProviderCredentials.fetch_for_oauth(ctx.org_id, ctx.project_id, "github")
    end

    test "put replaces existing credentials", %{ctx: ctx} do
      assert :ok = ProviderCredentials.put(ctx, "google", "old-id", "old-secret")
      assert :ok = ProviderCredentials.put(ctx, "google", "new-id", "new-secret")

      assert {:ok, %{"client_id" => "new-id", "client_secret" => "new-secret"}} =
               ProviderCredentials.fetch_for_oauth(ctx.org_id, ctx.project_id, "google")
    end

    test "fetch takes tenant coordinates, never the caller's permissions", %{ctx: ctx} do
      assert :ok = ProviderCredentials.put(ctx, "google", "client-abc", "secret-xyz")

      # No Context argument exists on this path — the read is keyed by tenant
      # alone, which is exactly why an executing component's context can no
      # longer reach the client secret through a permission set.
      assert {:ok, _} = ProviderCredentials.fetch_for_oauth("local", "default", "google")
      assert {:error, _} = ProviderCredentials.fetch_for_oauth("other_org", "default", "google")
    end

    test "missing credentials produce an actionable error", %{ctx: _ctx} do
      assert {:error, message} =
               ProviderCredentials.fetch_for_oauth("local", "default", "unconfigured")

      assert message =~ "oauth.set_client"
    end
  end

  describe "permission gates" do
    test "put requires :secrets_write" do
      ctx = narrow_ctx([:execute])
      assert {:error, _} = ProviderCredentials.put(ctx, "google", "id", "sec")
    end

    test "delete requires :secrets_write" do
      ctx = narrow_ctx([:execute, :secrets_read])
      assert {:error, _} = ProviderCredentials.delete(ctx, "google")
    end

    test "configured? requires :secrets_read" do
      ctx = narrow_ctx([:execute])
      assert {:error, _} = ProviderCredentials.configured?(ctx, "google")
    end

    test "configured? reports presence", %{ctx: ctx} do
      refute ProviderCredentials.configured?(ctx, "google")
      assert :ok = ProviderCredentials.put(ctx, "google", "id", "sec")
      assert ProviderCredentials.configured?(ctx, "google")
    end
  end

  describe "delete/2" do
    test "removes stored credentials", %{ctx: ctx} do
      assert :ok = ProviderCredentials.put(ctx, "google", "id", "sec")
      assert :ok = ProviderCredentials.delete(ctx, "google")
      refute ProviderCredentials.configured?(ctx, "google")

      assert {:error, :not_found} =
               Arca.ProviderCredentialStorage.get("local", "default", "google")
    end
  end

  describe "legacy secret fallback" do
    test "reads manifest-named secrets and copies them forward", %{ctx: ctx} do
      :ok = Sanctum.Secrets.set(ctx, "LEGACY_CLIENT_ID", "legacy-id")
      :ok = Sanctum.Secrets.set(ctx, "LEGACY_CLIENT_SECRET", "legacy-secret")

      assert {:ok, %{"client_id" => "legacy-id", "client_secret" => "legacy-secret"}} =
               ProviderCredentials.fetch_for_oauth(
                 "local",
                 "default",
                 "legacyprov",
                 {"LEGACY_CLIENT_ID", "LEGACY_CLIENT_SECRET"}
               )

      # Copied forward: a second fetch with no legacy hint hits the store
      assert {:ok, %{"client_id" => "legacy-id"}} =
               ProviderCredentials.fetch_for_oauth("local", "default", "legacyprov")
    end

    test "legacy client_secret is optional", %{ctx: ctx} do
      :ok = Sanctum.Secrets.set(ctx, "PUBONLY_CLIENT_ID", "pub-id")

      assert {:ok, %{"client_id" => "pub-id", "client_secret" => nil}} =
               ProviderCredentials.fetch_for_oauth(
                 "local",
                 "default",
                 "pubonly",
                 {"PUBONLY_CLIENT_ID", "PUBONLY_CLIENT_SECRET"}
               )
    end

    test "no legacy names means no fallback" do
      assert {:error, _} =
               ProviderCredentials.fetch_for_oauth("local", "default", "nolegacy", nil)
    end
  end

  describe "oauth.set_client MCP action" do
    test "stores credentials via the tool surface", %{ctx: ctx} do
      assert {:ok, %{status: "ok"}} =
               Sanctum.MCP.OAuthTool.handle(ctx, %{
                 "action" => "set_client",
                 "provider" => "google",
                 "client_id" => "tool-id",
                 "client_secret" => "tool-secret"
               })

      assert {:ok, %{"client_id" => "tool-id"}} =
               ProviderCredentials.fetch_for_oauth("local", "default", "google")
    end

    test "requires provider and client_id" do
      ctx = Sanctum.TestContext.local()
      assert {:error, _} = Sanctum.MCP.OAuthTool.handle(ctx, %{"action" => "set_client"})
    end

    test "requires :secrets_write" do
      ctx = narrow_ctx([:execute])

      assert {:error, _} =
               Sanctum.MCP.OAuthTool.handle(ctx, %{
                 "action" => "set_client",
                 "provider" => "google",
                 "client_id" => "x"
               })
    end
  end
end
