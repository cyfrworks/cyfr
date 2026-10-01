# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DeviceWriteWindowTest do
  @moduledoc """
  A webhook a paired device creates, and a vault entry its OAuth grant
  writes, are written in a transaction that holds the device's client and
  certificate (`Sanctum.Issuance.device_hold/1`). A revocation that commits
  after the request was verified (and confirmed, or the grant's standing
  read again) and before the write refuses it, and nothing is written.
  These need what only this suite has: the component domain a webhook's
  target is checked in, and an HTTP stub for the grant's token endpoint.
  The rotation and the vault's own writes are the sanctum suite's
  (`Sanctum.IssuanceTest`).
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Prima.DeviceCert.{Challenge, Proof}
  alias Sanctum.{Context, DeviceCerts, Pairing}
  alias Sanctum.Tenancy.{Athanors, Users}
  alias Sanctum.Vault.OAuthGrant

  @source "198.51.100.11"
  @provider "google"
  @scopes ["https://www.googleapis.com/auth/gmail.readonly"]

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Prima.RateLimiter.reset()
    on_exit(&Prima.RateLimiter.reset/0)

    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|glass-write-#{n}",
        provider: "github",
        email: "glass-write#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Glass writes #{n}")

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
      Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)

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

    {:ok, session_ctx: session_ctx, profile_id: profile_id}
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # A device paired through the ceremony, and its context once a request
  # under its certificate verified.
  defp paired!(session_ctx) do
    {device_key, private} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, invitation} =
      session_ctx
      |> Sanctum.TestContext.confirmed(:device_pairing, Pairing.invitation_change())
      |> Pairing.begin(%{})

    glass = Context.build(%{authenticated: false, client_ip: @source})
    submission = %{device_key: device_key}

    {:ok, %{challenge: pairing}} =
      Pairing.complete(glass, invitation.invitation_secret, submission)

    {:ok, %{client_id: client_id, certificate: certificate}} =
      Pairing.complete(
        glass,
        invitation.invitation_secret,
        Map.put(submission, :proof, Proof.sign(pairing, private))
      )

    {:ok, challenge} =
      Challenge.new(
        purpose: :connect,
        home: certificate.audience,
        athanor: certificate.athanor,
        client_id: client_id,
        device_key: certificate.device_key,
        nonce: :crypto.strong_rand_bytes(Challenge.nonce_bytes()),
        now: System.system_time(:millisecond)
      )

    {:ok, ctx} =
      DeviceCerts.verify_connect(
        %{client_id: client_id, certificate: certificate, source: @source},
        Proof.sign(challenge, private),
        challenge
      )

    {:ok, ctx} = DeviceCerts.verify_request(certificate, ctx, [])
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

  # The token endpoint answering once, and a grant pending under the
  # device's context as `OAuthGrant.authorize_url/2` mints one. The pending
  # record is server-minted state; fabricating it keeps the stub's http
  # token URL past the https check that guards operator input.
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

  defp token_endpoint!(bypass) do
    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "access_token" => "at-1",
          "refresh_token" => "rt-1",
          "expires_in" => 3600,
          "token_type" => "Bearer"
        })
      )
    end)
  end

  defp endpoints(bypass) do
    %{
      "authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth",
      "token_url" => "http://localhost:#{bypass.port}/token",
      "auth_style" => "params"
    }
  end

  defp new_target(name, bypass) do
    %{
      kind: :new,
      entry_id: nil,
      name: name,
      provider: @provider,
      endpoints: endpoints(bypass),
      scopes: @scopes
    }
  end

  # An oauth entry already bound to the stub's endpoints, so a re-auth is
  # the same-binding rotation.
  defp existing_target!(ctx, name, bypass) do
    {:ok, entry} =
      Arca.VaultStorage.put(Context.actor(ctx), %{
        name: name,
        kind: "oauth",
        provider_hint: @provider,
        oauth_endpoints: Jason.encode!(endpoints(bypass)),
        oauth_scopes: Jason.encode!(@scopes),
        sealed_payload: "sealed-v1"
      })

    target = %{
      kind: :existing,
      entry_id: entry.id,
      name: name,
      provider: @provider,
      endpoints: endpoints(bypass),
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
    test "creating an entry is refused by a revocation after its standing was read again: none is written",
         %{session_ctx: session_ctx} do
      {client_id, ctx} = paired!(session_ctx)
      bypass = Bypass.open()
      token_endpoint!(bypass)
      {state, pending} = pending_grant!(ctx, new_target("Glass mail", bypass))

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
      bypass = Bypass.open()
      token_endpoint!(bypass)
      {entry, target} = existing_target!(ctx, "Glass mail rotated", bypass)
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
      bypass = Bypass.open()
      token_endpoint!(bypass)
      {state, pending} = pending_grant!(ctx, new_target("Glass mail standing", bypass))

      assert {:ok, %{name: "Glass mail standing", rebound: false}} =
               OAuthGrant.complete(state, "code-3", pending.redirect_uri)
    end
  end
end
