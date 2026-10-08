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
  whose confirmation is consumed in its write's own transaction (a
  certification for another home, an enrollment, another kit, a live-key
  rotation, a remote sign-in assertion, a passkey) is held there by the
  consumption (`Sanctum.Consent.Authz.consume/2`); the revocation lands
  inside that transaction, right after the device's standing was read
  there. A device never reaches a door's link or unlink, which are a
  session's. Each change still completes while the device stands.

  These need what only this suite has: the component domain a webhook's
  target is checked in, and an HTTP stub for the grant's token endpoint.
  The rotation and the vault's own writes are the sanctum suite's
  (`Sanctum.IssuanceTest`), and two connections racing a consumption and
  a revocation are `Sanctum.Consent.AuthzRaceTest`'s.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{DeviceCertification, IdentityAttempt, Passkey, PersonIdentity}
  alias Prima.DeviceCert.{Challenge, Proof}
  alias Prima.Identity.Encoding

  alias Sanctum.{
    Context,
    DeviceCerts,
    IdentityFreshness,
    Pairing,
    Passkeys,
    Person,
    ProviderCredentials,
    Recovery,
    RemoteCertification,
    SignIn
  }

  alias Sanctum.Consent.Authz
  alias Sanctum.Tenancy.{Athanors, Users}
  alias Sanctum.Test.DirectoryServer, as: Directory
  alias Sanctum.TestContext.Authenticator
  alias Sanctum.Vault.OAuthGrant

  @source "198.51.100.11"
  @provider "google"
  @scopes ["https://www.googleapis.com/auth/gmail.readonly"]
  # Where the grants' entries may go, as `Prima.Destination`'s canonical
  # text; no case reads a token, so they stay attach-only.
  @destination ~s({"hosts":["gmail.googleapis.com"],"scheme":"https"})
  @hub "https://hub.example"

  setup_all do
    %{tls: Directory.tls()}
  end

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)
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

    {:ok, session_ctx: session_ctx, profile_id: profile_id, user: user}
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

  # A handler on the repo's statements: the process that put
  # `{test, actor, client_id}` under `:revoke_in_place` revokes that client
  # right after its first read of a paired client inside a transaction (the
  # device's standing read where its change is consumed, in the write's own
  # transaction), and tells the test what the revocation answered.
  @doc false
  def revoke_in_place(_event, _measurements, %{source: "paired_clients"}, _config) do
    with {test, actor, client_id} <- Process.get(:revoke_in_place),
         true <- Arca.Repo.in_transaction?() do
      Process.delete(:revoke_in_place)
      send(test, {:revoked_in_place, Arca.PairedClients.revoke(actor, client_id)})
    end

    :ok
  end

  def revoke_in_place(_event, _measurements, _metadata, _config), do: :ok

  # `write`, run here with the person's revocation of the device landing
  # inside the write's own transaction, right after the device's standing
  # was read there: on the one connection a sandboxed test has, the only
  # point a revocation can land between that read and the write. A refused
  # write rolls the revocation back with everything else, so a case
  # asserts what the write answered and that nothing was written.
  defp revoked_in_place(session_ctx, client_id, write) do
    handler = "device-write-in-place-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(handler, [:arca, :repo, :query], &__MODULE__.revoke_in_place/4, nil)
    on_exit(fn -> :telemetry.detach(handler) end)
    Process.put(:revoke_in_place, {self(), Context.actor(session_ctx), client_id})

    answer =
      try do
        write.()
      after
        Process.delete(:revoke_in_place)
        :telemetry.detach(handler)
      end

    assert_received {:revoked_in_place, {:ok, %{standing: "revoked"}}}
    answer
  end

  # `site` under the device's `ctx` as its person confirms it
  # (`Sanctum.TestContext.confirming/2`): asked, proven, then repeated under
  # the proven record with the device revoked at its write.
  defp revoked_at_its_write(session_ctx, client_id, ctx, site) do
    Sanctum.TestContext.confirming(ctx, fn
      %Context{confirmation_id: nil} = asking -> site.(asking)
      repeating -> revoked_in_place(session_ctx, client_id, fn -> site.(repeating) end)
    end)
  end

  defp confirmations(user_id) do
    Arca.Repo.aggregate(from(c in "pending_confirmations", where: c.user_id == ^user_id), :count)
  end

  defp identity(user_id), do: Arca.Repo.get_by!(PersonIdentity, user_id: user_id)
  defp attempt(request_id), do: Arca.Repo.get_by(IdentityAttempt, request_id: request_id)
  defp request_id, do: "req_#{System.unique_integer([:positive])}"
  defp kit_seed, do: :crypto.strong_rand_bytes(32)

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
      scopes: @scopes,
      destination: @destination,
      attach_only: true
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
        sealed_payload: "sealed-v1",
        destination: @destination
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

  # ---------------------------------------------------------------------------
  # A passkey
  # ---------------------------------------------------------------------------

  # The browser's registration of a new authenticator under the device's
  # context, and the credential id it stores.
  defp glass_registration!(ctx) do
    authenticator = Authenticator.new("glass-#{System.unique_integer([:positive])}")
    {:ok, options} = Passkeys.register(ctx, %{})
    credential = Authenticator.registration(authenticator, options)
    {credential, Encoding.b64(authenticator.credential_id)}
  end

  defp passkey?(credential_id),
    do: Arca.Repo.exists?(from(p in Passkey, where: p.credential_id == ^credential_id))

  describe "a passkey a device registers" do
    test "is refused by a revocation at its write: none is stored", %{session_ctx: session_ctx} do
      {client_id, ctx} = paired!(session_ctx)
      {credential, credential_id} = glass_registration!(ctx)

      assert {:error, :not_standing} =
               revoked_at_its_write(
                 session_ctx,
                 client_id,
                 ctx,
                 &Passkeys.register(&1, %{credential: credential})
               )

      refute passkey?(credential_id)
    end

    test "is registered while the device stands", %{session_ctx: session_ctx} do
      {_client_id, ctx} = paired!(session_ctx)
      {credential, credential_id} = glass_registration!(ctx)

      assert {:ok, %{status: "active"}} =
               Sanctum.TestContext.confirming(
                 ctx,
                 &Passkeys.register(&1, %{credential: credential})
               )

      assert passkey?(credential_id)
    end
  end

  # ---------------------------------------------------------------------------
  # A door
  # ---------------------------------------------------------------------------

  describe "a door a device names" do
    test "is never linked from a device: refused at the door, nothing opened or written",
         %{session_ctx: session_ctx, user: user} do
      {_client_id, ctx} = paired!(session_ctx)
      asked = confirmations(user.id)
      {:ok, doors} = Arca.Users.identities(Prima.Actor.system(), user.id)
      ticket = Encoding.b64(:crypto.strong_rand_bytes(32))

      assert {:error, :unauthenticated} = SignIn.link_door(ctx, "github", ticket)

      assert confirmations(user.id) == asked
      assert {:ok, ^doors} = Arca.Users.identities(Prima.Actor.system(), user.id)
    end

    test "is never unlinked from a device: refused at the door, the door stays",
         %{session_ctx: session_ctx, user: user} do
      {_client_id, ctx} = paired!(session_ctx)
      asked = confirmations(user.id)
      {:ok, [door | _] = doors} = Arca.Users.identities(Prima.Actor.system(), user.id)

      assert {:error, :unauthenticated} = SignIn.unlink_door(ctx, door.key)

      assert confirmations(user.id) == asked
      assert {:ok, ^doors} = Arca.Users.identities(Prima.Actor.system(), user.id)
    end
  end

  # ---------------------------------------------------------------------------
  # The person's identity
  # ---------------------------------------------------------------------------

  # The person enrolled at the scripted directory under their session, as
  # they enroll from Prism; answers the kit's seed.
  defp enrolled!(session_ctx, opts) do
    seed = kit_seed()
    args = %{"recovery_secret" => Encoding.b64(seed), "request_id" => request_id()}

    {:ok, %{phase: "accepted"}} =
      Sanctum.TestContext.confirming(session_ctx, &Recovery.enroll(&1, args, opts))

    seed
  end

  defp certify_args do
    {device_key, _private} = :crypto.generate_key(:eddsa, :ed25519)

    %{
      "device_key" => Encoding.b64(device_key),
      "audience" => @hub,
      "athanor" => "ath_hub",
      "client_id" => "pcl_hub"
    }
  end

  defp certifications(user_id),
    do: Arca.Repo.all(from(c in DeviceCertification, where: c.user_id == ^user_id))

  defp holder_args(signer, added, id) do
    %{
      "recovery_secret" => Encoding.b64(signer),
      "holder" => %{"kind" => "kit", "recovery_secret" => Encoding.b64(added)},
      "request_id" => id
    }
  end

  # The person's own pending carry to the hub, under the head their row
  # holds, and the assertion request the hub's challenge makes of it.
  defp carried!(user_id) do
    payload = ~s({"genesis":{}})
    head = identity(user_id).head_hash

    {:ok, action} =
      Arca.CarryActions.open(%Prima.Actor{user_id: user_id}, %{
        user_id: user_id,
        action_id: "car_#{System.unique_integer([:positive])}",
        source_home: Person.home(),
        destination_home: @hub,
        return_url: Person.home() <> "/carry",
        payload: payload,
        payload_digest: Prima.Digest.sha256(payload),
        key_epoch: head
      })

    request = %{
      audience: @hub,
      challenge: :crypto.strong_rand_bytes(32),
      action_id: action.action_id,
      key_epoch: head
    }

    {action, request}
  end

  describe "a person's identity, changed from a device" do
    setup %{tls: tls} do
      Directory.listen!()
      pinned = Application.fetch_env(:sanctum, :directory_url)

      on_exit(fn ->
        case pinned do
          {:ok, url} -> Application.put_env(:sanctum, :directory_url, url)
          :error -> Application.delete_env(:sanctum, :directory_url)
        end

        Arca.Cache.delete_match(Arca.Cache.Keys.match_identity_unreachable())
      end)

      directory = Directory.start!(tls)
      Application.put_env(:sanctum, :directory_url, directory.url)
      {:ok, opts: Directory.opts(tls)}
    end

    test "certifying a device for another home is refused by a revocation at its write: none is recorded",
         %{session_ctx: session_ctx, user: user, opts: opts} do
      enrolled!(session_ctx, opts)
      {client_id, ctx} = paired!(session_ctx)
      args = certify_args()

      assert {:error, :not_standing} =
               revoked_at_its_write(
                 session_ctx,
                 client_id,
                 ctx,
                 &RemoteCertification.certify(&1, args)
               )

      assert certifications(user.id) == []
    end

    test "a device for another home is certified while the device stands",
         %{session_ctx: session_ctx, user: user, opts: opts} do
      enrolled!(session_ctx, opts)
      {_client_id, ctx} = paired!(session_ctx)
      args = certify_args()

      assert {:ok, %{certificate: %{}}} =
               Sanctum.TestContext.confirming(ctx, &RemoteCertification.certify(&1, args))

      assert [%{audience_home: @hub}] = certifications(user.id)
    end

    test "enrolling is refused by a revocation at its write: no attempt is opened",
         %{session_ctx: session_ctx, user: user, opts: opts} do
      {client_id, ctx} = paired!(session_ctx)
      id = request_id()
      args = %{"recovery_secret" => Encoding.b64(kit_seed()), "request_id" => id}

      assert {:error, :not_standing} =
               revoked_at_its_write(session_ctx, client_id, ctx, &Recovery.enroll(&1, args, opts))

      assert attempt(id) == nil
      assert %{enrollment: "none", identifier: nil} = identity(user.id)
    end

    test "the person enrolls while the device stands",
         %{session_ctx: session_ctx, user: user, opts: opts} do
      {_client_id, ctx} = paired!(session_ctx)
      args = %{"recovery_secret" => Encoding.b64(kit_seed()), "request_id" => request_id()}

      assert {:ok, %{phase: "accepted"}} =
               Sanctum.TestContext.confirming(ctx, &Recovery.enroll(&1, args, opts))

      assert %{enrollment: "enrolled"} = identity(user.id)
    end

    test "another kit is refused by a revocation at its write: no attempt is opened, the head stays",
         %{session_ctx: session_ctx, user: user, opts: opts} do
      seed = enrolled!(session_ctx, opts)
      {client_id, ctx} = paired!(session_ctx)
      head = identity(user.id).head_hash
      id = request_id()
      args = holder_args(seed, kit_seed(), id)

      assert {:error, :not_standing} =
               revoked_at_its_write(
                 session_ctx,
                 client_id,
                 ctx,
                 &Recovery.enroll_holder(&1, args, opts)
               )

      assert attempt(id) == nil
      assert identity(user.id).head_hash == head
    end

    test "another kit is added while the device stands",
         %{session_ctx: session_ctx, user: user, opts: opts} do
      seed = enrolled!(session_ctx, opts)
      {_client_id, ctx} = paired!(session_ctx)
      args = holder_args(seed, kit_seed(), request_id())

      assert {:ok, %{phase: "accepted", key_epoch: epoch}} =
               Sanctum.TestContext.confirming(ctx, &Recovery.enroll_holder(&1, args, opts))

      assert identity(user.id).head_hash == epoch
    end

    test "rotating the live key is refused by a revocation at its write: no attempt, the key stays",
         %{session_ctx: session_ctx, user: user, opts: opts} do
      enrolled!(session_ctx, opts)
      {client_id, ctx} = paired!(session_ctx)
      before = identity(user.id)
      id = request_id()

      assert {:error, :not_standing} =
               revoked_at_its_write(
                 session_ctx,
                 client_id,
                 ctx,
                 &IdentityFreshness.rotate_live(&1, id, opts)
               )

      assert attempt(id) == nil
      after_it = identity(user.id)

      assert {after_it.live_public_key, after_it.head_hash} ==
               {before.live_public_key, before.head_hash}
    end

    test "the live key is rotated while the device stands",
         %{session_ctx: session_ctx, user: user, opts: opts} do
      enrolled!(session_ctx, opts)
      {_client_id, ctx} = paired!(session_ctx)
      id = request_id()

      assert {:ok, %{request_id: ^id, phase: "completed", key_epoch: epoch}} =
               Sanctum.TestContext.confirming(ctx, &IdentityFreshness.rotate_live(&1, id, opts))

      assert identity(user.id).head_hash == epoch
    end

    test "a remote sign-in assertion is refused by a revocation at its write: none is recorded",
         %{session_ctx: session_ctx, user: user, opts: opts} do
      enrolled!(session_ctx, opts)
      {client_id, ctx} = paired!(session_ctx)
      {action, request} = carried!(user.id)

      assert {:error, :not_standing} =
               revoked_at_its_write(
                 session_ctx,
                 client_id,
                 ctx,
                 &Person.sign_assertion(&1, request, [])
               )

      assert {:ok, %{assertion: nil}} =
               Arca.CarryActions.get(%Prima.Actor{user_id: user.id}, action.id)
    end

    test "a remote sign-in assertion is signed while the device stands",
         %{session_ctx: session_ctx, user: user, opts: opts} do
      enrolled!(session_ctx, opts)
      {_client_id, ctx} = paired!(session_ctx)
      {action, request} = carried!(user.id)

      assert {:ok, %{assertion: %Prima.PersonAssertion{}}} =
               Sanctum.TestContext.confirming(ctx, &Person.sign_assertion(&1, request, []))

      assert {:ok, %{assertion: recorded}} =
               Arca.CarryActions.get(%Prima.Actor{user_id: user.id}, action.id)

      assert is_binary(recorded)
    end
  end
end
