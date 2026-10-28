# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.WorkOSTest do
  @moduledoc """
  WorkOS's standalone single sign-on as the company's issuer, against a
  stub of its two endpoints (`Sanctum.Test.WorkOSStub`).

  `Sanctum.Auth.WorkOS` sends the browser to `/sso/authorize` with the
  client id, the redirect URI, `response_type=code`, the attempt's state
  and the configured organization, and nothing else. On the callback it
  posts the code, form-encoded with the API key as the client secret, to
  `/sso/token`: a profile of the configured organization answers that
  organization and the profile's connection as the configuration and the
  profile's `id` as the subject, never reading its email. A profile of
  another organization, the endpoint's refusal, an answer with no usable
  profile, an endpoint that cannot be reached and an unconfigured WorkOS
  are each refused.

  Through `Sanctum.CompanyLogin`, a session refused for the company
  condition alone signs in at WorkOS, is bound under
  `["workos", organization, connection]` and the profile's id, and
  stands. A row stands under the configured organization through any of
  its connections, and a change of organization makes every person bind
  again. A revocation that commits while the code is exchanged binds
  nothing, and an OpenID Connect issuer configured beside WorkOS is never
  asked.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Sanctum.Auth.WorkOS
  alias Sanctum.Caller
  alias Sanctum.CompanyLogin
  alias Sanctum.Context
  alias Sanctum.Test.WorkOSStub

  @client_id "client_01CYFRWORKOS"
  @api_key "sk_test_cyfr_workos_api_key"
  @organization "org_01CYFRCOMPANY"
  @elsewhere "org_01ELSEWHERE"
  @workos %{client_id: @client_id, api_key: @api_key, organization: @organization}
  @attempt %{
    redirect_uri: "https://cyfr.example/auth/company/callback",
    nonce: nil,
    pkce_verifier: nil
  }

  defmodule UnaskedOIDC do
    @moduledoc false

    # The OpenID Connect exchange (`:sanctum, :oidc_reauth_client`), which a
    # CYFR whose company issuer is WorkOS never asks.
    def authorize_url(_request),
      do: raise(ExUnit.AssertionError, message: "the OpenID Connect issuer was asked for its URL")

    def redeem(_code, _request),
      do:
        raise(ExUnit.AssertionError,
          message: "the OpenID Connect issuer was asked to redeem a code"
        )
  end

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    put_env!(:sanctum, :company_login, %{mode: :join, days: nil, issuer: :workos})
    put_env!(:sanctum, :workos, @workos)
    :ok
  end

  describe "authorize_url/2" do
    test "names the stub's /sso/authorize with exactly the five parameters" do
      %{url: base} = WorkOSStub.start!()

      assert {:ok, url} = WorkOS.authorize_url(@attempt, "the-attempt-state")
      uri = URI.parse(url)

      assert "#{uri.scheme}://#{uri.host}:#{uri.port}" == base
      assert uri.path == "/sso/authorize"

      assert pairs(uri.query) == [
               {"client_id", @client_id},
               {"organization", @organization},
               {"redirect_uri", @attempt.redirect_uri},
               {"response_type", "code"},
               {"state", "the-attempt-state"}
             ]
    end

    test "an unconfigured WorkOS has no URL" do
      put_env!(:sanctum, :workos, nil)

      assert WorkOS.authorize_url(@attempt, "the-attempt-state") == {:error, :unavailable}
    end
  end

  describe "complete/2" do
    test "posts the code, form-encoded with the API key as the client secret, to /sso/token" do
      profile = WorkOSStub.profile(%{"organization_id" => @organization})
      WorkOSStub.start!(fn _request -> WorkOSStub.token(profile) end)

      assert {:ok, _answer} = WorkOS.complete("wos_code_posted", @attempt)

      assert_receive {:workos_request,
                      %{
                        method: "POST",
                        path: "/sso/token",
                        query: "",
                        headers: headers,
                        body: body
                      }},
                     1_000

      assert {"content-type", "application/x-www-form-urlencoded"} in headers

      assert pairs(body) == [
               {"client_id", @client_id},
               {"client_secret", @api_key},
               {"code", "wos_code_posted"},
               {"grant_type", "authorization_code"}
             ]
    end

    test "a profile of the configured organization answers its connection and id, never its email" do
      profiles = %{
        "with_email" => WorkOSStub.profile(%{"organization_id" => @organization}),
        "null_email" => WorkOSStub.profile(%{"organization_id" => @organization, "email" => nil}),
        "no_email" =>
          WorkOSStub.profile(%{"organization_id" => @organization, "email" => :absent})
      }

      WorkOSStub.start!(fn request -> WorkOSStub.token(Map.fetch!(profiles, code(request))) end)

      for {code, profile} <- profiles do
        assert WorkOS.complete(code, @attempt) ==
                 {:ok,
                  %{
                    configuration: {:workos, @organization, profile["connection_id"]},
                    subject: profile["id"]
                  }},
               "the profile #{code} answers its organization, connection and id alone"
      end
    end

    test "a profile of another organization is refused" do
      profile = WorkOSStub.profile(%{"organization_id" => @elsewhere})
      WorkOSStub.start!(fn _request -> WorkOSStub.token(profile) end)

      assert WorkOS.complete("wos_code_elsewhere", @attempt) == {:error, :wrong_organization}
    end

    test "the token endpoint's 4xx is the issuer's refusal and its 5xx an issuer unavailable" do
      statuses = %{
        "code_400" => 400,
        "code_401" => 401,
        "code_422" => 422,
        "code_500" => 500,
        "code_503" => 503
      }

      WorkOSStub.start!(fn request ->
        {Map.fetch!(statuses, code(request)), ~s({"error":"invalid_grant"})}
      end)

      log =
        capture_log(fn ->
          for {code, status} <- statuses do
            expected = if status < 500, do: :issuer_refused, else: :unavailable

            assert WorkOS.complete(code, @attempt) == {:error, expected},
                   "HTTP #{status} answers #{expected}"
          end
        end)

      refute log =~ @api_key, "no log line carries the API key"
    end

    test "a connection closed without an answer is an issuer unavailable" do
      WorkOSStub.start!(fn _request -> :close end)

      log =
        capture_log(fn ->
          assert WorkOS.complete("wos_code_closed", @attempt) == {:error, :unavailable}
        end)

      assert_receive {:workos_request, %{path: "/sso/token"}}, 1_000
      refute log =~ @api_key, "no log line carries the API key"
    end

    test "a 200 with no usable profile is the issuer's refusal" do
      usable = WorkOSStub.profile(%{"organization_id" => @organization})

      bodies = %{
        "not_json" => "<html>signed in</html>",
        "array" => "[]",
        "no_profile" => Jason.encode!(%{"access_token" => "wos_access_token"}),
        "null_profile" => Jason.encode!(%{"access_token" => "t", "profile" => nil}),
        "no_id" => token_body(Map.delete(usable, "id")),
        "empty_id" => token_body(%{usable | "id" => ""}),
        "numeric_id" => token_body(%{usable | "id" => 42}),
        "no_connection" => token_body(Map.delete(usable, "connection_id")),
        "empty_connection" => token_body(%{usable | "connection_id" => ""}),
        "no_organization" => token_body(Map.delete(usable, "organization_id"))
      }

      WorkOSStub.start!(fn request -> {200, Map.fetch!(bodies, code(request))} end)

      capture_log(fn ->
        for {code, _body} <- bodies do
          assert WorkOS.complete(code, @attempt) == {:error, :issuer_refused},
                 "the body #{code} proves nothing"
        end
      end)
    end

    test "an unconfigured WorkOS exchanges nothing" do
      WorkOSStub.start!(fn _request -> WorkOSStub.token(WorkOSStub.profile()) end)

      for workos <- [nil, Map.delete(@workos, :api_key), Map.delete(@workos, :organization)] do
        put_env!(:sanctum, :workos, workos)

        assert WorkOS.complete("wos_code_unconfigured", @attempt) == {:error, :unavailable},
               "#{inspect(workos)} is no WorkOS"
      end

      refute_received {:workos_request, _request}
    end
  end

  describe "the company sign-in through WorkOS" do
    test "a person held for the company condition signs in at WorkOS, is bound and stands" do
      profile =
        WorkOSStub.profile(%{
          "organization_id" => @organization,
          "connection_id" => "conn_01OKTA"
        })

      %{url: base} = WorkOSStub.start!(fn _request -> WorkOSStub.token(profile) end)
      {user_id, token} = person_with_session!()
      redirect_uri = Sanctum.Person.home() <> "/auth/company/callback"

      assert Caller.establish({:session, token}) == {:error, :company_login_required}

      assert {:ok, url} = CompanyLogin.start(token)
      started = URI.parse(url)
      assert URI.to_string(%{started | query: nil}) == base <> "/sso/authorize"

      assert {:ok, %Req.Response{status: 302} = response} =
               Req.get(url, redirect: false, retry: false)

      assert_receive {:workos_request, %{method: "GET", path: "/sso/authorize", query: query}},
                     1_000

      assert query == started.query, "the stub received the URL start/1 answered"
      state = URI.decode_query(query)["state"]
      assert is_binary(state)

      assert pairs(query) == [
               {"client_id", @client_id},
               {"organization", @organization},
               {"redirect_uri", redirect_uri},
               {"response_type", "code"},
               {"state", state}
             ]

      assert [location] = Req.Response.get_header(response, "location")
      returned = URI.parse(location)
      assert URI.to_string(%{returned | query: nil}) == redirect_uri
      params = URI.decode_query(returned.query)
      assert %{"code" => code, "state" => ^state} = params

      assert CompanyLogin.complete(params, token) == {:ok, :bound}

      assert_receive {:workos_request, %{method: "POST", path: "/sso/token", body: body}}, 1_000
      assert URI.decode_query(body)["code"] == code

      assert {:ok, %Context{user_id: ^user_id}} = Caller.establish({:session, token})
      assert {:ok, row} = Arca.CompanyAuthorizations.get(Prima.Actor.system(), user_id)
      assert row.configuration == ~s(["workos","#{@organization}","conn_01OKTA"])
      assert row.subject == profile["id"]
    end

    test "WorkOS answering another organization binds nothing and spends the attempt" do
      profile = WorkOSStub.profile(%{"organization_id" => @elsewhere})
      WorkOSStub.start!(fn _request -> WorkOSStub.token(profile) end)
      {user_id, token} = person_with_session!()
      params = sign_in_at_workos!(token)

      assert CompanyLogin.complete(params, token) == {:error, :wrong_organization}
      assert_receive {:workos_request, %{path: "/sso/token"}}, 1_000

      assert Arca.CompanyAuthorizations.get(Prima.Actor.system(), user_id) ==
               {:error, :not_found}

      assert Caller.establish({:session, token}) == {:error, :company_login_required}

      assert CompanyLogin.complete(params, token) == {:error, :attempt_invalid}
      refute_received {:workos_request, _request}
    end

    test "a revocation that commits during the code exchange binds nothing" do
      test = self()

      WorkOSStub.start!(fn request ->
        send(test, {:held, self()})

        receive do
          :release ->
            WorkOSStub.token(
              WorkOSStub.profile(%{
                "id" => "prof_" <> code(request),
                "organization_id" => @organization
              })
            )
        end
      end)

      {kept, kept_token} = person_with_session!()
      {revoked, revoked_token} = person_with_session!()

      assert held_exchange(kept_token, fn -> :ok end) == {:ok, :bound},
             "a held exchange binds when nothing commits during it"

      assert held_exchange(revoked_token, fn ->
               assert Sanctum.Session.destroy(revoked_token) == :ok
             end) == {:error, :session_ended}

      assert {:ok, _row} = Arca.CompanyAuthorizations.get(Prima.Actor.system(), kept)

      assert Arca.CompanyAuthorizations.get(Prima.Actor.system(), revoked) ==
               {:error, :not_found}
    end

    test "an OpenID Connect issuer configured beside WorkOS is never the company's" do
      issuer = "https://idp.example.com"
      put_env!(:sanctum, :oidc_issuer, issuer)
      put_env!(:sanctum, :oidc_reauth_client, UnaskedOIDC)

      put_env!(:ueberauth, Ueberauth,
        providers: [
          oidcc:
            {Ueberauth.Strategy.Oidcc,
             issuer: :cyfr_oidc, client_id: "cid", client_secret: "csec"}
        ]
      )

      profile = WorkOSStub.profile(%{"organization_id" => @organization})
      WorkOSStub.start!(fn _request -> WorkOSStub.token(profile) end)
      {user_id, token} = person_with_session!()

      bind!(user_id, ["oidc", issuer, "cid"], "oidc-subject")

      assert Caller.establish({:session, token}) == {:error, :company_login_required},
             "a row under the OpenID Connect issuer does not stand"

      params = sign_in_at_workos!(token)
      assert CompanyLogin.complete(params, token) == {:ok, :bound}

      assert {:ok, %Context{user_id: ^user_id}} = Caller.establish({:session, token})
      assert {:ok, row} = Arca.CompanyAuthorizations.get(Prima.Actor.system(), user_id)
      assert row.configuration == ~s(["workos","#{@organization}","conn_01CYFR"])
      assert row.subject == profile["id"]
    end
  end

  describe "standing under WorkOS" do
    test "the organization decides, whatever the connection, and its change makes everyone bind again" do
      {okta, okta_token} = person_with_session!()
      {azure, azure_token} = person_with_session!()
      {outsider, outsider_token} = person_with_session!()

      bind!(okta, ["workos", @organization, "conn_01OKTA"], "prof_okta")
      bind!(azure, ["workos", @organization, "conn_01AZURE"], "prof_azure")
      bind!(outsider, ["workos", @elsewhere, "conn_01OKTA"], "prof_outsider")

      assert {:ok, %Context{user_id: ^okta}} = Caller.establish({:session, okta_token})
      assert {:ok, %Context{user_id: ^azure}} = Caller.establish({:session, azure_token})

      assert Caller.establish({:session, outsider_token}) == {:error, :company_login_required},
             "a row of another organization does not stand"

      put_env!(:sanctum, :workos, Map.put(@workos, :organization, @elsewhere))

      for token <- [okta_token, azure_token] do
        assert Caller.establish({:session, token}) == {:error, :company_login_required},
               "a row of the earlier organization stands no more"
      end

      assert {:ok, %Context{user_id: ^outsider}} = Caller.establish({:session, outsider_token})

      profile =
        WorkOSStub.profile(%{
          "id" => "prof_okta",
          "organization_id" => @elsewhere,
          "connection_id" => "conn_01OKTA"
        })

      WorkOSStub.start!(fn _request -> WorkOSStub.token(profile) end)
      params = sign_in_at_workos!(okta_token)

      assert CompanyLogin.complete(params, okta_token) == {:ok, :bound},
             "the earlier organization's row is replaced, not refreshed"

      assert {:ok, row} = Arca.CompanyAuthorizations.get(Prima.Actor.system(), okta)
      assert row.configuration == ~s(["workos","#{@elsewhere}","conn_01OKTA"])
      assert {:ok, %Context{user_id: ^okta}} = Caller.establish({:session, okta_token})
    end
  end

  # A person who stands in every other way, and a session of theirs.
  defp person_with_session! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|workos-#{n}",
        provider: "github",
        email: "workos#{n}@example.com",
        verified: true
      })

    ctx =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "github",
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(ctx)
    {user.id, session.token}
  end

  # The browser's part: the company page's start, then WorkOS's authorize
  # endpoint, which returns the browser to the callback. Answers the
  # callback's parameters.
  defp sign_in_at_workos!(token) do
    assert {:ok, url} = CompanyLogin.start(token)

    assert {:ok, %Req.Response{status: 302} = response} =
             Req.get(url, redirect: false, retry: false)

    assert_receive {:workos_request, %{method: "GET", path: "/sso/authorize"}}, 1_000
    assert [location] = Req.Response.get_header(response, "location")
    URI.decode_query(URI.parse(location).query)
  end

  # The callback completed in a task while the stub holds its code
  # exchange: `during` runs while it is held, then the exchange answers.
  defp held_exchange(token, during) do
    params = sign_in_at_workos!(token)
    exchange = Task.async(fn -> CompanyLogin.complete(params, token) end)
    assert_receive {:held, stub}, 5_000
    during.()
    send(stub, :release)
    Task.await(exchange, 20_000)
  end

  defp bind!(user_id, configuration, subject) do
    assert {:ok, :bound} =
             Arca.CompanyAuthorizations.bind(
               Prima.Actor.system(),
               %{user_id: user_id, configuration: Jason.encode!(configuration), subject: subject},
               verify: fn -> :ok end
             )
  end

  defp token_body(profile), do: elem(WorkOSStub.token(profile), 1)

  defp code(%{body: body}), do: URI.decode_query(body)["code"]

  defp pairs(encoded), do: encoded |> URI.query_decoder() |> Enum.sort()

  # Restored on exit, registered before the change.
  defp put_env!(app, key, value) do
    previous = Application.fetch_env(app, key)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end)

    Application.put_env(app, key, value)
  end
end
