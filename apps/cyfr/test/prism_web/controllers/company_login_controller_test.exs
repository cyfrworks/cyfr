# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.CompanyLoginControllerTest do
  @moduledoc """
  The company sign-in's start and callback (`PrismWeb.AuthController`),
  at a CYFR that requires a company sign-in through its OpenID Connect
  issuer.

  The start, posted from the company page with the CSRF token the page
  carries, under a session refused for the company sign-in alone, answers
  `303` to the issuer's authorization endpoint for an ordinary login: the
  company callback as its redirect URI, a state, a nonce and a PKCE
  challenge, and neither `prompt=login` nor `max_age`. The callback with
  that state and a code whose claims carry the issuer, a subject and the
  nonce binds the person, who then stands, and sends the browser to `/`.
  A session that stands, or a CYFR that requires no company sign-in,
  starts nothing and goes to `/`; no session goes to `/login`; a callback
  for no attempt, or for a subject bound to another person, goes back to
  the company page naming what went wrong, and binds nothing.

  The issuer here is a stand-in for the token exchange alone
  (`:sanctum, :oidc_reauth_client`): it answers the claims a test encodes
  into the code, as a validated ID token would carry them. The
  authorization URL is the real one (`Sanctum.Auth.OIDC.Oidcc`, through
  `Oidcc`), built against the issuer's configuration as the `:cyfr_oidc`
  worker holds it.
  """

  # Installs the company sign-in's settings and the issuer, which are
  # application environment, and the `:cyfr_oidc` worker, a named process.
  use CyfrWeb.ConnCase, async: false

  alias Sanctum.Auth.OIDC
  alias Sanctum.Tenancy.Athanors

  @issuer "https://idp.example.com"

  defmodule ProviderConfiguration do
    @moduledoc false

    # The issuer's configuration as the `:cyfr_oidc` worker
    # `ueberauth_oidcc` starts holds it once it read the issuer's discovery
    # document: decoded here from such a document, with no network.
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
    keys = [
      {:sanctum, :company_login},
      {:sanctum, :oidc_issuer},
      {:sanctum, :oidc_reauth_client},
      {:ueberauth, Ueberauth}
    ]

    previous = Map.new(keys, fn {app, key} -> {{app, key}, Application.fetch_env(app, key)} end)

    on_exit(fn ->
      for {{app, key}, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end
    end)

    Application.put_env(:sanctum, :oidc_issuer, @issuer)
    Application.put_env(:sanctum, :oidc_reauth_client, Issuer)

    Application.put_env(:ueberauth, Ueberauth,
      providers: [
        oidcc:
          {Ueberauth.Strategy.Oidcc, issuer: :cyfr_oidc, client_id: "cid", client_secret: "csec"}
      ]
    )

    Application.put_env(:sanctum, :company_login, %{mode: :join, days: nil, issuer: :oidc})
    start_supervised!({ProviderConfiguration, @issuer})
    :ok
  end

  # A person seated in a group of their own, and their session's token.
  defp person! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|company-#{n}",
        provider: "github",
        email: "company#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Company #{n}")

    ctx =
      Sanctum.Context.build(
        user_id: user.id,
        email: user.email,
        provider: "github",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(ctx)
    %{user_id: user.id, token: session.token}
  end

  # A browser whose cookie session holds `token`, or none.
  defp browser(conn, nil), do: Plug.Test.init_test_session(conn, %{})

  defp browser(conn, token),
    do: Plug.Test.init_test_session(conn, %{CyfrWeb.SignInResponse.session_key() => token})

  defp configuration, do: Jason.encode!(["oidc", @issuer, "cid"])

  # `user_id`'s company sign-in as `subject`, under the configuration this
  # CYFR names.
  defp bound!(user_id, subject) do
    assert {:ok, :bound} =
             Arca.CompanyAuthorizations.bind(
               Prima.Actor.system(),
               %{user_id: user_id, configuration: configuration(), subject: subject},
               verify: fn -> :ok end
             )

    :ok
  end

  defp code(claims), do: Base.url_encode64(Jason.encode!(claims), padding: false)

  defp subject, do: "sub-#{System.unique_integer([:positive])}"

  # The company page under `token`'s session, then its start posted with
  # the CSRF token the page's start carries, the test connection's own
  # skip of that check turned off, as a real browser has none. Answers the
  # start's response and the request the issuer's URL was built for.
  defp started!(conn, token) do
    page = conn |> browser(token) |> get(~p"/company-login")
    html = html_response(page, 200)

    [start] = Regex.run(~r/<a\b[^>]*data-test="company-login-start"[^>]*>/, html)
    [_, csrf] = Regex.run(~r/data-csrf="([^"]+)"/, start)

    started =
      page
      |> recycle()
      |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
      |> post(~p"/auth/company", %{"_csrf_token" => csrf})

    assert_received {:authorize, request}
    {started, request}
  end

  defp standing(user_id), do: Sanctum.CompanyLogin.standing(user_id)

  describe "the start" do
    test "answers 303 to the issuer for an ordinary login, with the company callback, a state, a nonce and a PKCE challenge",
         %{conn: conn} do
      %{token: token} = person!()
      {started, request} = started!(conn, token)

      assert started.status == 303
      uri = URI.parse(redirected_to(started, 303))
      query = URI.decode_query(uri.query)

      assert %URI{scheme: "https", host: "idp.example.com", path: "/authorize"} = uri
      assert query["response_type"] == "code"
      assert query["client_id"] == "cid"
      assert query["redirect_uri"] == Sanctum.Person.home() <> "/auth/company/callback"
      assert query["redirect_uri"] == request.redirect_uri
      assert is_binary(query["state"]) and query["state"] == request.state
      assert is_binary(query["nonce"]) and query["nonce"] == request.nonce
      assert query["code_challenge_method"] == "S256"

      assert query["code_challenge"] ==
               Base.url_encode64(:crypto.hash(:sha256, request.pkce_verifier), padding: false)

      refute Map.has_key?(query, "prompt"), "the company's login is not forced fresh"
      refute Map.has_key?(query, "max_age"), "the company's login is not forced fresh"
    end

    test "under a session that stands opens nothing and goes to /", %{conn: conn} do
      %{user_id: user_id, token: token} = person!()
      bound!(user_id, subject())

      started = conn |> browser(token) |> post(~p"/auth/company")

      assert redirected_to(started) == "/"
      refute_received {:authorize, _request}
    end

    test "with no session goes to /login", %{conn: conn} do
      started = conn |> browser(nil) |> post(~p"/auth/company")

      assert redirected_to(started) == "/login"
      refute_received {:authorize, _request}
    end

    test "where no company sign-in is required goes to /", %{conn: conn} do
      Application.put_env(:sanctum, :company_login, %{mode: :off, days: nil, issuer: :oidc})
      %{token: token} = person!()

      started = conn |> browser(token) |> post(~p"/auth/company")

      assert redirected_to(started) == "/"
      refute_received {:authorize, _request}
    end
  end

  describe "the callback" do
    test "with the attempt's state and the issuer's claims binds the person, who then stands",
         %{conn: conn} do
      %{user_id: user_id, token: token} = person!()
      {_started, request} = started!(conn, token)
      assert {:error, :company_login_required} = standing(user_id)

      claims = %{"iss" => @issuer, "sub" => subject(), "nonce" => request.nonce}

      called_back =
        build_conn()
        |> browser(token)
        |> get(~p"/auth/company/callback", %{"state" => request.state, "code" => code(claims)})

      assert redirected_to(called_back) == "/"
      assert_received {:redeem, %{nonce: nonce, pkce_verifier: verifier}}
      assert {nonce, verifier} == {request.nonce, request.pkce_verifier}

      assert :ok = standing(user_id)

      assert {:ok, %Sanctum.Context{user_id: ^user_id}} =
               Sanctum.Caller.establish(token, refresh: false)

      assert {:ok, %{configuration: stored, subject: sub}} =
               Arca.CompanyAuthorizations.get(Prima.Actor.system(), user_id)

      assert {stored, sub} == {configuration(), claims["sub"]}
    end

    test "for a state no attempt holds goes back to the company page, binding nothing",
         %{conn: conn} do
      %{user_id: user_id, token: token} = person!()

      called_back =
        conn
        |> browser(token)
        |> get(~p"/auth/company/callback", %{"state" => "no-such-state", "code" => code(%{})})

      assert redirected_to(called_back) == "/company-login?error=refused"
      refute_received {:redeem, _request}
      assert {:error, :company_login_required} = standing(user_id)
    end

    test "for a subject another person is bound to goes back to the company page, binding nothing",
         %{conn: conn} do
      %{user_id: someone} = person!()
      taken = subject()
      bound!(someone, taken)

      %{user_id: user_id, token: token} = person!()
      {_started, request} = started!(conn, token)
      claims = %{"iss" => @issuer, "sub" => taken, "nonce" => request.nonce}

      called_back =
        build_conn()
        |> browser(token)
        |> get(~p"/auth/company/callback", %{"state" => request.state, "code" => code(claims)})

      assert redirected_to(called_back) == "/company-login?error=subject_bound"
      assert {:error, :company_login_required} = standing(user_id)
      assert {:error, :not_found} = Arca.CompanyAuthorizations.get(Prima.Actor.system(), user_id)

      assert {:ok, %{subject: ^taken}} =
               Arca.CompanyAuthorizations.get(Prima.Actor.system(), someone)
    end
  end
end
