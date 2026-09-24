# SPDX-License-Identifier: Apache-2.0
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
      athanor_id: "ath_test",
      scope: :athanor,
      permissions: permissions,
      authenticated: true
    )
  end

  describe "put/4 + fetch_for_oauth/4" do
    test "round-trips client credentials through the sealed store", %{ctx: ctx} do
      assert :ok = ProviderCredentials.put(ctx, "google", "client-abc", "secret-xyz")

      assert {:ok, %{"client_id" => "client-abc", "client_secret" => "secret-xyz"}} =
               ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "google")
    end

    test "public clients store a nil client_secret", %{ctx: ctx} do
      assert :ok = ProviderCredentials.put(ctx, "github", "public-client")

      assert {:ok, %{"client_id" => "public-client", "client_secret" => nil}} =
               ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "github")
    end

    test "put replaces existing credentials", %{ctx: ctx} do
      assert :ok = ProviderCredentials.put(ctx, "google", "old-id", "old-secret")
      assert :ok = ProviderCredentials.put(ctx, "google", "new-id", "new-secret")

      assert {:ok, %{"client_id" => "new-id", "client_secret" => "new-secret"}} =
               ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "google")
    end

    test "fetch takes tenant coordinates, never the caller's permissions", %{ctx: ctx} do
      assert :ok = ProviderCredentials.put(ctx, "google", "client-abc", "secret-xyz")

      # No Context argument exists on this path — the read is keyed by tenant
      # alone, which is exactly why an executing component's context can no
      # longer reach the client secret through a permission set.
      assert {:ok, _} = ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "google")
      assert {:error, _} = ProviderCredentials.fetch_for_oauth("ath_other", "google")
    end

    test "missing credentials produce an actionable error", %{ctx: _ctx} do
      assert {:error, message} =
               ProviderCredentials.fetch_for_oauth("ath_test", "unconfigured")

      assert message =~ "oauth.set_client"
    end
  end

  describe "permission gates" do
    test "put requires an interactive session" do
      ctx = narrow_ctx([:execute])
      assert {:error, _} = ProviderCredentials.put(ctx, "google", "id", "sec")
    end

    test "delete requires an interactive session" do
      ctx = narrow_ctx([:execute, :vault_read])
      assert {:error, _} = ProviderCredentials.delete(ctx, "google")
    end

    test "configured? requires :vault_read" do
      ctx = narrow_ctx([:execute])
      assert {:error, _} = ProviderCredentials.configured?(ctx, "google")
    end

    test "configured? reports presence", %{ctx: ctx} do
      refute ProviderCredentials.configured?(ctx, "google")
      assert :ok = ProviderCredentials.put(ctx, "google", "id", "sec")
      assert ProviderCredentials.configured?(ctx, "google")
    end
  end

  describe "the consent class" do
    # These are the athanor's OAuth *app* identity — the material
    # `vault.authorize` then spends to obtain third-party tokens. They sit on
    # the outbound side of the credential line with vault entries, not with
    # the inbound keys CYFR mints for itself, so the writes are interactive
    # and a key cannot make them however wide its permission set.
    defp key_ctx do
      Context.build(
        user_id: "svc",
        athanor_id: "ath_test",
        scope: :athanor,
        permissions: [:*],
        auth_method: :api_key,
        authenticated: true
      )
    end

    test "an API-key caller cannot substitute the OAuth client" do
      assert {:error, {:surface_not_permitted, :api_key}} =
               ProviderCredentials.put(key_ctx(), "google", "attacker-id", "attacker-secret")
    end

    test "an API-key caller cannot delete the OAuth client" do
      assert {:error, {:surface_not_permitted, :api_key}} =
               ProviderCredentials.delete(key_ctx(), "google")
    end

    test "reads stay available to a key", %{ctx: ctx} do
      assert :ok = ProviderCredentials.put(ctx, "google", "id", "sec")
      assert ProviderCredentials.configured?(key_ctx(), "google")
    end

    test "both oauth mutations are annotated interactive" do
      actions = Sanctum.Providers.OAuth.definition().annotations.actions

      assert actions["set_client"][:consent] == :interactive
      assert actions["delete_client"][:consent] == :interactive
      assert actions["list"][:consent] == nil
    end
  end

  describe "delete/2" do
    test "removes stored credentials", %{ctx: ctx} do
      assert :ok = ProviderCredentials.put(ctx, "google", "id", "sec")
      assert :ok = ProviderCredentials.delete(ctx, "google")
      refute ProviderCredentials.configured?(ctx, "google")

      assert {:error, :not_found} =
               Arca.ProviderCredentialStorage.get(Sanctum.Context.actor(ctx), "google")
    end
  end

  describe "oauth.set_client MCP action" do
    test "stores credentials via the tool surface", %{ctx: ctx} do
      assert {:ok, %{status: "ok"}} =
               Sanctum.Providers.OAuth.handle(ctx, %{
                 "action" => "set_client",
                 "provider" => "google",
                 "client_id" => "tool-id",
                 "client_secret" => "tool-secret"
               })

      assert {:ok, %{"client_id" => "tool-id"}} =
               ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "google")
    end

    test "requires provider and client_id" do
      ctx = Sanctum.TestContext.local()
      assert {:error, _} = Sanctum.Providers.OAuth.handle(ctx, %{"action" => "set_client"})
    end

    test "requires the interactive class" do
      # The tool surface refuses at the dispatch chokepoint, where the
      # action's consent annotation is enforced. A permission set — however
      # wide — does not open an outbound-credential write.
      for ctx <- [narrow_ctx([:execute]), key_ctx()] do
        assert {:error, %Prima.Refusal{stage: :admission, reason: {:consent_class_required, _}}} =
                 Grimoire.call_external("oauth", ctx, %{
                   "action" => "set_client",
                   "provider" => "google",
                   "client_id" => "x"
                 })
      end
    end
  end
end
