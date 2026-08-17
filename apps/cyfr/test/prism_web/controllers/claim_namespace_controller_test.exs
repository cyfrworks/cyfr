# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ClaimNamespaceControllerTest do
  @moduledoc """
  Tests for the personal-namespace claim gate.

  Happy-path POST `/submit` requires a mocked `Registry.Client.claim_personal_namespace/4`
  response which the repo has no infrastructure for; those cases are deliberately
  not covered here (they land with codex integration tests). The error cases
  below exercise the controller's cookie/session guards and form rendering
  without making any HTTP calls to cyfr.run.
  """
  use EmissaryWeb.ConnCase

  setup do
    # Tests migrate the cyfr.run endpoint to an unreachable host so any probe
    # that does reach HTTP fails fast rather than hanging on real DNS/TCP.
    # Client.ex builds `https://#{host}`; localhost:19 is almost certainly
    # not listening.
    original_registry_url = Application.get_env(:cyfr, :registry_url)
    Application.put_env(:cyfr, :registry_url, "127.0.0.1:19")

    on_exit(fn ->
      if original_registry_url,
        do: Application.put_env(:cyfr, :registry_url, original_registry_url),
        else: Application.delete_env(:cyfr, :registry_url)
    end)

    :ok
  end

  describe "GET /claim-namespace" do
    test "renders the form with CSRF token embedded", %{conn: conn} do
      conn = get(conn, ~p"/claim-namespace/")

      assert response(conn, 200)
      body = response(conn, 200)
      assert body =~ "Claim your cyfr.run namespace"
      assert body =~ "name=\"_csrf_token\""
      assert body =~ "pattern=\"^[a-z0-9]+(-[a-z0-9]+)*$\""
    end

    test "pre-fills the username input from :claim_suggested_username in session",
         %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:claim_suggested_username, "alice-smith")
        |> get(~p"/claim-namespace/")

      body = response(conn, 200)
      assert body =~ ~s(value="alice-smith")
    end

    test "renders empty value when no suggested username in session", %{conn: conn} do
      conn = get(conn, ~p"/claim-namespace/")
      body = response(conn, 200)
      assert body =~ ~s(value="")
    end
  end

  describe "POST /claim-namespace/submit" do
    test "returns 400 with 'Login session expired' when :_cyfr_pending_probe cookie missing",
         %{conn: conn} do
      csrf = get_csrf_from_form(conn)

      conn =
        conn
        |> post(~p"/claim-namespace/submit", %{
          "_csrf_token" => csrf,
          "username" => "alice"
        })

      # The pop_pending_probe/1 guard fires before any HTTP call; controller
      # returns 400 and re-renders the form with the "expired" error banner.
      assert conn.status == 400
      body = response(conn, 400)
      assert body =~ "Login session expired"
    end

    test "re-renders form with error when :username param missing entirely",
         %{conn: conn} do
      csrf = get_csrf_from_form(conn)

      conn = post(conn, ~p"/claim-namespace/submit", %{"_csrf_token" => csrf})

      assert conn.status == 400
      body = response(conn, 400)
      assert body =~ "username is required"
    end

    test "CSRF token is embedded in the rendered form", %{conn: conn} do
      # The `:browser` pipeline includes `:protect_from_forgery`; the
      # claim-namespace scope is under that pipeline (router.ex:50-55).
      # `Phoenix.ConnTest.build_conn/0` bypasses CSRF validation by design
      # (the test conn has CSRF disabled for ergonomics), so we verify the
      # token is RENDERED — runtime CSRF enforcement is the framework's
      # responsibility once a real request hits the pipeline.
      conn = get(conn, ~p"/claim-namespace/")
      body = response(conn, 200)

      assert body =~ ~s(name="_csrf_token")
      assert Regex.match?(~r/name="_csrf_token" value="[A-Za-z0-9_+\/=-]+"/, body)
    end

    test "submit without a probe cookie reports the expired session" do
      csrf = get_csrf_from_form(build_conn())

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{sanctum_session_token: "fake-session"})
        |> post(~p"/claim-namespace/submit", %{
          "_csrf_token" => csrf,
          "username" => "alice"
        })

      assert response(conn, 400) =~ "Login session expired"
    end

    test "a probe cookie minted by the writer's scheme is readable on submit" do
      # Scheme-drift tripwire: AuthController.maybe_stash_pending_probe/3 writes
      # this cookie with `encrypt: true`, and pop_pending_probe/1 must fetch it
      # with the matching `encrypted:` option. A mismatch (e.g. reading it as
      # `signed:`) makes the cookie verify-fail to nil, and every submit — even
      # right after login — dead-ends in "Login session expired". Mint the
      # cookie exactly as the writer does, against the endpoint's real secret,
      # and assert the controller gets PAST the expired branch.
      csrf = get_csrf_from_form(build_conn())
      access_token = "gho_fake_probe_token"
      endpoint_secret = EmissaryWeb.Endpoint.config(:secret_key_base)

      writing_conn =
        build_conn()
        |> Map.put(:secret_key_base, endpoint_secret)
        |> put_resp_cookie("_cyfr_pending_probe", access_token,
          encrypt: true,
          max_age: 600,
          http_only: true,
          same_site: "Lax"
        )

      %{value: cookie_value} = writing_conn.resp_cookies["_cyfr_pending_probe"]

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{sanctum_session_token: "fake-session"})
        |> Plug.Test.put_req_cookie("_cyfr_pending_probe", cookie_value)
        |> post(~p"/claim-namespace/submit", %{
          "_csrf_token" => csrf,
          "username" => "alice"
        })

      # With a readable probe the flow proceeds to the session lookup (the fake
      # session token fails there, which is fine) — it must NOT stall on the
      # cookie. If this renders "Login session expired", the write/read cookie
      # schemes have drifted apart again.
      refute response_body(conn) =~ "Login session expired"

      # Regression for the cookie-retry bug: pop_pending_probe/1 must not
      # delete the cookie on read — a failed claim (e.g. slug_taken 409)
      # re-renders the form and the retry needs the same access_token.
      # delete_resp_cookie writes max-age=0 (and a 1970 expires date).
      deletion_markers =
        conn
        |> get_resp_header("set-cookie")
        |> Enum.filter(&String.starts_with?(&1, "_cyfr_pending_probe="))
        |> Enum.filter(fn header ->
          String.contains?(header, "max-age=0") or
            String.contains?(header, "expires=Thu, 01 Jan 1970")
        end)

      assert deletion_markers == [],
             "_cyfr_pending_probe cookie was deleted before the claim succeeded — retry will 400 'expired'. " <>
               "See ClaimNamespaceController.pop_pending_probe/1."
    end
  end

  # The submit failure pages render with varying status codes depending on the
  # branch (400 expired, 302 not-logged-in redirect, 200 form re-render); read
  # whatever body came back without pinning the status.
  defp response_body(conn), do: conn.resp_body || ""

  # The test pipeline renders the form with a CSRF token; pull it out and
  # reuse for the subsequent POST. Keeps tests independent of Phoenix's
  # internal token format.
  defp get_csrf_from_form(conn) do
    conn = get(conn, ~p"/claim-namespace/")
    body = response(conn, 200)

    case Regex.run(~r/name="_csrf_token" value="([^"]+)"/, body) do
      [_, token] -> token
      _ -> raise "Could not extract CSRF token from claim-namespace form"
    end
  end
end
