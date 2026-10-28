# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.OIDCReauthTest do
  @moduledoc """
  A re-authentication through the home's OpenID Connect issuer, bound to
  one pending confirmation.

  The request forces a fresh login (`prompt=login`, `max_age=0`) and
  carries a nonce derived from the record, held on it, and a state naming
  the record by its public ref under the home's keyed digest, never the
  secret its asking request holds; its redirect URI is the
  second one the issuer lists, `<origin>/auth/oidcc/reauth`. The callback
  verifies the login only when the ID token carries the record's nonce,
  an `auth_time` at or after the record's opening, and the issuer and
  subject of the person's own linked door: a login the issuer answered
  from its own session, another record's nonce, another subject, a forged
  state or an issuer that sends no `auth_time` proves nothing.

  A verified login confirms nothing by itself. Its page shows the
  record's preview, and the record is confirmed only when the person
  approves there, by a POST the CSRF token guards, from a browser whose
  own session is the record's person: a decline, another person's
  browser or one with no session confirms nothing.

  The issuer here is a stand-in for the token exchange alone
  (`:sanctum, :oidc_reauth_client`): it answers the claims a test hands
  it, as a real issuer's validated ID token would carry them, and every
  check of them is `Sanctum.Auth.OIDC`'s. The authorization URL is the
  real one (`Sanctum.Auth.OIDC.Oidcc.authorize_url/1`, through `Oidcc`),
  built against the issuer's configuration as the `:cyfr_oidc` worker
  holds it.
  """

  use CyfrWeb.ConnCase, async: false

  alias Sanctum.Auth.OIDC
  alias Sanctum.Context
  alias Sanctum.Tenancy.Athanors

  @issuer "https://idp.example.com"

  defmodule ProviderConfiguration do
    @moduledoc false

    # The issuer's configuration as the `:cyfr_oidc` worker
    # `ueberauth_oidcc` starts holds it once it read the issuer's discovery
    # document: decoded here from such a document, with no network, and
    # answered to `Oidcc` as that worker answers it.
    use GenServer

    def start_link(issuer), do: GenServer.start_link(__MODULE__, issuer, name: :cyfr_oidc)

    @impl true
    def init(issuer) do
      {:ok, configuration} =
        :oidcc_provider_configuration.decode_configuration(%{
          "issuer" => issuer,
          "authorization_endpoint" => issuer <> "/authorize",
          "token_endpoint" => issuer <> "/token",
          "jwks_uri" => issuer <> "/jwks",
          "scopes_supported" => ["openid", "email"],
          "response_types_supported" => ["code"],
          "subject_types_supported" => ["public"],
          "id_token_signing_alg_values_supported" => ["ES256"],
          "code_challenge_methods_supported" => ["S256"]
        })

      {:ok, %{configuration: configuration, jwks: :jose_jwk.generate_key({:ec, "P-256"})}}
    end

    @impl true
    def handle_call(:get_provider_configuration, _from, state),
      do: {:reply, state.configuration, state}

    def handle_call(:get_jwks, _from, state), do: {:reply, state.jwks, state}
  end

  defmodule Issuer do
    @moduledoc false

    # The URL the browser is sent to, built by the real exchange; the
    # request is kept for the test to read.
    def authorize_url(request) do
      send(self(), {:authorize, request})
      OIDC.Oidcc.authorize_url(request)
    end

    # The claims a test encoded into the code, as the validated ID token's.
    def redeem(code, request) do
      send(self(), {:redeem, request})

      case Base.url_decode64(code, padding: false) do
        {:ok, json} -> {:ok, Jason.decode!(json)}
        :error -> {:error, :reauth_refused}
      end
    end
  end

  setup do
    oidc = Application.get_env(:sanctum, :oidc_issuer)
    ueberauth = Application.get_env(:ueberauth, Ueberauth)
    client = Application.get_env(:sanctum, :oidc_reauth_client)

    Application.put_env(:sanctum, :oidc_issuer, @issuer)
    Application.put_env(:sanctum, :oidc_reauth_client, Issuer)

    Application.put_env(:ueberauth, Ueberauth,
      providers: [
        oidcc:
          {Ueberauth.Strategy.Oidcc, issuer: :cyfr_oidc, client_id: "cid", client_secret: "csec"}
      ]
    )

    on_exit(fn ->
      restore(:sanctum, :oidc_issuer, oidc)
      restore(:sanctum, :oidc_reauth_client, client)
      restore(:ueberauth, Ueberauth, ueberauth)
    end)

    start_supervised!({ProviderConfiguration, @issuer})
    seated!()
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  # A person whose door is this issuer's subject, seated in a group, and the
  # context their session establishes there.
  defp seated!(subject \\ "sub-#{System.unique_integer([:positive])}") do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: Sanctum.Auth.Identity.key(:oidcc, @issuer, subject),
        provider: "oidcc",
        email: "reauth#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Reauth #{n}")

    built =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "oidcc",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(built)
    {:ok, ctx} = Sanctum.Caller.establish(session.token, focus: athanor.id, refresh: false)
    %{user: user, athanor: athanor, ctx: ctx, subject: subject, token: session.token}
  end

  # A browser whose cookie session is `token`'s, or none.
  defp browser(conn, nil), do: Plug.Test.init_test_session(conn, %{})

  defp browser(conn, token),
    do: Plug.Test.init_test_session(conn, %{CyfrWeb.SignInResponse.session_key() => token})

  # A verified login's held proof: the callback's answer.
  defp verified!(ctx, subject, id) do
    {_url, request} = begun!(ctx, id)

    assert {:ok, %{ticket: ticket} = held} =
             OIDC.reauth_callback(%{
               "state" => request.state,
               "code" => code(claims(request, subject))
             })

    assert is_binary(ticket)
    {held, request}
  end

  defp change(name \\ "prod-key") do
    %{
      operation: "vault.create",
      arguments: %{name: name, kind: "api_key", fields: %{"KEY" => "sk-secret"}},
      resource: name
    }
  end

  # A change asked for with no proof: the signal's secret, and the ref
  # every other surface names its record by.
  defp asked!(ctx, change \\ change()) do
    {:error, {:confirmation_required, %{id: secret}}} =
      Sanctum.Consent.Authz.check(ctx, :credential_entry, change)

    {secret, Prima.Confirmation.ref(secret)}
  end

  # The record's ref, as a re-authentication names it.
  defp opened!(ctx, change \\ change()), do: ctx |> asked!(change) |> elem(1)

  defp record(ctx, id) do
    {:ok, row} = Arca.PendingConfirmations.get(Context.actor(ctx), id)
    row
  end

  # Begin the re-authentication, and answer the request it sent the issuer.
  defp begun!(ctx, id) do
    assert {:ok, %{method: "oidc", url: url}} = OIDC.reauth_url(ctx, id)
    assert_received {:authorize, request}
    {url, request}
  end

  # The code a login answers: the ID token's claims.
  defp code(claims), do: Base.url_encode64(Jason.encode!(claims), padding: false)

  defp claims(request, subject, overrides \\ %{}) do
    Map.merge(
      %{
        "iss" => @issuer,
        "sub" => subject,
        "aud" => "cid",
        "nonce" => request.nonce,
        "auth_time" => System.os_time(:second)
      },
      overrides
    )
  end

  describe "the request" do
    test "forces a fresh login for one record, at the second redirect URI", %{ctx: ctx} do
      {secret, id} = asked!(ctx)
      {url, request} = begun!(ctx, id)
      uri = URI.parse(url)
      query = URI.decode_query(uri.query)

      # The URL `Oidcc` built at the issuer's authorization endpoint, from
      # what the exchange handed it: the login forced fresh, the request's
      # own redirect, nonce and state, and the PKCE challenge of its
      # verifier.
      assert %URI{scheme: "https", host: "idp.example.com", path: "/authorize"} = uri
      assert query["prompt"] == "login"
      assert query["max_age"] == "0"
      assert query["response_type"] == "code"
      assert query["client_id"] == "cid"
      assert query["scope"] == "openid"
      assert query["redirect_uri"] == request.redirect_uri
      assert query["nonce"] == request.nonce
      assert query["state"] == request.state
      assert query["code_challenge_method"] == "S256"

      assert query["code_challenge"] ==
               Base.url_encode64(:crypto.hash(:sha256, request.pkce_verifier), padding: false)

      assert request.redirect_uri == Sanctum.Person.home() <> "/auth/oidcc/reauth"
      assert record(ctx, id).reauth_nonce == request.nonce
      refute request.nonce == id
      assert request.state =~ "."

      # The state names the record by its ref; nothing the issuer, the
      # browser or the request log sees carries the asking request's
      # secret.
      [payload, _mac] = String.split(request.state, ".")
      nonce = request.nonce

      assert %{"c" => ^id, "n" => ^nonce} =
               payload |> Base.url_decode64!(padding: false) |> Jason.decode!()

      for seen <- [url, request.state, request.nonce, request.pkce_verifier] do
        refute seen =~ secret
      end
    end

    test "a new request replaces the old nonce", %{ctx: ctx, subject: subject} do
      id = opened!(ctx)
      {_url, first} = begun!(ctx, id)
      {_url, second} = begun!(ctx, id)
      refute first.nonce == second.nonce

      assert OIDC.reauth_callback(%{
               "state" => first.state,
               "code" => code(claims(first, subject))
             }) ==
               {:error, :reauth_refused}

      assert {:ok, %{ref: ^id, ticket: _}} =
               OIDC.reauth_callback(%{
                 "state" => second.state,
                 "code" => code(claims(second, subject))
               })
    end

    test "a person with no door of this issuer is refused" do
      n = System.unique_integer([:positive])

      {:ok, user} =
        Sanctum.Test.People.linked(%{
          id: "github|https://github.com|reauth-#{n}",
          provider: "github",
          email: "reauth-gh#{n}@example.com",
          verified: true
        })

      {:ok, athanor} = Athanors.create_group(user.id, "Reauth GH #{n}")

      ctx =
        Context.build(
          user_id: user.id,
          athanor_id: athanor.id,
          permissions: [:*],
          auth_method: :oidc,
          authenticated: true
        )

      id = opened!(ctx)
      assert {:error, {:invalid_argument, _}} = OIDC.reauth_url(ctx, id)
      refute Sanctum.Auth.OIDC.reauth_available?(user.id)
    end
  end

  describe "the callback" do
    test "a fresh login by the person's own door is held, with the preview, and confirms nothing",
         %{ctx: ctx, subject: subject} do
      id = opened!(ctx)
      {held, request} = verified!(ctx, subject, id)

      assert_received {:redeem, redeemed}
      assert redeemed.nonce == request.nonce
      assert redeemed.pkce_verifier == request.pkce_verifier

      assert %{ref: ^id, operation: "vault.create", preview: preview} = held
      refute Map.has_key?(held, :id)
      assert preview["resource"] == "prod-key"
      assert preview["operation"] == "vault.create"
      refute inspect(held) =~ "sk-secret"

      assert record(ctx, id).state == "pending"
      assert record(ctx, id).proof == nil
    end

    test "a login the issuer answered from its own session, older than the record, is refused",
         %{ctx: ctx, subject: subject} do
      id = opened!(ctx)
      {_url, request} = begun!(ctx, id)
      opened = DateTime.to_unix(record(ctx, id).opened_at, :second)
      stale = claims(request, subject, %{"auth_time" => opened - 60})

      assert OIDC.reauth_callback(%{"state" => request.state, "code" => code(stale)}) ==
               {:error, :reauth_refused}

      assert record(ctx, id).state == "pending"
    end

    test "an issuer that sends no auth_time proves no freshness", %{ctx: ctx, subject: subject} do
      id = opened!(ctx)
      {_url, request} = begun!(ctx, id)
      without = Map.delete(claims(request, subject), "auth_time")

      assert OIDC.reauth_callback(%{"state" => request.state, "code" => code(without)}) ==
               {:error, :reauth_refused}
    end

    test "another record's nonce is refused", %{ctx: ctx, subject: subject} do
      id = opened!(ctx)
      other = opened!(ctx, change("other-key"))
      {_url, request} = begun!(ctx, id)
      {_url, other_request} = begun!(ctx, other)

      crossed = claims(request, subject, %{"nonce" => other_request.nonce})

      assert OIDC.reauth_callback(%{"state" => request.state, "code" => code(crossed)}) ==
               {:error, :reauth_refused}

      assert record(ctx, id).state == "pending"
    end

    test "a fresh login as another subject, or through another issuer, is refused",
         %{ctx: ctx, subject: subject} do
      id = opened!(ctx)
      {_url, request} = begun!(ctx, id)

      # Another person of the same issuer, even one this home knows.
      %{subject: someone} = seated!()

      for claims <- [
            claims(request, someone),
            claims(request, "sub-stranger"),
            claims(request, subject, %{"iss" => "https://other-idp.example.com"})
          ] do
        assert OIDC.reauth_callback(%{"state" => request.state, "code" => code(claims)}) ==
                 {:error, :reauth_refused}
      end

      assert record(ctx, id).state == "pending"
    end

    test "a forged state, an error answer or a used record confirms nothing",
         %{ctx: ctx, subject: subject, token: token} do
      id = opened!(ctx)
      {_url, request} = begun!(ctx, id)
      [payload, _mac] = String.split(request.state, ".")
      forged = payload <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      good = code(claims(request, subject))

      assert OIDC.reauth_callback(%{"state" => forged, "code" => good}) ==
               {:error, :reauth_refused}

      assert OIDC.reauth_callback(%{"state" => request.state, "error" => "login_required"}) ==
               {:error, :reauth_refused}

      assert {:ok, %{ticket: ticket}} =
               OIDC.reauth_callback(%{"state" => request.state, "code" => good})

      assert {:ok, %{state: "confirmed"}} = OIDC.reauth_decide(ticket, token, :approve)

      assert OIDC.reauth_callback(%{"state" => request.state, "code" => good}) ==
               {:error, :not_pending}
    end
  end

  describe "the person's answer" do
    test "an approval from the person's own session confirms the record, and the change goes ahead",
         %{ctx: ctx, subject: subject, token: token} do
      {secret, id} = asked!(ctx)
      {held, _request} = verified!(ctx, subject, id)

      assert {:ok, %{ref: ^id, state: "confirmed"}} =
               OIDC.reauth_decide(held.ticket, token, :approve)

      assert record(ctx, id).proof == "oidc_reauth"

      # The ref the page and the stream name repeats nothing; the asking
      # request's secret does.
      assert {:error, {:confirmation_required, _}} =
               Sanctum.Consent.Authz.confirm(
                 %{ctx | confirmation_id: id},
                 :credential_entry,
                 change()
               )

      assert Sanctum.Consent.Authz.confirm(
               %{ctx | confirmation_id: secret},
               :credential_entry,
               change()
             ) ==
               :ok

      # The ticket was spent.
      assert OIDC.reauth_decide(held.ticket, token, :approve) == {:error, :reauth_refused}
    end

    test "a decline confirms nothing, and spends the proof", %{
      ctx: ctx,
      subject: subject,
      token: token
    } do
      id = opened!(ctx)
      {held, _request} = verified!(ctx, subject, id)

      assert OIDC.reauth_decide(held.ticket, token, :decline) == {:ok, :declined}
      assert OIDC.reauth_decide(held.ticket, token, :approve) == {:error, :reauth_refused}
      assert record(ctx, id).state == "pending"
    end

    test "another person's session, or none, confirms nothing", %{
      ctx: ctx,
      subject: subject,
      token: own
    } do
      %{token: someone} = seated!()

      for token <- [someone, nil, "", "not-a-session"] do
        id = opened!(ctx, change("key-#{System.unique_integer([:positive])}"))
        {held, _request} = verified!(ctx, subject, id)

        assert OIDC.reauth_decide(held.ticket, token, :approve) == {:error, :another_person}
        assert record(ctx, id).state == "pending"

        # Spent on the refusal: the person's own session cannot reuse it.
        assert OIDC.reauth_decide(held.ticket, own, :approve) ==
                 {:error, :reauth_refused}
      end
    end

    test "a record asked for again since the login confirms nothing", %{
      ctx: ctx,
      subject: subject,
      token: token
    } do
      id = opened!(ctx)
      {held, _request} = verified!(ctx, subject, id)

      # A new re-authentication replaced the nonce the held login answered.
      _again = begun!(ctx, id)

      assert OIDC.reauth_decide(held.ticket, token, :approve) == {:error, :reauth_refused}
      assert OIDC.reauth_decide("never-issued", token, :approve) == {:error, :reauth_refused}
      assert record(ctx, id).state == "pending"
    end
  end

  # ---------------------------------------------------------------------------
  # Adding a device: a re-authentication a paired device began
  # ---------------------------------------------------------------------------

  # Asked by `ctx`, proven by a re-authentication `prover` began and the
  # person approved from their own session: the record's secret.
  defp reauth_confirmed!(ctx, prover, subject, token, change) do
    {:error, {:confirmation_required, %{id: secret}}} =
      Sanctum.Consent.Authz.check(%{ctx | confirmation_id: nil}, :device_pairing, change)

    ref = Prima.Confirmation.ref(secret)
    {held, _request} = verified!(prover, subject, ref)
    assert {:ok, %{state: "confirmed"}} = OIDC.reauth_decide(held.ticket, token, :approve)
    secret
  end

  defp pairing_change(digest), do: Sanctum.Pairing.invitation_change(digest)

  # The glass's two calls under the invitation, with the key it made.
  defp complete!(secret, {device_key, private}) do
    glass = Context.build(%{authenticated: false, client_ip: "198.51.100.30"})

    {:ok, %{challenge: challenge}} =
      Sanctum.Pairing.complete(glass, secret, %{device_key: device_key})

    {:ok, paired} =
      Sanctum.Pairing.complete(glass, secret, %{
        device_key: device_key,
        proof: Prima.DeviceCert.Proof.encode(Prima.DeviceCert.Proof.sign(challenge, private))
      })

    paired
  end

  # The person's first device, paired on a re-authentication from their
  # session while they hold no passkey and no device, and the context its
  # channel mints from a connect proof.
  defp first_device!(%{ctx: ctx, subject: subject, token: token}) do
    {device_key, private} = key = :crypto.generate_key(:eddsa, :ed25519)
    digest = Prima.Device.key_digest(device_key)
    secret = reauth_confirmed!(ctx, ctx, subject, token, pairing_change(digest))

    {:ok, invitation} =
      Sanctum.Pairing.begin(%{ctx | confirmation_id: secret}, %{"key_digest" => digest})

    paired = complete!(invitation.invitation_secret, key)
    certificate = paired.certificate

    {:ok, challenge} =
      Prima.DeviceCert.Challenge.new(
        purpose: :connect,
        home: certificate.audience,
        athanor: certificate.athanor,
        client_id: paired.client_id,
        device_key: device_key,
        nonce: :crypto.strong_rand_bytes(Prima.DeviceCert.Challenge.nonce_bytes()),
        now: System.system_time(:millisecond)
      )

    {:ok, device_ctx} =
      Sanctum.DeviceCerts.verify_connect(
        %{client_id: paired.client_id, certificate: certificate, source: "198.51.100.30"},
        Prima.DeviceCert.Proof.sign(challenge, private),
        challenge
      )

    %{client_id: paired.client_id, ctx: device_ctx}
  end

  describe "a re-authentication begun from a paired device" do
    test "confirms as that device: a device it confirmed is added, and the invitation names it",
         %{ctx: ctx, subject: subject, token: token} = seated do
      device = first_device!(seated)
      {device_key, _private} = key = :crypto.generate_key(:eddsa, :ed25519)
      digest = Prima.Device.key_digest(device_key)

      secret = reauth_confirmed!(ctx, device.ctx, subject, token, pairing_change(digest))
      row = record(ctx, Prima.Confirmation.ref(secret))
      assert {row.proof, row.confirmed_client_id} == {"oidc_reauth", device.client_id}

      assert {:ok, invitation} =
               Sanctum.Pairing.begin(%{ctx | confirmation_id: secret}, %{"key_digest" => digest})

      assert %{confirmer_kind: "device", confirmer_id: confirmer} =
               Arca.Repo.get_by!(Arca.Schemas.PairingInvitation,
                 secret_hash: Prima.Digest.sha256(invitation.invitation_secret)
               )

      assert confirmer == device.client_id
      assert %{client_id: _} = complete!(invitation.invitation_secret, key)
    end

    test "its state names the device; one begun from a session names none",
         %{ctx: ctx} = seated do
      device = first_device!(seated)
      ref = opened!(ctx)

      {_url, from_device} = begun!(device.ctx, ref)
      {_url, from_session} = begun!(ctx, ref)

      decoded = fn state ->
        [payload, _mac] = String.split(state, ".")
        payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
      end

      assert %{"d" => client_id} = decoded.(from_device.state)
      assert client_id == device.client_id
      refute Map.has_key?(decoded.(from_session.state), "d")
    end

    test "from a session that names no client, a re-authentication adds no device once one is paired",
         %{ctx: ctx, subject: subject, token: token} = seated do
      _device = first_device!(seated)
      {device_key, _private} = :crypto.generate_key(:eddsa, :ed25519)
      digest = Prima.Device.key_digest(device_key)

      secret = reauth_confirmed!(ctx, ctx, subject, token, pairing_change(digest))
      assert record(ctx, Prima.Confirmation.ref(secret)).confirmed_client_id == nil

      assert Sanctum.Pairing.begin(%{ctx | confirmation_id: secret}, %{"key_digest" => digest}) ==
               {:error, Sanctum.Pairing.addition_refusal()}
    end

    test "a device's state replayed against a later attempt begun from a session confirms nothing",
         %{ctx: ctx, subject: subject, token: token} = seated do
      device = first_device!(seated)
      digest = Prima.Device.key_digest(elem(:crypto.generate_key(:eddsa, :ed25519), 0))

      {:error, {:confirmation_required, %{id: secret}}} =
        Sanctum.Consent.Authz.check(ctx, :device_pairing, pairing_change(digest))

      ref = Prima.Confirmation.ref(secret)
      {_url, from_device} = begun!(device.ctx, ref)
      {_url, from_session} = begun!(ctx, ref)
      refute from_device.nonce == from_session.nonce
      refute from_device.pkce_verifier == from_session.pkce_verifier

      # The device's state, read from its authorization URL, beside the
      # code of the later login the session began: the record's nonce is
      # the later attempt's, so the device's state names an attempt that no
      # longer stands, and nothing is held to approve.
      assert OIDC.reauth_callback(%{
               "state" => from_device.state,
               "code" => code(claims(from_session, subject))
             }) == {:error, :reauth_refused}

      row = record(ctx, ref)
      assert {row.state, row.confirmed_client_id} == {"pending", nil}

      # The session's own attempt confirms, given on no device, and adds
      # nothing once a device is paired.
      {:ok, %{ticket: ticket}} =
        OIDC.reauth_callback(%{
          "state" => from_session.state,
          "code" => code(claims(from_session, subject))
        })

      assert {:ok, %{state: "confirmed"}} = OIDC.reauth_decide(ticket, token, :approve)
      assert record(ctx, ref).confirmed_client_id == nil

      assert Sanctum.Pairing.begin(%{ctx | confirmation_id: secret}, %{"key_digest" => digest}) ==
               {:error, Sanctum.Pairing.addition_refusal()}
    end

    test "a device revoked between its login and the person's answer confirms nothing",
         %{ctx: ctx, subject: subject, token: token} = seated do
      device = first_device!(seated)
      digest = Prima.Device.key_digest(elem(:crypto.generate_key(:eddsa, :ed25519), 0))

      {:error, {:confirmation_required, %{id: secret}}} =
        Sanctum.Consent.Authz.check(ctx, :device_pairing, pairing_change(digest))

      ref = Prima.Confirmation.ref(secret)
      {held, _request} = verified!(device.ctx, subject, ref)
      {:ok, _revoked} = Arca.PairedClients.revoke(Context.actor(ctx), device.client_id)

      assert OIDC.reauth_decide(held.ticket, token, :approve) == {:error, :revoked}
      assert record(ctx, ref).state == "pending"
    end
  end

  describe "GET and POST /auth/oidcc/reauth" do
    # The issuer's redirect, in a browser holding `token`'s session.
    defp called_back(conn, ctx, subject, token) do
      id = opened!(ctx)
      {_url, request} = begun!(ctx, id)

      conn =
        conn
        |> browser(token)
        |> get("/auth/oidcc/reauth", %{
          "state" => request.state,
          "code" => code(claims(request, subject))
        })

      {conn, id}
    end

    test "the callback shows what it would confirm and asks, confirming nothing", %{
      conn: conn,
      ctx: ctx,
      subject: subject,
      token: token
    } do
      {conn, id} = called_back(conn, ctx, subject, token)
      html = html_response(conn, 200)

      assert html =~ "Confirm this change?"
      assert html =~ "vault.create"
      assert html =~ "prod-key"
      refute html =~ "sk-secret"
      assert html =~ ~s(name="decision" value="approve")
      assert html =~ ~s(name="decision" value="decline")
      assert html =~ ~s(name="_csrf_token")

      # The held proof's ticket rides the cookie session, never the page.
      ticket = get_session(conn, "oidc_reauth_ticket")
      assert is_binary(ticket)
      refute html =~ ticket
      assert record(ctx, id).state == "pending"
    end

    test "the person's approval confirms and goes back to the console", %{
      conn: conn,
      ctx: ctx,
      subject: subject,
      token: token
    } do
      {conn, id} = called_back(conn, ctx, subject, token)
      conn = post(conn, "/auth/oidcc/reauth", %{"decision" => "approve"})

      assert redirected_to(conn) == "/"
      assert record(ctx, id).state == "confirmed"
      assert record(ctx, id).proof == "oidc_reauth"
    end

    test "a decline confirms nothing", %{conn: conn, ctx: ctx, subject: subject, token: token} do
      {conn, id} = called_back(conn, ctx, subject, token)
      conn = post(conn, "/auth/oidcc/reauth", %{"decision" => "decline"})

      assert html_response(conn, 200) =~ "You declined"
      assert record(ctx, id).state == "pending"

      # The proof went with the answer: approving after confirms nothing.
      conn = post(conn, "/auth/oidcc/reauth", %{"decision" => "approve"})
      assert html_response(conn, 409) =~ "Nothing was confirmed"
      assert record(ctx, id).state == "pending"
    end

    test "a browser signed in as another person confirms nothing", %{
      conn: conn,
      ctx: ctx,
      subject: subject
    } do
      %{token: someone} = seated!()
      {conn, id} = called_back(conn, ctx, subject, someone)
      conn = post(conn, "/auth/oidcc/reauth", %{"decision" => "approve"})

      assert html_response(conn, 403) =~ "not signed in here as the person who asked"
      assert record(ctx, id).state == "pending"
    end

    test "a browser with no session confirms nothing", %{conn: conn, ctx: ctx, subject: subject} do
      {conn, id} = called_back(conn, ctx, subject, nil)
      conn = post(conn, "/auth/oidcc/reauth", %{"decision" => "approve"})

      assert html_response(conn, 403) =~ "not signed in here as the person who asked"
      assert record(ctx, id).state == "pending"
    end

    test "an answer without the page's CSRF token is refused", %{
      conn: conn,
      ctx: ctx,
      subject: subject,
      token: token
    } do
      {conn, id} = called_back(conn, ctx, subject, token)

      # The browser pipeline guards the POST; the test connection's own
      # skip of that guard is turned off, as a real browser has none.
      conn =
        conn
        |> recycle()
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)

      assert_error_sent 403, fn ->
        post(conn, "/auth/oidcc/reauth", %{"decision" => "approve"})
      end

      assert record(ctx, id).state == "pending"
    end

    test "a refused answer is a page saying so, and confirms nothing", %{conn: conn, ctx: ctx} do
      id = opened!(ctx)
      {_url, request} = begun!(ctx, id)

      conn = get(conn, "/auth/oidcc/reauth", %{"state" => request.state, "code" => code(%{})})

      assert html_response(conn, 401) =~ "did not confirm"
      assert record(ctx, id).state == "pending"
    end
  end
end
