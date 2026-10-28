# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.CompanyLoginLiveTest do
  @moduledoc """
  `/company-login` and the console pages around it, at a CYFR that
  requires a company sign-in through its OpenID Connect issuer.

  The page opens only for a session refused for the company sign-in and
  nothing else: it says why, offers the start (a POST to `/auth/company`)
  and signing out, and shows the sentence for the `error` the callback
  sent back. A session that stands goes to `/`, and none or a revoked one
  to `/login`. A protected page mounted by a person who lapsed sends them
  to the company page, and their session stands; an open page ends at its
  revalidation once its person lapses, a configuration change included.
  """

  # Installs the company sign-in's settings, which are application
  # environment.
  use PrismWeb.ConnCase, async: false

  alias CyfrWeb.ContextGuard
  alias PrismWeb.CompanyLoginLive

  @issuer "https://idp.example.com"

  setup do
    keys = [{:sanctum, :company_login}, {:sanctum, :oidc_issuer}, {:ueberauth, Ueberauth}]
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
    client!("cid")
    Application.put_env(:sanctum, :company_login, %{mode: :join, days: nil, issuer: :oidc})
    :ok
  end

  # The `oidcc` client the company's issuer knows this CYFR by: changing
  # its id is a configuration change, under which no binding stands.
  defp client!(client_id) do
    Application.put_env(:ueberauth, Ueberauth,
      providers: [
        oidcc:
          {Ueberauth.Strategy.Oidcc,
           issuer: :cyfr_oidc, client_id: client_id, client_secret: "csec"}
      ]
    )
  end

  # The person's company sign-in, given under the configuration this CYFR
  # names now.
  defp stands!(%{user_id: user_id}) do
    {:ok, {client_id, _secret}} = Sanctum.Auth.OIDC.client_credentials()

    assert {:ok, _bound} =
             Arca.CompanyAuthorizations.bind(
               Prima.Actor.system(),
               %{
                 user_id: user_id,
                 configuration: Jason.encode!(["oidc", @issuer, client_id]),
                 subject: "sub-#{System.unique_integer([:positive])}"
               },
               verify: fn -> :ok end
             )

    :ok
  end

  defp token(conn), do: get_session(conn, session_key())

  describe "the company page" do
    test "opens for a session refused only for the company sign-in, saying why", %{conn: conn} do
      conn = log_in_user(conn, test_user())
      {:ok, view, _html} = live(conn, ~p"/company-login")

      assert has_element?(view, ~s([data-test="company-login"]))

      assert has_element?(
               view,
               ~s([data-test="company-login"] p),
               Prima.Refusal.message(:company_login_required)
             )

      assert has_element?(
               view,
               ~s(a[data-test="company-login-start"][href="/auth/company"][data-method="post"])
             )

      assert has_element?(
               view,
               ~s(a[data-test="company-login-sign-out"][href="/auth/logout"][data-method="post"])
             )

      refute has_element?(view, ~s([data-test="company-login-error"]))
    end

    test "sends a session that stands to /", %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      stands!(user)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/company-login")
    end

    test "sends a browser with no session, or a revoked one, to /login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} =
               live(Plug.Test.init_test_session(conn, %{}), ~p"/company-login")

      signed_in = log_in_user(conn, test_user())
      :ok = Sanctum.Session.destroy(token(signed_in))

      assert {:error, {:redirect, %{to: "/login"}}} = live(signed_in, ~p"/company-login")
    end

    test "shows the sentence for the error the callback sent back", %{conn: conn} do
      conn = log_in_user(conn, test_user())
      errors = ["subject_bound", "wrong_organization", "unavailable", "refused"]
      sentences = Enum.map(errors, &CompanyLoginLive.sentence/1)

      assert length(Enum.uniq(sentences)) == length(errors),
             "each error the callback names reads its own sentence"

      assert CompanyLoginLive.sentence("subject_bound") ==
               Prima.Refusal.message(:company_subject_bound)

      for {error, sentence} <- Enum.zip(errors, sentences) do
        {:ok, view, _html} = live(conn, "/company-login?error=#{error}")

        assert has_element?(view, ~s([data-test="company-login-error"]), sentence),
               "the page shows #{error}'s sentence"

        assert has_element?(view, ~s([data-test="company-login-start"]))
      end
    end
  end

  describe "a protected page" do
    test "mounted by a person who lapsed sends them to the company page, and the session stands",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)

      for path <- [~p"/chat", athanor_path("/settings")] do
        assert {:error, {:redirect, %{to: "/company-login"}}} = live(conn, path),
               "#{path} sends the lapsed person to the company page"
      end

      assert {:ok, %{user_id: user_id}} = Sanctum.Session.load(token(conn))
      assert user_id == user.user_id

      {:ok, view, _html} = live(conn, ~p"/company-login")
      assert has_element?(view, ~s([data-test="company-login-start"]))
    end

    test "open ends at its revalidation once a configuration change lapses its person",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      stands!(user)
      {view, _html} = mount_athanor(conn, "/settings")

      client!("cid-rotated")
      send(view.pid, ContextGuard.recheck_message())

      assert_redirect(view, "/company-login", 2_000)
      assert {:ok, _session} = Sanctum.Session.load(token(conn))
    end
  end
end
