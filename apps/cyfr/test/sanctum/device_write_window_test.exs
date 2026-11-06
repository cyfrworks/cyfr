# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DeviceWriteWindowTest do
  @moduledoc """
  A sensitive change a paired device asks for is written while the device
  is held: a revocation that commits after the device's standing was read
  and before the write refuses it, and nothing is written.

  A credential written in its own transaction after its confirmation was
  consumed (a webhook, a vault entry an OAuth grant writes, an OAuth
  provider's client credentials) holds the device's client and
  certificate in that transaction (`Sanctum.Issuance.device_hold/1`); the
  revocation commits between the confirmation and the write. A change
  whose confirmation is consumed in its write's own transaction is held
  there by the consumption (`Sanctum.Consent.Authz.consume/2`); the
  revocation lands inside that transaction, right after the device's
  standing was read there. Each change still completes while the device
  stands.

  These need what only this suite has: the component domain a webhook's
  target is checked in. A grant's token endpoint is a scripted
  provider's (`:sanctum, :scripted_oauth_provider`). The vault's own
  writes are the sanctum suite's (`Sanctum.IssuanceTest`),
  and two connections racing a consumption and a revocation are
  `Sanctum.Consent.AuthzRaceTest`'s.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Sanctum.{Context, DeviceCerts, Pairing, ProviderCredentials}

  alias Sanctum.Consent.Authz
  alias Sanctum.Test.DirectoryServer, as: Directory
  alias Sanctum.Vault.OAuthGrant

  @source "198.51.100.11"
  @provider "google"
  @scopes ["https://www.googleapis.com/auth/gmail.readonly"]
  # Where the grants' entries may go, as `Prima.Destination`'s canonical
  # text; no case reads a token, so they stay attach-only.
  @destination ~s({"hosts":["gmail.googleapis.com"],"scheme":"https"})

  setup_all do
    %{tls: Directory.tls()}
  end

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)
    Prima.Test.RateLimiter.reset!()
    on_exit(&Prima.Test.RateLimiter.reset!/0)

    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|glass-write-#{n}",
        provider: "github",
        email: "glass-write#{n}@example.com",
        verified: true
      })

    athanor = Sanctum.Test.People.athanor!(user)

    {:ok, session} =
      Sanctum.TestContext.create_session(
        Context.build(
          user_id: user.id,
          email: user.email,
          provider: "github",
          athanor_id: athanor.id,
          permissions: [:*],
          auth_method: :oidc,
          authenticated: true
        )
      )

    {:ok, session_ctx} =
      Sanctum.Caller.establish(session.token, focus: athanor.id, refresh: false)

    {:ok, _component} =
      Sanctum.Test.ComponentHelpers.register_test_component(
        "handler",
        "1.0.0",
        "formula",
        %{},
        session_ctx
      )

    profile_id =
      Sanctum.Test.ConsentFixtures.bindable_profile(session_ctx, "f:local.handler",
        profile_id: "prof-glass-#{n}"
      )

    :ok =
      Sanctum.TestContext.put_provider_credentials(
        session_ctx,
        @provider,
        "client-id-1",
        "client-secret-1"
      )

    {:ok, session_ctx: session_ctx, profile_id: profile_id, user: user}
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # A device of the person's account paired here, and its context once a
  # request under its certificate verified.
  defp paired!(session_ctx) do
    %{client_id: client_id, certificate: certificate, ctx: ctx} =
      Sanctum.Test.Devices.paired!(session_ctx.user_id, @source)

    {:ok, ctx} = DeviceCerts.verify_request(certificate, ctx)
    {client_id, ctx}
  end

  defp revoke!(session_ctx, client_id) do
    session_ctx
    |> Sanctum.TestContext.confirmed(:pairing_revocation, %{
      operation: "pairing.revoke",
      arguments: %{"client_id" => client_id},
      resource: client_id
    })
    |> Pairing.revoke(client_id)
  end

  # A handler on the repo's statements and on a confirmation's consumption:
  # the process that put `{test, point}` under `:window_hold` is held at the
  # first event `point` names, until the test releases it. Both points
  # below fire outside any transaction, so the test can write meanwhile.
  @doc false
  def hold(event, _measurements, metadata, _config) do
    with {test, point} <- Process.get(:window_hold),
         true <- point.(event, metadata) do
      Process.delete(:window_hold)
      send(test, {:window_held, self()})

      receive do
        :release -> :ok
      end
    end

    :ok
  end

  # Once the confirmation the write needs is consumed: the request was
  # verified and confirmed, and the write's transaction has not begun.
  defp confirmed_point([:cyfr, :sanctum, :confirmation, :consumed], _metadata), do: true
  defp confirmed_point(_event, _metadata), do: false

  # Once a grant's standing was read again after its token exchange: the
  # second read of its paired client (`Sanctum.Caller.revalidate_session/1`
  # reads it once per recheck, and nothing else in the callback does).
  defp regranted_point([:arca, :repo, :query], %{source: "paired_clients"}) do
    seen = Process.get(:client_reads, 0) + 1
    Process.put(:client_reads, seen)
    seen == 2
  end

  defp regranted_point(_event, _metadata), do: false

  # `write`, run by a task held at `point`, where the person revokes the
  # device under their session before the task goes on.
  defp revoked_in_window(session_ctx, client_id, point, write) do
    test = self()
    handler = "device-write-window-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        [[:arca, :repo, :query], [:cyfr, :sanctum, :confirmation, :consumed]],
        &__MODULE__.hold/4,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    task =
      Task.async(fn ->
        Process.put(:window_hold, {test, point})
        write.()
      end)

    assert_receive {:window_held, held}, 5_000
    assert {:ok, %{standing: "revoked"}} = revoke!(session_ctx, client_id)
    send(held, :release)
    Task.await(task, 25_000)
  end

  defp webhook?(ctx, name) do
    Arca.Repo.exists?(
      from(w in Arca.Schemas.Webhook, where: w.athanor_id == ^ctx.athanor_id and w.name == ^name)
    )
  end

  # A provider no shipped preset is (`:sanctum, :scripted_oauth_provider`),
  # standing in for its token endpoint: every code exchange is answered
  # one bundle.
  defmodule GrantIdp do
    @moduledoc false

    @hint "glass-idp"
    @endpoints %{
      "authorize_url" => "https://idp.glass.test/authorize",
      "token_url" => "https://idp.glass.test/token"
    }

    def hint, do: @hint
    def endpoints, do: @endpoints

    def preset(@hint), do: %{endpoints: @endpoints}
    def preset(_hint), do: nil

    def post(_url, _headers, _body),
      do: {:ok, %{"access_token" => "at-1", "refresh_token" => "rt-1", "expires_in" => 3600}}
  end

  # A grant pending under the device's context as
  # `OAuthGrant.authorize_url/2` mints one; the pending record is
  # server-minted state.
  defp pending_grant!(ctx, target) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    pending = %{
      target: target,
      redirect_uri: OAuthGrant.redirect_uri(),
      code_verifier: "verifier-1",
      context: ctx,
      actor: Context.actor(ctx)
    }

    Arca.Cache.put({:vault_oauth_pending, state}, pending, 120_000)
    {state, pending}
  end

  defp new_target(name) do
    %{
      kind: :new,
      entry_id: nil,
      name: name,
      provider: GrantIdp.hint(),
      endpoints: GrantIdp.endpoints(),
      scopes: @scopes,
      destination: @destination,
      attach_only: true
    }
  end

  # An oauth entry already bound to the scripted provider's endpoints and
  # holding a bundle, so a re-auth is the same-binding rotation.
  defp existing_target!(ctx, name) do
    id = Prima.UUID7.generate_id("vlt")
    aad = Sanctum.CipherAAD.vault_entry(ctx.athanor_id, id, GrantIdp.hint())
    {:ok, json} = Sanctum.Vault.Payload.encode_material(%{}, %{"access_token" => "at-0"})
    {:ok, sealed} = Sanctum.Cipher.encrypt(json, aad)

    {:ok, entry} =
      Arca.VaultStorage.put(Context.actor(ctx), %{
        id: id,
        name: name,
        kind: "oauth",
        provider_hint: GrantIdp.hint(),
        oauth_endpoints: Jason.encode!(GrantIdp.endpoints()),
        oauth_scopes: Jason.encode!(@scopes),
        sealed_payload: sealed,
        destination: @destination
      })

    target = %{
      kind: :existing,
      entry_id: entry.id,
      name: name,
      provider: GrantIdp.hint(),
      endpoints: GrantIdp.endpoints(),
      scopes: @scopes
    }

    {entry, target}
  end

  # ---------------------------------------------------------------------------
  # A webhook
  # ---------------------------------------------------------------------------

  describe "a webhook a device creates" do
    test "is refused by a revocation after its request was confirmed: none is written",
         %{session_ctx: session_ctx, profile_id: profile_id} do
      {client_id, ctx} = paired!(session_ctx)

      opts = %{
        name: "glass-hook",
        target_ref: "f:local.handler",
        profile_id: profile_id,
        replay_protection: "none"
      }

      confirmed =
        Sanctum.TestContext.confirmed(ctx, :credential_issuance, %{
          operation: "webhook.create",
          arguments: opts,
          resource: "glass-hook"
        })

      assert {:error, :not_standing} =
               revoked_in_window(session_ctx, client_id, &confirmed_point/2, fn ->
                 Sanctum.Webhook.create(confirmed, opts)
               end)

      refute webhook?(ctx, "glass-hook")
    end

    test "is refused through the webhook tool with the refusal's own sentence, logging nothing",
         %{session_ctx: session_ctx, profile_id: profile_id} do
      {client_id, ctx} = paired!(session_ctx)

      args = %{
        "action" => "create",
        "name" => "glass-tool-hook",
        "target_ref" => "f:local.handler",
        "profile_id" => profile_id,
        "replay_protection" => "none"
      }

      {answer, log} =
        ExUnit.CaptureLog.with_log(fn ->
          revoked_in_window(session_ctx, client_id, &confirmed_point/2, fn ->
            Sanctum.TestContext.confirming(ctx, &Sanctum.Providers.Webhook.handle(&1, args))
          end)
        end)

      assert answer == {:error, Prima.Refusal.message(:not_standing)}
      refute log =~ "Sanctum.Providers.Webhook"
      refute webhook?(ctx, "glass-tool-hook")
    end

    test "is written while the device stands", %{
      session_ctx: session_ctx,
      profile_id: profile_id
    } do
      {_client_id, ctx} = paired!(session_ctx)

      opts = %{
        name: "glass-hook-standing",
        target_ref: "f:local.handler",
        profile_id: profile_id,
        replay_protection: "none"
      }

      confirmed =
        Sanctum.TestContext.confirmed(ctx, :credential_issuance, %{
          operation: "webhook.create",
          arguments: opts,
          resource: "glass-hook-standing"
        })

      assert {:ok, %{name: "glass-hook-standing", secret: "whsec_" <> _}} =
               Sanctum.Webhook.create(confirmed, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # An OAuth grant a device started
  # ---------------------------------------------------------------------------

  describe "an OAuth grant a device started" do
    setup %{session_ctx: session_ctx} do
      # Restored by on_exit, registered before the change.
      prior = Application.fetch_env(:sanctum, :scripted_oauth_provider)

      on_exit(fn ->
        case prior do
          {:ok, value} -> Application.put_env(:sanctum, :scripted_oauth_provider, value)
          :error -> Application.delete_env(:sanctum, :scripted_oauth_provider)
        end
      end)

      Application.put_env(:sanctum, :scripted_oauth_provider, GrantIdp)

      :ok =
        Sanctum.TestContext.put_provider_credentials(
          session_ctx,
          GrantIdp.hint(),
          "client-id-1",
          "client-secret-1"
        )

      :ok
    end

    test "creating an entry is refused by a revocation after its standing was read again: none is written",
         %{session_ctx: session_ctx} do
      {client_id, ctx} = paired!(session_ctx)
      {state, pending} = pending_grant!(ctx, new_target("Glass mail"))

      assert {:error, :unauthenticated} =
               revoked_in_window(session_ctx, client_id, &regranted_point/2, fn ->
                 OAuthGrant.complete(state, "code-1", pending.redirect_uri)
               end)

      assert {:error, :not_found} =
               Arca.VaultStorage.get_by_name(Context.actor(ctx), "Glass mail")
    end

    test "rotating an entry is refused the same way: its material stays at its revision",
         %{session_ctx: session_ctx} do
      {client_id, ctx} = paired!(session_ctx)
      {entry, target} = existing_target!(ctx, "Glass mail rotated")
      {state, pending} = pending_grant!(ctx, target)

      assert {:error, :unauthenticated} =
               revoked_in_window(session_ctx, client_id, &regranted_point/2, fn ->
                 OAuthGrant.complete(state, "code-2", pending.redirect_uri)
               end)

      assert {:ok, unchanged} = Arca.VaultStorage.get(Context.actor(ctx), entry.id)

      assert {unchanged.payload_rev, unchanged.sealed_payload} ==
               {entry.payload_rev, entry.sealed_payload}
    end

    test "writes its entry while the device stands", %{session_ctx: session_ctx} do
      {_client_id, ctx} = paired!(session_ctx)
      {state, pending} = pending_grant!(ctx, new_target("Glass mail standing"))

      assert {:ok, %{name: "Glass mail standing", rebound: false}} =
               OAuthGrant.complete(state, "code-3", pending.redirect_uri)
    end
  end

  # ---------------------------------------------------------------------------
  # OAuth provider credentials
  # ---------------------------------------------------------------------------

  describe "OAuth provider credentials a device stores" do
    test "are refused by a revocation after the confirmation was consumed: the athanor's stay",
         %{session_ctx: session_ctx} do
      {client_id, ctx} = paired!(session_ctx)
      args = %{provider: @provider, client_id: "replacement", client_secret: "replaced"}

      confirmed =
        Sanctum.TestContext.confirmed(ctx, :credential_entry, %{
          operation: "oauth.set_client",
          arguments: args,
          resource: @provider
        })

      assert {:error, :not_standing} =
               revoked_in_window(session_ctx, client_id, &confirmed_point/2, fn ->
                 ProviderCredentials.put(confirmed, @provider, args.client_id, args.client_secret)
               end)

      assert {:error, :not_standing} =
               Authz.authorize(ctx, %Authz.Request{commit_digest: "sha256:commit-one"})

      assert {:ok, %{"client_id" => "client-id-1", "client_secret" => "client-secret-1"}} =
               ProviderCredentials.fetch_for_oauth(ctx.athanor_id, @provider)
    end

    test "are stored while the device stands", %{session_ctx: session_ctx} do
      {_client_id, ctx} = paired!(session_ctx)

      assert :ok =
               Sanctum.TestContext.put_provider_credentials(ctx, @provider, "glass-id", "glass")

      assert {:ok, %{"client_id" => "glass-id", "client_secret" => "glass"}} =
               ProviderCredentials.fetch_for_oauth(ctx.athanor_id, @provider)
    end
  end
end
