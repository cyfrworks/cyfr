# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.BrowserLogoutTest do
  @moduledoc """
  The browser's sign-out (`PrismWeb.AuthController.browser_logout/2`),
  posted as a browser posts it: with the session cookie a signed-in page
  set and the forgery token that page carries.

  When the store deletes the session the cookie names, the answer is the
  signed-out redirect with `cyfr-session-retired: 1`, and the cookie the
  browser held is refused afterwards; the same cookie signed out again
  gets the header again, since no session of it stands. When the store
  cannot delete it, the answer is `503` with neither the header nor the
  redirect, and that same cookie still signs the browser in, so the
  sign-out can be sent again. A sign-out with no session redirects
  without the header.
  """

  # Installs a trigger on the sessions table, which is schema state every
  # concurrent sandbox would see.
  use CyfrWeb.ConnCase, async: false

  @cookie "_cyfr_key"

  # A signed-in browser: the cookie the first page under a new session of
  # the test athanor's person set, and the forgery token that page
  # carries.
  defp signed_in!(conn) do
    person = Sanctum.TestContext.owner!()

    {:ok, %{token: token}} =
      Sanctum.TestContext.create_session(
        Sanctum.Context.build(
          user_id: person.id,
          provider: "local",
          athanor_id: Sanctum.TestContext.athanor_id(),
          permissions: Sanctum.Context.person_permissions(),
          auth_method: :oidc
        )
      )

    page =
      conn
      |> Plug.Test.init_test_session(%{CyfrWeb.SignInResponse.session_key() => token})
      |> get(~p"/")

    html = html_response(page, 200)
    [_, csrf] = Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, html)
    %{cookie: page.resp_cookies[@cookie].value, csrf: csrf, token: token}
  end

  defp with_cookie(conn, cookie), do: put_req_cookie(conn, @cookie, cookie)

  defp sign_out(conn, %{cookie: cookie, csrf: csrf}) do
    conn
    |> with_cookie(cookie)
    |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
    |> post(~p"/auth/logout", %{"_csrf_token" => csrf})
  end

  # Whether the cookie still signs a browser in: `/` serves the desktop to
  # a session that stands and sends anyone else to the sign-in page.
  defp signs_in?(cookie) do
    case build_conn() |> with_cookie(cookie) |> get(~p"/") do
      %{status: 200} -> true
      %{status: 302} = conn -> refute_redirect_to_sign_in(conn)
    end
  end

  defp refute_redirect_to_sign_in(conn) do
    assert redirected_to(conn) =~ "/login"
    false
  end

  # The store refuses to delete the row of `token`'s session, and only
  # that row; sandbox rollback removes the trigger if the test fails
  # before `allow_deletes/0`.
  defp refuse_delete(token) do
    hash = Base.encode16(Sanctum.Session.token_hash(token), case: :lower)

    statements = %{
      Ecto.Adapters.Postgres => [
        """
        CREATE FUNCTION refuse_logout() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF OLD.token_hash = decode('#{hash}', 'hex') THEN
            RAISE EXCEPTION 'test session delete refused';
          END IF;
          RETURN OLD;
        END $$
        """,
        """
        CREATE TRIGGER refuse_logout BEFORE DELETE ON sessions
        FOR EACH ROW EXECUTE FUNCTION refuse_logout()
        """
      ],
      Ecto.Adapters.SQLite3 => [
        """
        CREATE TRIGGER refuse_logout BEFORE DELETE ON sessions WHEN OLD.token_hash = X'#{hash}'
        BEGIN SELECT RAISE(ABORT, 'test session delete refused'); END
        """
      ]
    }

    Enum.each(Map.fetch!(statements, Arca.Repo.__adapter__()), &Arca.Repo.query!/1)
  end

  defp allow_deletes do
    statements = %{
      Ecto.Adapters.Postgres => [
        "DROP TRIGGER refuse_logout ON sessions",
        "DROP FUNCTION refuse_logout()"
      ],
      Ecto.Adapters.SQLite3 => ["DROP TRIGGER refuse_logout"]
    }

    Enum.each(Map.fetch!(statements, Arca.Repo.__adapter__()), &Arca.Repo.query!/1)
  end

  test "a failed delete answers 503 and keeps the session; the retry retires it and says so",
       %{conn: conn} do
    browser = signed_in!(conn)
    assert signs_in?(browser.cookie)

    refuse_delete(browser.token)
    failed = sign_out(conn, browser)

    assert failed.status == 503
    assert get_resp_header(failed, "cyfr-session-retired") == []
    assert get_resp_header(failed, "location") == []
    assert failed.resp_body =~ "still signed in"

    allow_deletes()
    assert signs_in?(browser.cookie)

    retired = sign_out(conn, browser)

    assert redirected_to(retired) == "/login?error=signed_out"
    assert get_resp_header(retired, "cyfr-session-retired") == ["1"]
    refute signs_in?(browser.cookie)
  end

  test "the same cookie signed out again is told again that no session of it stands",
       %{conn: conn} do
    browser = signed_in!(conn)

    first = sign_out(conn, browser)
    assert get_resp_header(first, "cyfr-session-retired") == ["1"]
    refute signs_in?(browser.cookie)

    again = sign_out(conn, browser)
    assert redirected_to(again) == "/login?error=signed_out"
    assert get_resp_header(again, "cyfr-session-retired") == ["1"]
    refute signs_in?(browser.cookie)
  end

  test "a sign-out with no session acknowledges no retirement and retires nothing",
       %{conn: conn} do
    browser = signed_in!(conn)
    page = build_conn() |> Plug.Test.init_test_session(%{}) |> get(~p"/login")
    [_, csrf] = Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, html_response(page, 200))

    signed_out = sign_out(conn, %{cookie: page.resp_cookies[@cookie].value, csrf: csrf})

    assert redirected_to(signed_out) == "/login?error=signed_out"
    assert get_resp_header(signed_out, "cyfr-session-retired") == []
    assert signs_in?(browser.cookie)
  end
end
