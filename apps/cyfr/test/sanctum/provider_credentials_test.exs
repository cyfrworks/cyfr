# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ProviderCredentialsTest do
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.ProviderCredentials
  alias Sanctum.Test.DirectoryServer

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

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

  # A person with their own athanor, and the context their session
  # establishes there.
  defp signed_in! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|oauth-client-#{n}",
        provider: "github",
        email: "oauth-client#{n}@example.com",
        verified: true
      })

    athanor = Sanctum.Test.People.athanor!(user)

    built =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "github",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(built)
    {:ok, ctx} = Sanctum.Caller.establish(session.token, focus: athanor.id, refresh: false)
    ctx
  end

  # The sources of the statements this process ran, as the handler told it.
  defp ran do
    receive do
      {:statement, source} -> [source | ran()]
    after
      0 -> []
    end
  end

  describe "put/4 + fetch_for_oauth/4" do
    test "round-trips client credentials through the sealed store", %{ctx: ctx} do
      assert :ok =
               Sanctum.TestContext.put_provider_credentials(
                 ctx,
                 "google",
                 "client-abc",
                 "secret-xyz"
               )

      assert {:ok, %{"client_id" => "client-abc", "client_secret" => "secret-xyz"}} =
               ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "google")
    end

    test "public clients store a nil client_secret", %{ctx: ctx} do
      assert :ok = Sanctum.TestContext.put_provider_credentials(ctx, "github", "public-client")

      assert {:ok, %{"client_id" => "public-client", "client_secret" => nil}} =
               ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "github")
    end

    test "put replaces existing credentials", %{ctx: ctx} do
      assert :ok =
               Sanctum.TestContext.put_provider_credentials(ctx, "google", "old-id", "old-secret")

      assert :ok =
               Sanctum.TestContext.put_provider_credentials(ctx, "google", "new-id", "new-secret")

      assert {:ok, %{"client_id" => "new-id", "client_secret" => "new-secret"}} =
               ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "google")
    end

    test "a context that is no paired device's takes no device hold, and stores",
         %{ctx: ctx} do
      confirmed =
        Sanctum.TestContext.confirmed_change(
          ctx,
          "oauth.set_client",
          %{provider: "google", client_id: "session-id", client_secret: "session-secret"},
          "google"
        )

      test = self()
      handler = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler,
          [:arca, :repo, :query],
          fn _, _, meta, _ -> if self() == test, do: send(test, {:statement, meta[:source]}) end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      answer = ProviderCredentials.put(confirmed, "google", "session-id", "session-secret")
      :telemetry.detach(handler)

      assert answer == :ok
      sources = ran()
      refute "paired_clients" in sources
      refute "device_certificates" in sources

      assert {:ok, %{"client_id" => "session-id"}} =
               ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "google")
    end

    test "fetch takes tenant coordinates, never the caller's permissions", %{ctx: ctx} do
      assert :ok =
               Sanctum.TestContext.put_provider_credentials(
                 ctx,
                 "google",
                 "client-abc",
                 "secret-xyz"
               )

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
      assert :ok = Sanctum.TestContext.put_provider_credentials(ctx, "google", "id", "sec")
      assert {:ok, [%{provider: "google"}]} = ProviderCredentials.list(key_ctx())
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
      assert :ok = Sanctum.TestContext.put_provider_credentials(ctx, "google", "id", "sec")
      assert :ok = ProviderCredentials.delete(ctx, "google")

      assert {:error, :not_found} =
               Arca.ProviderCredentialStorage.get(Sanctum.Context.actor(ctx), "google")
    end
  end

  describe "oauth.set_client MCP action" do
    test "stores credentials via the tool surface", %{ctx: ctx} do
      confirmed =
        Sanctum.TestContext.confirmed_change(
          ctx,
          "oauth.set_client",
          %{provider: "google", client_id: "tool-id", client_secret: "tool-secret"},
          "google"
        )

      assert {:ok, %{status: "ok"}} =
               Sanctum.Providers.OAuth.handle(confirmed, %{
                 "action" => "set_client",
                 "provider" => "google",
                 "client_id" => "tool-id",
                 "client_secret" => "tool-secret"
               })

      assert {:ok, %{"client_id" => "tool-id"}} =
               ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "google")
    end

    test "a client configuration refused for ownership answers the ownership refusal and stores nothing",
         %{ctx: ctx} do
      confirmed =
        Sanctum.TestContext.confirmed_change(
          ctx,
          "oauth.set_client",
          %{provider: "google", client_id: "unowned-id", client_secret: "unowned-secret"},
          "google"
        )

      on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)
      Arca.ControlPlane.record(:lost)

      assert {:error, :not_owner} =
               Sanctum.Providers.OAuth.handle(confirmed, %{
                 "action" => "set_client",
                 "provider" => "google",
                 "client_id" => "unowned-id",
                 "client_secret" => "unowned-secret"
               })

      Arca.ControlPlane.record(:unclaimed)
      assert {:error, _missing} = ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "google")
    end

    test "by a person whose account was closed answers the closed-account refusal, and stores nothing" do
      ctx = signed_in!()

      set_client =
        &Sanctum.Providers.OAuth.handle(&1, %{
          "action" => "set_client",
          "provider" => "google",
          "client_id" => "closed-id",
          "client_secret" => "closed-secret"
        })

      assert DirectoryServer.repeated_once_closed(ctx, set_client) == {:error, :identity_gone}

      assert {:error, :not_found} =
               Arca.ProviderCredentialStorage.get(Context.actor(ctx), "google")
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
                 Sanctum.Gate.call_external("oauth", ctx, %{
                   "action" => "set_client",
                   "provider" => "google",
                   "client_id" => "x"
                 })
      end
    end
  end
end
