# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.CompanyLoginTest do
  @moduledoc """
  The company sign-in a CYFR may require of every person
  (`Sanctum.CompanyLogin`): the standing condition, and the sign-in that
  meets it through the OpenID Connect issuer.

  `standing/1` reads nothing with the mode off. Otherwise a person stands
  on their row under the current configuration (the issuer and client id,
  or the WorkOS organization through any of its connections), within the
  days under `renew`; a principal that is not a person is held to
  nothing. A configuration change stops every row standing until the
  person signs in again, and turning the mode off keeps the rows.

  `Sanctum.Caller` holds each of its six standing paths (a session, an
  API key and a paired device, at establishment and at revalidation) and
  a derived credential's standing to the condition, last, so any other
  refusal is answered before it, and a refusal is never memoized.
  `held/1` answers the owner of a session refused for the condition and
  nothing else.

  `start/1` asks the issuer for an ordinary login carrying the attempt's
  state, nonce and PKCE verifier; `complete/2` binds the subject the
  token names, or refreshes the binding. A refused callback binds and
  refreshes nothing, and an attempt it found is spent. A revocation, a
  denial or a configuration change that commits during the code exchange
  is read by the binding transaction, and a process killed during the
  exchange leaves the attempt spent and nothing bound.

  The issuer is a stand-in for the code exchange alone
  (`:sanctum, :oidc_reauth_client`). Its authorization URL is `Oidcc`'s
  own, built against an issuer configuration held as the `:cyfr_oidc`
  worker holds it; its exchange answers what the test wrote into the
  code: the ID token's claims, an issuer that cannot be reached, or an
  answer held until the test releases it.
  """

  # The company sign-in's settings, the issuer and its client are the
  # application's environment: one case at a time.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{CompanyAuthorization, CompanyLoginAttempt}
  alias Arca.Test.QueryCounter
  alias Prima.DeviceCert.Proof
  alias Sanctum.{Caller, CompanyLogin, Context, Pairing}
  alias Sanctum.Tenancy.{Athanors, Users}

  @issuer "https://idp.example.com"
  @oidc ~s(["oidc","https://idp.example.com","cid"])
  @source "198.51.100.7"

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
      Sanctum.Auth.OIDC.Oidcc.authorize_url(request)
    end

    # What the test wrote into the code (`code/2`): the process to tell,
    # whether to hold the exchange until that process releases it, and
    # the answer, as a validated ID token's claims or a refusal.
    def redeem(code, request) do
      {test, hold?, answer} =
        code |> Base.url_decode64!(padding: false) |> :erlang.binary_to_term([:safe])

      send(test, {:redeem, request})

      if hold? do
        send(test, {:held, self()})

        receive do
          :release -> answer
        after
          30_000 -> {:error, :unavailable}
        end
      else
        answer
      end
    end
  end

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    put_env!(:sanctum, :company_login, %{mode: :off, days: nil, issuer: nil})
    put_env!(:sanctum, :oidc_issuer, @issuer)
    put_env!(:sanctum, :oidc_reauth_client, Issuer)
    client!("cid")
    start_supervised!({ProviderConfiguration, @issuer})

    seated!()
  end

  # ---------------------------------------------------------------------------
  # Settings
  # ---------------------------------------------------------------------------

  # Every change to the environment is restored, the restore registered
  # before the change; a key changed twice in one case is restored to the
  # value before the first, since `on_exit` callbacks run last first.
  defp put_env!(app, key, value) do
    prior = Application.fetch_env(app, key)
    on_exit(fn -> restore(app, key, prior) end)
    Application.put_env(app, key, value)
  end

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)

  defp require!(mode, days \\ nil, issuer \\ :oidc),
    do: put_env!(:sanctum, :company_login, %{mode: mode, days: days, issuer: issuer})

  # The `oidcc` provider's registration: the client id a binding is made
  # under.
  defp client!(client_id) do
    put_env!(:ueberauth, Ueberauth,
      providers: [
        oidcc:
          {Ueberauth.Strategy.Oidcc,
           issuer: :cyfr_oidc, client_id: client_id, client_secret: "csec"}
      ]
    )
  end

  # The establish memo on, and what it kept dropped after the case.
  defp memo! do
    on_exit(fn -> Arca.Cache.delete_match({:established, :_, :_}) end)
    put_env!(:sanctum, :caller_memo_ttl_ms, 60_000)
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # A person seated in a group of their own, a session of theirs there,
  # and the context it establishes, all made while no company sign-in is
  # required.
  defp seated! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|company-#{n}",
        provider: "github",
        email: "company#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Company #{n}")
    token = session!(user, athanor)
    {:ok, ctx} = Caller.establish({:session, token}, focus: athanor.id, refresh: false)
    %{user: user, athanor: athanor, token: token, ctx: ctx}
  end

  defp session!(user, athanor) do
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
    session.token
  end

  # An API key the person makes from their session: the session's
  # context, the key's name, the raw key and the context it establishes.
  defp key!(session_ctx) do
    name = "company-#{System.unique_integer([:positive])}"
    {:ok, %{api_key: raw}} = Sanctum.TestContext.create_key(session_ctx, %{name: name})
    {:ok, key_ctx} = Caller.establish({:api_key, raw})
    %{issuer: session_ctx, name: name, raw: raw, ctx: key_ctx}
  end

  # A device paired through the ceremony under the person's session, and
  # what `Sanctum.DeviceCerts` hands `Caller.establish_device/2` once it
  # verified it: the certificate and the rows it read.
  defp device!(session_ctx) do
    on_exit(fn -> Prima.Test.RateLimiter.reset!() end)
    Prima.Test.RateLimiter.reset!()

    {device_key, private} = :crypto.generate_key(:eddsa, :ed25519)
    digest = Prima.Device.key_digest(device_key)

    {:ok, invitation} =
      session_ctx
      |> Sanctum.TestContext.confirmed(:device_pairing, Pairing.invitation_change(digest))
      |> Pairing.begin(%{"key_digest" => digest})

    glass = Context.build(%{authenticated: false, client_ip: @source})
    submission = %{device_key: device_key}

    {:ok, %{challenge: challenge}} =
      Pairing.complete(glass, invitation.invitation_secret, submission)

    {:ok, %{client_id: client_id, certificate: certificate}} =
      Pairing.complete(
        glass,
        invitation.invitation_secret,
        Map.put(submission, :proof, Proof.encode(Proof.sign(challenge, private)))
      )

    user_id = certificate.subject.user_id

    {:ok, client} =
      Sanctum.DeviceCerts.paired_client(certificate.athanor, user_id, client_id)

    {:ok, standing} = Sanctum.DeviceCerts.standing(user_id, certificate.athanor)

    %{
      certificate: certificate,
      client: client,
      user: standing.user,
      athanor: standing.athanor,
      seat: standing.seat,
      platform_admin: standing.platform_admin
    }
  end

  # A binding written as a company sign-in writes it, with nothing to
  # verify.
  defp bind!(user_id, configuration \\ @oidc, subject \\ "sub-1") do
    {:ok, _bound_or_refreshed} =
      Arca.Test.CompanyLogin.bind(user_id, configuration, subject)

    :ok
  end

  # The person's company authorization row as stored, or nil.
  defp authorization(user_id), do: Arca.Repo.get(CompanyAuthorization, user_id)

  # The binding given `seconds` ago; answers when.
  defp lapse!(user_id, seconds) do
    at = DateTime.add(DateTime.utc_now(), -seconds, :second)

    {1, _} =
      Arca.Repo.update_all(from(c in CompanyAuthorization, where: c.user_id == ^user_id),
        set: [authorized_at: at]
      )

    at
  end

  defp attempt!(user_id),
    do: Arca.Repo.one!(from(a in CompanyLoginAttempt, where: a.user_id == ^user_id))

  # The person's row marked denied with their sessions left in place, so
  # a session of theirs is refused for a reason other than the company
  # sign-in. `Users.deny/1` also deletes the sessions, which the cases of
  # a revoked session cover.
  defp denied_in_place!(user_id) do
    {1, _} =
      Arca.Repo.update_all(from(u in Arca.Schemas.User, where: u.id == ^user_id),
        set: [status: "denied"]
      )

    :ok
  end

  # ---------------------------------------------------------------------------
  # The sign-in
  # ---------------------------------------------------------------------------

  # Begin a company sign-in for the session `token`, and answer the
  # request the issuer was sent.
  defp begun!(token) do
    assert {:ok, url} = CompanyLogin.start(token)
    assert_received {:authorize, request}
    Map.put(request, :url, url)
  end

  # A code whose exchange answers `answer` to this process, at once or
  # once released.
  defp code(answer, hold?) do
    {self(), hold?, answer} |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)
  end

  defp claims(request, subject, overrides \\ %{}) do
    Map.merge(
      %{"iss" => @issuer, "sub" => subject, "aud" => "cid", "nonce" => request.nonce},
      overrides
    )
  end

  # The issuer's callback for `request`, its code answering `answer`.
  defp callback(request, answer, hold \\ :at_once),
    do: %{"state" => request.state, "code" => code(answer, hold == :hold)}

  # The callback for `request` whose token names `subject`.
  defp signed_in(request, subject), do: callback(request, {:ok, claims(request, subject)})

  # `complete/2` in a task whose exchange holds until it is released.
  defp exchanging!(params, token) do
    task = Task.async(fn -> CompanyLogin.complete(params, token) end)
    assert_receive {:held, exchange}, 5_000
    {task, exchange}
  end

  defp released({task, exchange}) do
    send(exchange, :release)
    Task.await(task, 15_000)
  end

  # The attempt answers no more: its state, with a code the issuer would
  # accept, is refused.
  defp assert_spent(request, token) do
    assert CompanyLogin.complete(signed_in(request, "sub-spent"), token) ==
             {:error, :attempt_invalid},
           "the attempt still answered"
  end

  # ---------------------------------------------------------------------------
  # standing/1
  # ---------------------------------------------------------------------------

  describe "standing/1" do
    test "with the mode off answers :ok and reads nothing", %{user: user} do
      assert QueryCounter.assert_queries(0, fn -> CompanyLogin.standing(user.id) end) == :ok

      # The same person once a sign-in is required: one read, by the
      # person's key, and no row to stand on.
      require!(:join)

      assert {{:error, :company_login_required}, %{total: 1, by_source: by_source}} =
               QueryCounter.count(fn -> CompanyLogin.standing(user.id) end)

      assert by_source == %{"company_authorizations" => 1}
    end

    test "join needs the person's row", %{user: user} do
      require!(:join)
      assert CompanyLogin.standing(user.id) == {:error, :company_login_required}

      bind!(user.id)
      assert CompanyLogin.standing(user.id) == :ok

      # Given a year ago, it still stands: join has no days.
      lapse!(user.id, 365 * 86_400)
      assert CompanyLogin.standing(user.id) == :ok
    end

    test "renew needs authorized_at within the days", %{user: user} do
      require!(:renew, 30)
      assert CompanyLogin.standing(user.id) == {:error, :company_login_required}

      bind!(user.id)
      assert CompanyLogin.standing(user.id) == :ok

      lapse!(user.id, 30 * 86_400 - 3_600)
      assert CompanyLogin.standing(user.id) == :ok, "a binding inside the days did not stand"

      lapse!(user.id, 30 * 86_400 + 60)

      assert CompanyLogin.standing(user.id) == {:error, :company_login_required},
             "a binding past the days stood"
    end

    test "a row under another issuer or client id does not stand", %{user: user} do
      require!(:join)

      for configuration <- [
            ~s(["oidc","https://other.example.com","cid"]),
            ~s(["oidc","https://idp.example.com","another-client"]),
            ~s(["workos","org_a","conn_1"])
          ] do
        bind!(user.id, configuration)

        assert CompanyLogin.standing(user.id) == {:error, :company_login_required},
               "a row under #{configuration} stood"
      end

      bind!(user.id, @oidc)
      assert CompanyLogin.standing(user.id) == :ok
    end

    test "under WorkOS a row stands for the configured organization, through any connection",
         %{user: user} do
      put_env!(:sanctum, :workos, %{
        client_id: "client_w",
        api_key: "sk_test_w",
        organization: "org_a"
      })

      require!(:join, nil, :workos)

      for configuration <- [~s(["workos","org_a","conn_1"]), ~s(["workos","org_a","conn_2"])] do
        bind!(user.id, configuration, "prof_1")
        assert CompanyLogin.standing(user.id) == :ok, "a row under #{configuration} did not stand"
      end

      for configuration <- [~s(["workos","org_b","conn_1"]), @oidc] do
        bind!(user.id, configuration, "prof_1")

        assert CompanyLogin.standing(user.id) == {:error, :company_login_required},
               "a row under #{configuration} stood"
      end
    end

    test "a principal that is not a person is held to nothing" do
      require!(:join)

      for principal <- ["system", "webhook:wh_1", "github|https://github.com|someone", nil] do
        assert QueryCounter.assert_queries(0, fn -> CompanyLogin.standing(principal) end) == :ok,
               "#{inspect(principal)} was held to the company sign-in"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The configuration
  # ---------------------------------------------------------------------------

  describe "the configuration" do
    test "a person bound under one client is refused under another until they sign in again",
         %{user: user, token: token} do
      require!(:join)
      bind!(user.id, @oidc, "sub-1")
      assert {:ok, %Context{}} = Caller.establish({:session, token}, refresh: false)

      client!("cid-b")
      assert CompanyLogin.standing(user.id) == {:error, :company_login_required}

      assert Caller.establish({:session, token}, refresh: false) ==
               {:error, :company_login_required}

      request = begun!(token)
      assert CompanyLogin.complete(signed_in(request, "sub-1"), token) == {:ok, :bound}

      assert %CompanyAuthorization{
               configuration: ~s(["oidc","https://idp.example.com","cid-b"]),
               subject: "sub-1"
             } = authorization(user.id)

      assert {:ok, %Context{}} = Caller.establish({:session, token}, refresh: false)
    end

    test "renew moved to off: standing passes and the row stays", %{user: user, token: token} do
      require!(:renew, 1)
      bind!(user.id)
      lapse!(user.id, 2 * 86_400)
      assert CompanyLogin.standing(user.id) == {:error, :company_login_required}
      row = authorization(user.id)

      require!(:off)
      assert CompanyLogin.standing(user.id) == :ok
      assert {:ok, %Context{}} = Caller.establish({:session, token}, refresh: false)
      assert authorization(user.id) == row, "turning the mode off changed the row"
    end
  end

  # ---------------------------------------------------------------------------
  # Sanctum.Caller's standing paths
  # ---------------------------------------------------------------------------

  describe "each standing path, called directly" do
    test "session establishment refuses without the row, and admits at once after binding",
         %{user: user, token: token} do
      memo!()
      require!(:join)

      assert Caller.establish({:session, token}, refresh: false) ==
               {:error, :company_login_required}

      bind!(user.id)

      # The refusal was never memoized: the next establish reads again.
      assert {:ok, %Context{user_id: user_id}} =
               Caller.establish({:session, token}, refresh: false)

      assert user_id == user.id

      # The memo is on: it keeps the admission, as it would have kept the
      # refusal had refusals been memoized.
      refute Arca.Cache.match({:established, :_, :_}) == [], "the memo kept nothing"
    end

    test "session revalidation", %{user: user, ctx: ctx} do
      require!(:join)
      assert Caller.revalidate_session(ctx) == {:error, :company_login_required}

      bind!(user.id)
      assert {:ok, %Context{auth_method: :oidc}} = Caller.revalidate_session(ctx)
    end

    test "API-key establishment", %{user: user, ctx: ctx} do
      key = key!(ctx)
      require!(:join)
      assert Caller.establish({:api_key, key.raw}) == {:error, :company_login_required}

      bind!(user.id)
      assert {:ok, %Context{auth_method: :api_key}} = Caller.establish({:api_key, key.raw})
    end

    test "API-key revalidation", %{user: user, ctx: ctx} do
      key = key!(ctx)
      require!(:join)
      assert Caller.revalidate_session(key.ctx) == {:error, :company_login_required}

      bind!(user.id)
      assert {:ok, %Context{auth_method: :api_key}} = Caller.revalidate_session(key.ctx)
    end

    test "device establishment", %{user: user, ctx: ctx} do
      device = device!(ctx)
      require!(:join)
      assert Caller.establish_device(device, []) == {:error, :company_login_required}

      bind!(user.id)
      assert {:ok, %Context{auth_method: :device}} = Caller.establish_device(device, [])
    end

    test "device revalidation", %{user: user, ctx: ctx} do
      {:ok, device_ctx} = ctx |> device!() |> Caller.establish_device([])
      require!(:join)
      assert Caller.revalidate_session(device_ctx) == {:error, :company_login_required}

      bind!(user.id)
      assert {:ok, %Context{auth_method: :device}} = Caller.revalidate_session(device_ctx)
    end

    test "a derived credential's standing", %{user: user, ctx: ctx} do
      claims =
        Map.merge(ctx.credential_binding, %{user_id: ctx.user_id, athanor_id: ctx.athanor_id})

      assert {:ok, _standing} = Caller.derived_standing(claims)
      require!(:join)
      assert Caller.derived_standing(claims) == {:error, :company_login_required}

      bind!(user.id)
      assert {:ok, _standing} = Caller.derived_standing(claims)
    end
  end

  describe "the condition is checked last" do
    test "on the session path a denied person is refused as denied", %{
      user: user,
      token: token,
      ctx: ctx
    } do
      require!(:join)

      assert Caller.establish({:session, token}, refresh: false) ==
               {:error, :company_login_required}

      assert Caller.revalidate_session(ctx) == {:error, :company_login_required}

      denied_in_place!(user.id)
      assert {:error, {:denied, %Context{}}} = Caller.establish({:session, token}, refresh: false)
      assert Caller.revalidate_session(ctx) == {:error, :not_standing}
    end

    test "on the key path a revoked key is refused as revoked", %{ctx: ctx} do
      key = key!(ctx)
      require!(:join)
      assert Caller.establish({:api_key, key.raw}) == {:error, :company_login_required}
      assert Caller.revalidate_session(key.ctx) == {:error, :company_login_required}

      :ok = Sanctum.ApiKey.revoke(key.issuer, key.name)
      assert Caller.establish({:api_key, key.raw}) == {:error, :revoked}
      assert Caller.revalidate_session(key.ctx) == {:error, :unauthenticated}
    end

    test "on the device path a revoked client is refused as unauthenticated", %{ctx: ctx} do
      device = device!(ctx)
      require!(:join)
      assert Caller.establish_device(device, []) == {:error, :company_login_required}

      assert Caller.establish_device(put_in(device.client.standing, "revoked"), []) ==
               {:error, :unauthenticated}
    end
  end

  # ---------------------------------------------------------------------------
  # held/1
  # ---------------------------------------------------------------------------

  describe "held/1" do
    test "answers the owner of a session refused for the company condition alone", %{
      user: user,
      token: token
    } do
      require!(:join)
      assert {:ok, %{user_id: user_id, session_hash: hash}} = CompanyLogin.held(token)
      assert user_id == user.id
      assert hash == Sanctum.Session.token_hash(token)
    end

    test "refuses a session that stands, and start/1 with it", %{user: user, token: token} do
      require!(:join)
      bind!(user.id)
      assert CompanyLogin.held(token) == {:error, :standing}
      assert CompanyLogin.start(token) == {:error, :standing}
    end

    test "answers any other refusal as it is", %{user: user, token: token} do
      require!(:join)
      assert CompanyLogin.held("cyfr_sess_unknown") == {:error, :unauthenticated}
      assert CompanyLogin.held(nil) == {:error, :unauthenticated}

      denied_in_place!(user.id)
      assert {:error, {:denied, %Context{}}} = CompanyLogin.held(token)
    end
  end

  # ---------------------------------------------------------------------------
  # A company sign-in
  # ---------------------------------------------------------------------------

  describe "a company sign-in" do
    # A later start replaces the earlier attempt, and the binding spends
    # its attempt under the person's lock: the replaced attempt's exchange,
    # answering after the replacement, binds nothing, and the later
    # attempt binds its own subject.
    test "an exchange from an attempt replaced by a newer start cannot bind first", %{
      user: user,
      token: token
    } do
      require!(:join)
      earlier = begun!(token)

      exchange =
        exchanging!(callback(earlier, {:ok, claims(earlier, "subject-earlier")}, :hold), token)

      later = begun!(token)
      old_answer = released(exchange)
      new_answer = CompanyLogin.complete(signed_in(later, "subject-later"), token)

      assert {old_answer, new_answer, authorization(user.id).subject} ==
               {{:error, :attempt_invalid}, {:ok, :bound}, "subject-later"}
    end

    test "start/1 asks the issuer for an ordinary login carrying the attempt", %{
      user: user,
      token: token
    } do
      require!(:join)
      request = begun!(token)
      attempt = attempt!(user.id)

      assert request.fresh == false
      assert is_binary(attempt.nonce) and request.nonce == attempt.nonce
      assert is_binary(attempt.pkce_verifier) and request.pkce_verifier == attempt.pkce_verifier
      assert String.ends_with?(request.redirect_uri, "/auth/company/callback")
      assert attempt.state_hash == :crypto.hash(:sha256, request.state)
      assert attempt.session_hash == Sanctum.Session.token_hash(token)
      assert attempt.consumed_at == nil

      uri = URI.parse(request.url)
      query = URI.decode_query(uri.query)

      assert %URI{scheme: "https", host: "idp.example.com", path: "/authorize"} = uri
      refute Map.has_key?(query, "prompt"), "the login was forced fresh"
      refute Map.has_key?(query, "max_age"), "the login was forced fresh"
      assert query["client_id"] == "cid"
      assert query["redirect_uri"] == request.redirect_uri
      assert query["state"] == request.state
      assert query["nonce"] == request.nonce

      assert query["code_challenge"] ==
               Base.url_encode64(:crypto.hash(:sha256, request.pkce_verifier), padding: false)
    end

    test "complete/2 binds the token's subject, and the person stands", %{
      user: user,
      token: token
    } do
      require!(:join)
      request = begun!(token)

      assert CompanyLogin.complete(signed_in(request, "sub-1"), token) == {:ok, :bound}

      # The exchange redeemed the code for this attempt.
      assert_received {:redeem, redeemed}
      assert redeemed.nonce == request.nonce
      assert redeemed.pkce_verifier == request.pkce_verifier
      assert redeemed.redirect_uri == request.redirect_uri

      assert %CompanyAuthorization{configuration: @oidc, subject: "sub-1"} =
               authorization(user.id)

      assert Arca.Repo.all(from(a in CompanyLoginAttempt, where: a.user_id == ^user.id)) == [],
             "the binding spent its attempt"

      assert {:ok, %Context{}} = Caller.establish({:session, token}, refresh: false)
    end

    test "a later company sign-in refreshes the binding", %{user: user, token: token} do
      require!(:renew, 30)
      request = begun!(token)
      assert CompanyLogin.complete(signed_in(request, "sub-1"), token) == {:ok, :bound}

      lapsed = lapse!(user.id, 31 * 86_400)

      assert Caller.establish({:session, token}, refresh: false) ==
               {:error, :company_login_required}

      request = begun!(token)
      assert CompanyLogin.complete(signed_in(request, "sub-1"), token) == {:ok, :refreshed}

      row = authorization(user.id)
      assert {row.configuration, row.subject} == {@oidc, "sub-1"}
      assert DateTime.compare(row.authorized_at, lapsed) == :gt, "authorized_at did not move"
      assert {:ok, %Context{}} = Caller.establish({:session, token}, refresh: false)
    end
  end

  # ---------------------------------------------------------------------------
  # A refused sign-in
  # ---------------------------------------------------------------------------

  describe "a refused sign-in binds nothing" do
    test "the issuer unreachable at the callback: the attempt is spent and the person starts again",
         %{user: user, token: token} do
      require!(:join)
      request = begun!(token)

      assert CompanyLogin.complete(callback(request, {:error, :unavailable}), token) ==
               {:error, :unavailable}

      assert authorization(user.id) == nil
      assert_spent(request, token)
      assert authorization(user.id) == nil
      assert {:ok, _url} = CompanyLogin.start(token)
    end

    test "a state that names no attempt", %{user: user, token: token} do
      require!(:join)
      request = begun!(token)
      params = %{signed_in(request, "sub-1") | "state" => "another-state"}

      assert CompanyLogin.complete(params, token) == {:error, :attempt_invalid}
      assert authorization(user.id) == nil
    end

    test "an expired attempt", %{user: user, token: token} do
      require!(:join)
      request = begun!(token)

      {1, _} =
        Arca.Repo.update_all(from(a in CompanyLoginAttempt, where: a.user_id == ^user.id),
          set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      assert CompanyLogin.complete(signed_in(request, "sub-1"), token) ==
               {:error, :attempt_invalid}

      assert authorization(user.id) == nil
    end

    test "a replayed callback", %{user: user, token: token} do
      require!(:join)
      request = begun!(token)
      params = signed_in(request, "sub-1")
      assert CompanyLogin.complete(params, token) == {:ok, :bound}
      bound = authorization(user.id)

      assert CompanyLogin.complete(params, token) == {:error, :attempt_invalid}
      assert authorization(user.id) == bound, "the replay refreshed the binding"
    end

    test "a callback presented with another session's token", %{
      user: user,
      athanor: athanor,
      token: token
    } do
      require!(:join)
      request = begun!(token)
      other = session!(user, athanor)

      assert CompanyLogin.complete(signed_in(request, "sub-1"), other) ==
               {:error, :attempt_invalid}

      assert authorization(user.id) == nil
    end

    test "a token whose nonce is not the attempt's", %{user: user, token: token} do
      require!(:join)
      request = begun!(token)
      answer = {:ok, claims(request, "sub-1", %{"nonce" => "another-nonce"})}

      assert CompanyLogin.complete(callback(request, answer), token) == {:error, :issuer_refused}
      assert authorization(user.id) == nil
      assert_spent(request, token)
    end

    test "a token from another issuer", %{user: user, token: token} do
      require!(:join)
      request = begun!(token)
      answer = {:ok, claims(request, "sub-1", %{"iss" => "https://other.example.com"})}

      assert CompanyLogin.complete(callback(request, answer), token) == {:error, :issuer_refused}
      assert authorization(user.id) == nil
      assert_spent(request, token)
    end

    test "a callback whose session was revoked", %{user: user, token: token} do
      require!(:join)
      request = begun!(token)
      :ok = Sanctum.Session.destroy(token)

      assert CompanyLogin.complete(signed_in(request, "sub-1"), token) ==
               {:error, :session_ended}

      assert authorization(user.id) == nil
      assert_spent(request, token)
    end

    test "a callback whose person is now refused for another reason", %{
      user: user,
      token: token
    } do
      require!(:join)
      request = begun!(token)
      denied_in_place!(user.id)

      assert CompanyLogin.complete(signed_in(request, "sub-1"), token) ==
               {:error, :session_ended}

      assert authorization(user.id) == nil
      assert_spent(request, token)
    end

    test "a subject another person holds under the current configuration", %{
      user: user,
      token: token
    } do
      %{user: other} = seated!()
      require!(:join)
      bind!(other.id, @oidc, "sub-shared")
      held = authorization(other.id)
      request = begun!(token)

      assert CompanyLogin.complete(signed_in(request, "sub-shared"), token) ==
               {:error, :company_subject_bound}

      assert authorization(user.id) == nil
      assert authorization(other.id) == held
    end

    test "a person bound to another subject under the current configuration", %{
      user: user,
      token: token
    } do
      require!(:renew, 30)
      bind!(user.id, @oidc, "sub-1")
      lapse!(user.id, 31 * 86_400)
      before = authorization(user.id)
      request = begun!(token)

      assert CompanyLogin.complete(signed_in(request, "sub-new"), token) ==
               {:error, :company_subject_bound}

      assert authorization(user.id) == before
    end
  end

  # ---------------------------------------------------------------------------
  # During the exchange
  # ---------------------------------------------------------------------------

  describe "during the exchange" do
    test "a session revoked binds nothing", %{user: user, token: token} do
      require!(:join)
      request = begun!(token)
      exchange = exchanging!(callback(request, {:ok, claims(request, "sub-1")}, :hold), token)

      :ok = Sanctum.Session.destroy(token)

      assert released(exchange) == {:error, :session_ended}
      assert authorization(user.id) == nil
    end

    test "a person denied binds nothing", %{user: user, token: token} do
      require!(:join)
      request = begun!(token)
      exchange = exchanging!(callback(request, {:ok, claims(request, "sub-1")}, :hold), token)

      {:ok, _denied} = Users.deny(user)

      assert released(exchange) == {:error, :session_ended}
      assert authorization(user.id) == nil
    end

    test "a session revoked leaves an earlier binding unrefreshed", %{user: user, token: token} do
      require!(:renew, 30)
      bind!(user.id, @oidc, "sub-1")
      lapse!(user.id, 31 * 86_400)
      before = authorization(user.id)
      request = begun!(token)
      exchange = exchanging!(callback(request, {:ok, claims(request, "sub-1")}, :hold), token)

      :ok = Sanctum.Session.destroy(token)

      assert released(exchange) == {:error, :session_ended}
      assert authorization(user.id) == before, "the binding was refreshed"
    end

    test "the configuration changed binds nothing", %{user: user, token: token} do
      require!(:join)
      request = begun!(token)
      exchange = exchanging!(callback(request, {:ok, claims(request, "sub-1")}, :hold), token)

      client!("cid-b")

      assert released(exchange) == {:error, :configuration_changed}
      assert authorization(user.id) == nil
    end

    test "the process killed binds nothing, its attempt is spent, and the person starts again",
         %{user: user, token: token} do
      require!(:join)
      request = begun!(token)
      params = callback(request, {:ok, claims(request, "sub-1")}, :hold)

      pid = spawn(fn -> CompanyLogin.complete(params, token) end)
      assert_receive {:held, ^pid}, 5_000
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000

      assert authorization(user.id) == nil
      assert %DateTime{} = attempt!(user.id).consumed_at
      assert_spent(request, token)

      request = begun!(token)
      assert CompanyLogin.complete(signed_in(request, "sub-1"), token) == {:ok, :bound}
    end
  end

  describe "with the mode off" do
    test "start/1 and complete/2 answer :not_required, and an open attempt binds nothing", %{
      user: user,
      token: token
    } do
      require!(:join)
      request = begun!(token)

      require!(:off)
      assert CompanyLogin.start(token) == {:error, :not_required}

      assert CompanyLogin.complete(signed_in(request, "sub-1"), token) ==
               {:error, :not_required}

      assert authorization(user.id) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # A remote person's head during the exchange
  # ---------------------------------------------------------------------------

  describe "a remote person's head past its freshness bound during the exchange" do
    alias Sanctum.Test.DirectoryServer

    # A scripted directory on loopback, its host listed as the operator's
    # private egress target and reached through the directory client's
    # seam, so the reads that pass no options (a session's mint, the
    # caller's freshness check) reach it. A directory found unreachable is
    # forgotten after the case.
    setup do
      tls = DirectoryServer.tls()
      on_exit(fn -> Arca.Cache.delete_match(Arca.Cache.Keys.match_identity_unreachable()) end)
      put_env!(:sanctum, :private_egress_targets, ["dir-a.test"])
      put_env!(:sanctum, :directory_client, DirectoryServer.opts(tls))
      %{directory: DirectoryServer.start!(tls)}
    end

    # The seated person made this CYFR's remote person of an identity the
    # directory serves, their head cached as verified now, and a session
    # of theirs minted bound to that head's key_epoch.
    defp remote_session!(%{user: user, athanor: athanor, directory: directory}) do
      identity = DirectoryServer.identity!(directory.dir, directory.url)
      :ok = DirectoryServer.remote_person!(user.id, identity)
      %{identifier: identity.identifier, token: session!(user, athanor)}
    end

    # The cached head's verification moved a day back, far past the bound;
    # answers it as stored.
    defp head_aged!(identifier) do
      {1, _} =
        Arca.Repo.update_all(
          from(h in Arca.Schemas.DirectoryHead, where: h.identifier == ^identifier),
          set: [verified_at: DateTime.add(DateTime.utc_now(), -86_400, :second)]
        )

      head_verified_at(identifier)
    end

    defp head_verified_at(identifier),
      do: Arca.Repo.get!(Arca.Schemas.DirectoryHead, identifier).verified_at

    test "a head read fresh from a reachable directory before the transaction binds, and the person stands",
         %{user: user} = context do
      %{identifier: identifier, token: token} = remote_session!(context)
      require!(:join)

      assert Caller.establish({:session, token}, refresh: false) ==
               {:error, :company_login_required}

      request = begun!(token)
      exchange = exchanging!(callback(request, {:ok, claims(request, "sub-1")}, :hold), token)

      aged = head_aged!(identifier)

      assert released(exchange) == {:ok, :bound}

      # The head was read again from the directory, outside the binding
      # transaction, whose own re-read sees the cache alone.
      assert DateTime.compare(head_verified_at(identifier), aged) == :gt,
             "the cached head was not refreshed"

      assert %CompanyAuthorization{configuration: @oidc, subject: "sub-1"} =
               authorization(user.id)

      assert {:ok, %Context{user_id: user_id}} =
               Caller.establish({:session, token}, refresh: false)

      assert user_id == user.id
    end

    test "a head its unreachable directory cannot refresh is unavailable: nothing bound, the attempt spent",
         %{user: user, directory: directory} = context do
      %{identifier: identifier, token: token} = remote_session!(context)
      require!(:join)
      request = begun!(token)
      exchange = exchanging!(callback(request, {:ok, claims(request, "sub-1")}, :hold), token)

      aged = head_aged!(identifier)
      DirectoryServer.Server.stop(directory.server)

      {answer, log} = ExUnit.CaptureLog.with_log(fn -> released(exchange) end)

      assert answer == {:error, :unavailable}
      assert log =~ "freshness bound", "the directory was not read before the transaction"
      assert head_verified_at(identifier) == aged, "the cached head moved"
      assert authorization(user.id) == nil
      assert %DateTime{} = attempt!(user.id).consumed_at
      assert_spent(request, token)
      assert authorization(user.id) == nil

      # A pause, not a sign-out: the session stays.
      assert {:ok, %Context{}} = Sanctum.Session.load(token)
    end
  end
end
