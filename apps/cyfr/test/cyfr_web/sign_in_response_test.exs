# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.SignInResponseTest do
  @moduledoc """
  The one transcription of a sign-in outcome to a browser response: a
  proceed is a redirect to the console root carrying the session, an
  outage is a page, and the pending-probe cookie is carried or retired.
  """
  use CyfrWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias CyfrWeb.SignInResponse

  @probe_cookie "_cyfr_pending_probe"
  @secret String.duplicate("s", 64)

  defp browser_conn(session \\ %{}) do
    build_conn()
    |> Map.put(:secret_key_base, @secret)
    |> init_test_session(session)
    |> fetch_flash()
  end

  defp session_dropped?(conn), do: conn.private[:plug_session_info] == :drop

  test "the session key is the context guard's" do
    assert SignInResponse.session_key() == CyfrWeb.ContextGuard.session_key()
  end

  describe "respond/3 — a proceed" do
    test "a device ticket's token becomes the session and the console root is the landing" do
      conn =
        SignInResponse.respond(browser_conn(), {:proceed, %{}}, session: {:token, "tok-1"})

      assert redirected_to(conn) == "/"
      assert get_session(conn, SignInResponse.session_key()) == "tok-1"
    end

    test "the anonymous session is cleared before the token is written" do
      conn =
        %{"_csrf_token" => "planted"}
        |> browser_conn()
        |> SignInResponse.respond({:proceed, %{}}, session: {:token, "tok-2"})

      assert get_session(conn, "_csrf_token") == nil
      assert get_session(conn, SignInResponse.session_key()) == "tok-2"
    end

    test "a minted session is a live session for the context" do
      ctx = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())

      conn = SignInResponse.respond(browser_conn(), {:proceed, %{}}, session: {:mint, ctx})

      assert redirected_to(conn) == "/"
      token = get_session(conn, SignInResponse.session_key())
      assert is_binary(token)
      assert {:ok, %{user_id: user_id}} = Sanctum.Caller.peek(token)
      assert user_id == ctx.user_id

      Sanctum.Session.destroy(token)
    end

    test "an existing session stands as it is" do
      conn =
        %{sanctum_session_token: "existing"}
        |> browser_conn()
        |> SignInResponse.respond({:proceed, %{}}, session: :existing)

      assert redirected_to(conn) == "/"
      assert get_session(conn, SignInResponse.session_key()) == "existing"
      refute session_dropped?(conn)
    end

    test "an access token is stashed in the encrypted probe cookie" do
      conn =
        SignInResponse.respond(browser_conn(), {:proceed, %{}},
          session: :existing,
          access_token: "gho_probe"
        )

      assert %{value: value} = cookie = conn.resp_cookies[@probe_cookie]
      assert cookie.max_age == 600
      assert cookie.http_only == true
      assert cookie.same_site == "Lax"
      refute value =~ "gho_probe"

      read =
        build_conn()
        |> Map.put(:secret_key_base, @secret)
        |> put_req_cookie(@probe_cookie, value)
        |> fetch_cookies(encrypted: [@probe_cookie])

      assert read.cookies[@probe_cookie] == "gho_probe"
    end

    test "no access token retires any stash" do
      conn = SignInResponse.respond(browser_conn(), {:proceed, %{}}, session: :existing)

      assert %{max_age: 0} = conn.resp_cookies[@probe_cookie]
    end

    test "a stash that cannot be written leaves the sign-in standing" do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> fetch_flash()

      {conn, log} =
        with_log(fn ->
          SignInResponse.respond(conn, {:proceed, %{}},
            session: :existing,
            access_token: "gho_probe"
          )
        end)

      assert redirected_to(conn) == "/"
      refute Map.has_key?(conn.resp_cookies, @probe_cookie)
      assert log =~ "failed to stash pending_probe cookie"
      refute log =~ "gho_probe"
    end

    test "the registry's report is flashed" do
      conn =
        SignInResponse.respond(
          browser_conn(),
          {:proceed, %{unsynced: ["acme"], probe: :ok}},
          session: :existing
        )

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "acme"

      conn =
        SignInResponse.respond(
          browser_conn(),
          {:proceed, %{unsynced: [], probe: :legal_required}},
          session: :existing
        )

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "updated its policy"
    end

    test "a response without flash still lands" do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> SignInResponse.respond({:proceed, %{unsynced: [], probe: :failed}},
          session: :existing
        )

      assert redirected_to(conn) == "/"
      refute Map.has_key?(conn.assigns, :flash)
    end
  end

  describe "respond/3 — an outage" do
    test "a mint that could not finish drops the session and answers a 503 page" do
      ctx = Sanctum.TestContext.local()

      conn =
        %{sanctum_session_token: "stale"}
        |> browser_conn()
        |> SignInResponse.respond({:unavailable, :membership_read}, session: {:mint, ctx})

      assert conn.status == 503
      assert ["text/html" <> _] = get_resp_header(conn, "content-type")
      assert conn.resp_body =~ "could not read memberships"
      assert conn.resp_body =~ ~s(<a href="/login">Try again</a>)
      assert session_dropped?(conn)
    end

    test "an existing session stands through an outage" do
      conn =
        %{sanctum_session_token: "existing"}
        |> browser_conn()
        |> SignInResponse.respond({:unavailable, :other}, session: :existing)

      assert conn.status == 503
      assert conn.resp_body =~ "Signing in did not finish"
      refute session_dropped?(conn)
      assert get_session(conn, SignInResponse.session_key()) == "existing"
    end

    test "the retry path is escaped into the page" do
      conn =
        SignInResponse.respond(browser_conn(), {:unavailable, :membership_read},
          session: :existing,
          retry_path: "/legal?x=<b>"
        )

      assert conn.resp_body =~ ~s(href="/legal?x=&lt;b&gt;")
    end

    test "a caller that accepts JSON is answered with the same page" do
      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> SignInResponse.respond({:unavailable, :membership_read}, session: :existing)

      assert conn.status == 503
      assert ["text/html" <> _] = get_resp_header(conn, "content-type")
    end

    test "a mint outage on a conn with no session is still a page" do
      conn =
        SignInResponse.respond(build_conn(), {:unavailable, :membership_read},
          session: {:mint, Sanctum.TestContext.local()}
        )

      assert conn.status == 503
    end
  end

  describe "the session and flash helpers" do
    test "put_flash_if_available/3 flashes when flash is fetched and is a no-op otherwise" do
      conn = SignInResponse.put_flash_if_available(browser_conn(), :info, "hello")
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "hello"

      bare = build_conn()
      assert SignInResponse.put_flash_if_available(bare, :info, "hello") == bare
    end

    test "safe_drop_session/1 drops a fetched session and is a no-op otherwise" do
      assert session_dropped?(SignInResponse.safe_drop_session(browser_conn()))

      bare = build_conn()
      assert SignInResponse.safe_drop_session(bare) == bare
    end
  end
end
