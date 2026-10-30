# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AuthControllerTest do
  @moduledoc """
  Tests for the browser's sign-in controller.

  Tests cover:
  - request/2: Unknown provider handling
  - callback/2: Success and failure cases. The OpenID Connect callback
    unlocks the person who linked the identity it names
    (`Sanctum.SignIn.unlock/1`) and never makes one.
  - device_complete/2: The device-flow ticket
  - cyfr_start/2: The start of every `cyfr` sign-in, whose request the
    browser's session keeps in place of any earlier attempt and its
    challenge until the callback admits under it
  """
  use CyfrWeb.ConnCase

  # The OpenID Connect issuer this CYFR is configured with, which offers
  # the callback's sign-in; restored when the case ends.
  defp issuer! do
    previous = Application.fetch_env(:sanctum, :oidc_issuer)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sanctum, :oidc_issuer, value)
        :error -> Application.delete_env(:sanctum, :oidc_issuer)
      end
    end)

    Application.put_env(:sanctum, :oidc_issuer, "https://idp.test")
  end

  # A person here with the issuer's identity `uid` linked.
  defp linked!(uid, attrs \\ %{}) do
    {:ok, user} =
      Sanctum.Test.People.linked(
        Map.merge(%{id: "oidcc|https://idp.test|#{uid}", provider: "oidcc"}, attrs)
      )

    user
  end

  describe "request/2" do
    test "returns 404 for unknown provider", %{conn: conn} do
      conn = get(conn, ~p"/auth/unknown_provider")

      # A browser pipeline answers in HTML now, not JSON dumped into the
      # person's window.
      assert html_response(conn, 404) =~ "Unknown sign-in provider"
    end

    test "GET /auth/github is 404: GitHub signs in by device flow", %{conn: conn} do
      conn = get(conn, ~p"/auth/github")
      assert html_response(conn, 404) =~ "Unknown sign-in provider"
    end
  end

  describe "callback/2" do
    setup do
      issuer!()
      # The door's `*`: a sign-in method still makes no one where it stands.
      {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "test")

      # No sign-in speaks to the registry; it points at an address nothing
      # answers on all the same, so a request made by mistake reaches no
      # public registry.
      original_registry = Application.get_env(:cyfr, :registry_url)
      Application.put_env(:cyfr, :registry_url, "127.0.0.1:19")

      on_exit(fn ->
        if original_registry,
          do: Application.put_env(:cyfr, :registry_url, original_registry),
          else: Application.delete_env(:cyfr, :registry_url)
      end)

      :ok
    end

    test "returns error for invalid callback without auth data", %{conn: conn} do
      # Simulate a callback without Ueberauth data
      conn = get(conn, ~p"/auth/oidcc/callback")

      assert html_response(conn, 400) =~ "Invalid sign-in callback"
    end

    test "handles ueberauth failure", %{conn: conn} do
      # Simulate Ueberauth failure
      failure = %Ueberauth.Failure{
        provider: :oidcc,
        errors: [
          %Ueberauth.Failure.Error{message: "Access denied"}
        ]
      }

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> assign(:ueberauth_failure, failure)
        |> PrismWeb.AuthController.callback(%{})

      assert html_response(conn, 401) =~ "Sign-in failed"
      assert html_response(conn, 401) =~ "Access denied"
    end

    test "a callback for an identity no person here linked is refused, with no session, no person and no door request",
         %{conn: conn} do
      people = Arca.Repo.aggregate(Arca.Schemas.User, :count)

      auth = %Ueberauth.Auth{
        uid: "99999",
        provider: :oidcc,
        info: %Ueberauth.Auth.Info{email: "stranger@example.com", name: "Stranger"},
        credentials: %Ueberauth.Auth.Credentials{
          token: "gho_x",
          refresh_token: nil,
          expires: false
        },
        extra: %{}
      }

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> assign(:ueberauth_auth, auth)
        |> PrismWeb.AuthController.callback(%{})

      assert conn.status == 403
      assert conn.resp_body =~ "No one here signs in with this account"
      assert conn.resp_body =~ ~s(href="/login")
      refute get_session(conn, :sanctum_session_token)
      user_id = "oidcc|https://idp.test|99999"
      assert {:error, :not_found} = Sanctum.Tenancy.Users.get_by_identity(user_id)
      assert Arca.Repo.aggregate(Arca.Schemas.User, :count) == people
      assert Sanctum.Door.Store.requests() == []
    end

    test "a person a deny names is refused even when the door is *", %{conn: conn} do
      user = linked!("77777", %{email: "banned@example.com", verified: true})
      {:ok, _} = Sanctum.Door.Store.deny("person", user.id, "test")

      auth = %Ueberauth.Auth{
        uid: "77777",
        provider: :oidcc,
        info: %Ueberauth.Auth.Info{email: "banned@example.com", name: "Banned"},
        credentials: %Ueberauth.Auth.Credentials{
          token: "gho_x",
          refresh_token: nil,
          expires: false
        },
        extra: %{}
      }

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> assign(:ueberauth_auth, auth)
        |> PrismWeb.AuthController.callback(%{})

      assert conn.status == 403
      assert conn.resp_body =~ "not allowed on this server"
      refute get_session(conn, :sanctum_session_token)
    end

    defp oidcc_auth(uid, email) do
      %Ueberauth.Auth{
        uid: uid,
        provider: :oidcc,
        info: %Ueberauth.Auth.Info{email: email, name: "Test User"},
        credentials: %Ueberauth.Auth.Credentials{
          token: "gho_mock_access_token",
          refresh_token: nil,
          expires: false
        },
        extra: %{}
      }
    end

    test "a person signs in on their own athanor even with cyfr.run unreachable",
         %{conn: conn} do
      uid = "first-#{System.unique_integer([:positive])}"
      user = linked!(uid)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> assign(:ueberauth_auth, oidcc_auth(uid, "test@example.com"))
        |> PrismWeb.AuthController.callback(%{})

      assert redirected_to(conn) == "/"
      token = Plug.Conn.get_session(conn, :sanctum_session_token)
      assert is_binary(token)

      assert {:ok, %{namespace: nil, personal_athanor_id: pid}} =
               Sanctum.Tenancy.Users.get(user.id)

      assert {:ok, %{kind: "person", owner_user_id: owner}} = Sanctum.Tenancy.Athanors.get(pid)
      assert owner == user.id
      assert {:ok, %{user_id: user_id, athanor_id: ^pid}} = Sanctum.Session.load(token)
      assert user_id == user.id
    end

    test "a returning person signs in and lands in the chat even with cyfr.run unreachable",
         %{conn: conn} do
      uid = "back-#{System.unique_integer([:positive])}"
      user_id = "oidcc|https://idp.test|#{uid}"

      {:ok, user} =
        Sanctum.Test.People.linked(%{
          id: user_id,
          provider: "oidcc",
          email: "back@example.com",
          verified: true
        })

      {:ok, _} =
        Sanctum.Tenancy.Users.set_namespace(user, "back#{System.unique_integer([:positive])}")

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Phoenix.ConnTest.fetch_flash()
        |> assign(:ueberauth_auth, oidcc_auth(uid, "back@example.com"))
        |> PrismWeb.AuthController.callback(%{})

      assert redirected_to(conn) == "/"
      token = Plug.Conn.get_session(conn, :sanctum_session_token)
      assert is_binary(token)
      assert {:ok, %{authenticated: true}} = Sanctum.Session.load(token)
      # The token travels in the cookie only.
      refute conn.resp_body =~ token
    end

    test "a door a recovery retires during the sign-in through it is refused as a sign-in, with no session and no error",
         %{conn: conn} do
      alias Sanctum.Test.DirectoryServer

      tls = DirectoryServer.tls()
      DirectoryServer.listen!()
      DirectoryServer.seam!(tls)
      directory = DirectoryServer.start!(tls)
      identity = DirectoryServer.identity!(directory.dir, directory.url)

      # A person whose keys are at another home, signing in here through an
      # OpenID Connect door of theirs.
      uid = "recovered-#{System.unique_integer([:positive])}"
      key = "oidcc|https://idp.test|#{uid}"

      {:ok, user} =
        Sanctum.Test.People.linked(%{
          id: key,
          provider: "oidcc",
          verified: :unknown
        })

      :ok = DirectoryServer.remote_person!(user.id, identity)

      signed_in =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Phoenix.ConnTest.fetch_flash()
        |> assign(:ueberauth_auth, oidcc_auth(uid, nil))
        |> PrismWeb.AuthController.callback(%{})

      assert is_binary(Plug.Conn.get_session(signed_in, :sanctum_session_token))

      # They recover with new keys at their directory. The next sign-in's
      # fresh read finds the recovery and retires the door it came through
      # before its session is issued.
      DirectoryServer.recover!(directory.dir, identity)

      {refused, log} =
        ExUnit.CaptureLog.with_log(fn ->
          build_conn()
          |> Plug.Test.init_test_session(%{})
          |> Phoenix.ConnTest.fetch_flash()
          |> assign(:ueberauth_auth, oidcc_auth(uid, nil))
          |> PrismWeb.AuthController.callback(%{})
        end)

      assert refused.status == 401
      assert refused.resp_body =~ "Sign in again"
      assert refused.resp_body =~ ~s(href="/login")
      refute Plug.Conn.get_session(refused, :sanctum_session_token)
      # No fault logged for it.
      refute log =~ "CyfrWeb.SignInResponse"
      assert {:error, :not_found} = Sanctum.Tenancy.Users.get_by_identity(key)
    end
  end

  # The registry is a Bypass server holding no expectation, so any request a
  # sign-in made to it would fail the test: no sign-in speaks to the
  # registry, and the provider's token goes nowhere.
  describe "callback/2 — no sign-in speaks to the registry (Bypass)" do
    alias Compendium.Registry.CredentialStore

    setup do
      issuer!()
      {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "test")

      bypass = Bypass.open()
      original_url = Application.get_env(:cyfr, :registry_url)
      original_oci = Application.get_env(:cyfr, :oci_registry_url)

      original_sanctum = Application.get_env(:sanctum, :registry_url)
      Application.put_env(:cyfr, :registry_url, "127.0.0.1:#{bypass.port}")
      Application.put_env(:sanctum, :registry_url, "127.0.0.1:#{bypass.port}")
      Application.put_env(:cyfr, :oci_registry_url, "registry.test")

      on_exit(fn ->
        if original_url,
          do: Application.put_env(:cyfr, :registry_url, original_url),
          else: Application.delete_env(:cyfr, :registry_url)

        Application.put_env(:sanctum, :registry_url, original_sanctum)

        if original_oci,
          do: Application.put_env(:cyfr, :oci_registry_url, original_oci),
          else: Application.delete_env(:cyfr, :oci_registry_url)
      end)

      {:ok, bypass: bypass}
    end

    defp verified_oidcc_auth(uid, opts \\ []) do
      %Ueberauth.Auth{
        uid: uid,
        provider: :oidcc,
        info: %Ueberauth.Auth.Info{
          email: Keyword.get(opts, :email, "alice@example.com"),
          name: "Alice"
        },
        credentials: %Ueberauth.Auth.Credentials{
          token: Keyword.get(opts, :token, "gho_access"),
          refresh_token: nil,
          expires: false
        },
        extra: %Ueberauth.Auth.Extra{
          raw_info: %{userinfo: %{"email_verified" => true}}
        }
      }
    end

    defp callback(conn, auth) do
      %{conn | secret_key_base: String.duplicate("a", 64)}
      |> Plug.Test.init_test_session(%{})
      |> Phoenix.ConnTest.fetch_flash()
      |> assign(:ueberauth_auth, auth)
      |> PrismWeb.AuthController.callback(%{})
    end

    defp session_of(conn), do: Plug.Conn.get_session(conn, :sanctum_session_token)

    # The identity `key` linked to the person `user_id`, as linking a
    # sign-in method writes it.
    defp link!(user_id, key) do
      {:ok, %{provider: provider, issuer: issuer, subject: subject}} =
        Sanctum.Auth.Identity.parse(key)

      now = DateTime.utc_now()

      %Arca.Schemas.ExternalIdentity{}
      |> Arca.Schemas.ExternalIdentity.changeset(%{
        id: Prima.UUID7.generate_id("ext"),
        user_id: user_id,
        key: key,
        provider: provider,
        issuer: issuer,
        subject: subject,
        first_seen_at: now,
        last_seen_at: now
      })
      |> Arca.Repo.insert!()
    end

    test "a sign-in lands on the person's own athanor, asks the registry nothing and keeps no token",
         %{conn: conn} do
      uid = "auth_cb_first_#{System.unique_integer([:positive])}"
      user_id = "oidcc|https://idp.test|#{uid}"
      linked!(uid)

      conn = callback(conn, verified_oidcc_auth(uid, token: "gho_never_sent"))

      assert redirected_to(conn) == "/"
      assert is_binary(session_of(conn))
      refute Enum.any?(Map.keys(conn.resp_cookies), &(&1 =~ "probe"))
      refute inspect(conn.resp_cookies) =~ "gho_never_sent"

      assert {:ok, %{personal_athanor_id: pid, namespace: nil}} =
               Sanctum.Tenancy.Users.get(person_id(user_id))

      assert {:ok, %{authenticated: true, namespace: nil, athanor_id: ^pid}} =
               Sanctum.Session.load(session_of(conn))

      assert {:ok, []} =
               CredentialStore.list_for_user(person_context(user_id), "registry.test")
    end

    test "a returning person's namespace is the one their row holds", %{conn: conn} do
      n = System.unique_integer([:positive])
      back = "auth_cb_back_#{n}"

      {:ok, user} =
        Sanctum.Test.People.linked(%{
          id: "oidcc|https://idp.test|#{back}",
          provider: "oidcc",
          email: "alice@example.com",
          verified: true
        })

      {:ok, _} = Sanctum.Tenancy.Users.set_namespace(user, "back#{n}")
      conn = callback(conn, verified_oidcc_auth(back))

      assert redirected_to(conn) == "/"
      assert {:ok, %{namespace: ns}} = Sanctum.Session.load(session_of(conn))
      assert ns == "back#{n}"
    end

    test "signing in does not carry the pre-login session across",
         %{conn: conn} do
      # The anonymous session's `_csrf_token` is what binds a device-flow
      # ticket to a browser, so anything an attacker could plant on this
      # origin before sign-in must not survive it. Nothing set before the
      # exchange is still readable after.
      n = System.unique_integer([:positive])
      uid = "auth_cb_renew_#{n}"
      linked!(uid)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:planted, "pre-login")
        |> Plug.Conn.put_session("_csrf_token", "pre-login-csrf")

      assert Plug.Conn.get_session(conn, :planted) == "pre-login"

      conn = callback(conn, verified_oidcc_auth(uid))

      assert is_binary(session_of(conn))
      refute Plug.Conn.get_session(conn, :planted)
      refute Plug.Conn.get_session(conn, "_csrf_token") == "pre-login-csrf"
    end

    test "a full server still signs in a person who is here: the caps count admissions, not sign-ins",
         %{conn: conn} do
      n = System.unique_integer([:positive])
      user = linked!("full_#{n}", %{email: "full#{n}@example.com", verified: true})
      Cyfr.Test.Settings.put("max_athanors", 1)

      conn = callback(conn, verified_oidcc_auth("full_#{n}", email: "full#{n}@example.com"))

      assert redirected_to(conn) == "/"
      assert {:ok, %{user_id: user_id}} = Sanctum.Session.load(session_of(conn))
      assert user_id == user.id
    end

    test "the administrator's sign-in lands in their own athanor, with the capability",
         %{conn: conn} do
      n = System.unique_integer([:positive])
      uid = "auth_cb_ops_#{n}"
      Arca.Repo.delete_all(Arca.Schemas.User)
      admin = Sanctum.Test.People.first!()
      link!(admin.id, "oidcc|https://idp.test|#{uid}")

      conn = callback(conn, verified_oidcc_auth(uid, email: "ops#{n}@example.com"))

      assert redirected_to(conn) == "/"

      # Their own athanor is minted at their admission and is what the
      # session names; the grant is a platform row beside it, not a seat.
      assert {:ok, %{id: personal_id}} = Sanctum.Tenancy.Athanors.get_by_owner(admin.id)

      assert {:ok, %{user_id: user_id, athanor_id: ^personal_id, platform_admin: true}} =
               Sanctum.Session.load(session_of(conn))

      assert user_id == admin.id
    end

    test "no browser outcome is a JSON document, and no body carries a session token",
         %{conn: conn} do
      uid = "auth_cb_nojson_#{System.unique_integer([:positive])}"
      linked!(uid)

      # With the provider's token and without one: a redirect each time.
      for auth <- [verified_oidcc_auth(uid), verified_oidcc_auth(uid, token: nil)] do
        conn = callback(conn, auth)
        assert conn.status == 302
        refute Enum.any?(Plug.Conn.get_resp_header(conn, "content-type"), &(&1 =~ "json"))
        refute conn.resp_body =~ "session_token"
      end
    end
  end

  describe "device_complete/2 — the ticket carries the session" do
    defp mint_session do
      ctx =
        Sanctum.Context.build(
          user_id: "github|https://github.com|ticket_#{System.unique_integer([:positive])}",
          email: "ticket@example.com",
          provider: "github",
          permissions: [:*],
          namespace: "testns",
          authenticated: true
        )

      {:ok, session} = Sanctum.Session.create(Sanctum.TestContext.issuer!(ctx))
      session
    end

    # The browser that started the flow, as LoginLive records it: the
    # session's CSRF token. `browser_conn/1` seeds the same value so the
    # request arrives as that browser.
    @browser_binding "device-ticket-test-browser"

    defp browser_conn(conn),
      do: Plug.Test.init_test_session(conn, %{"_csrf_token" => @browser_binding})

    defp mint_ticket(payload) do
      ticket = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      payload = Map.put_new(payload, :browser_binding, @browser_binding)
      Arca.Cache.put({:login_device_ticket, ticket}, payload, 60_000)
      ticket
    end

    test "of two requests presenting one ticket, one signs in", %{conn: conn} do
      session = mint_session()

      ticket =
        mint_ticket(%{
          session_token: session.token
        })

      signed_in =
        1..2
        |> Enum.map(fn _ ->
          Task.async(fn ->
            browser_conn(conn)
            |> get("/auth/device/complete/#{ticket}")
            |> Plug.Conn.get_session(:sanctum_session_token)
          end)
        end)
        |> Task.await_many(10_000)

      assert Enum.count(signed_in, &(&1 == session.token)) == 1
    end

    # Without this, the ticket is a bearer credential for someone else's
    # session: an attacker completes their own device flow, sends the link
    # to a victim, and the victim's browser is signed in as the attacker —
    # every document they then write lands in the attacker's athanor.
    test "a ticket opened by a different browser signs nobody in", %{conn: conn} do
      session = mint_session()

      ticket =
        mint_ticket(%{
          session_token: session.token
        })

      other_browser =
        Plug.Test.init_test_session(conn, %{"_csrf_token" => "a-different-browser"})

      conn = get(other_browser, "/auth/device/complete/#{ticket}")

      assert redirected_to(conn) == "/login"
      refute Plug.Conn.get_session(conn, :sanctum_session_token)
    end

    test "a ticket that names no browser is refused" do
      session = mint_session()

      # Bypasses mint_ticket/1's binding, the way a ticket minted before the
      # binding existed would look.
      ticket = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      Arca.Cache.put(
        {:login_device_ticket, ticket},
        %{
          session_token: session.token
        },
        60_000
      )

      conn = get(browser_conn(build_conn()), "/auth/device/complete/#{ticket}")

      assert redirected_to(conn) == "/login"
      refute Plug.Conn.get_session(conn, :sanctum_session_token)
    end

    test "a refused ticket is spent, not left for the right browser", %{conn: conn} do
      session = mint_session()

      ticket =
        mint_ticket(%{
          session_token: session.token
        })

      wrong = Plug.Test.init_test_session(conn, %{"_csrf_token" => "a-different-browser"})
      assert redirected_to(get(wrong, "/auth/device/complete/#{ticket}")) == "/login"

      # The rightful browser now finds nothing: a wrong presentation burns
      # the ticket rather than letting an attacker probe with it.
      retry = get(browser_conn(build_conn()), "/auth/device/complete/#{ticket}")
      assert redirected_to(retry) == "/login"
      refute Plug.Conn.get_session(retry, :sanctum_session_token)
    end
  end

  # The person an IdP identity key names: their own id, minted at admission.
  defp person_id(identity) do
    {:ok, %{id: id}} = Sanctum.Tenancy.Users.get_by_identity(identity)
    id
  end

  # The person the push tokens are stored as, as a context names them.
  defp person_context(identity),
    do:
      Sanctum.Context.build(
        user_id: person_id(identity),
        authenticated: true,
        auth_method: :oidc
      )

  describe "linking an OpenID Connect door" do
    setup do
      issuer!()

      person = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
      {:ok, session} = Sanctum.Session.create(person)
      {:ok, person: person, session: session}
    end

    defp link_auth(uid) do
      %Ueberauth.Auth{
        uid: uid,
        provider: :oidcc,
        info: %Ueberauth.Auth.Info{email: "#{uid}@idp.test", name: "Linked"},
        credentials: %Ueberauth.Auth.Credentials{token: "t", refresh_token: nil, expires: false},
        extra: %{}
      }
    end

    defp intent(person, session, overrides \\ %{}) do
      Map.merge(
        %{
          "user_id" => person.user_id,
          "session" =>
            Base.url_encode64(Sanctum.Session.token_hash(session.token), padding: false),
          "return_to" => "/a/test/settings",
          "expires_at" => System.system_time(:millisecond) + 60_000
        },
        overrides
      )
    end

    defp linked_callback(token, intent, auth) do
      build_conn()
      |> Plug.Test.init_test_session(%{
        sanctum_session_token: token,
        cyfr_link_intent: intent
      })
      |> assign(:ueberauth_auth, auth)
      |> PrismWeb.AuthController.callback(%{})
    end

    test "the start holds the intent for the session that asked, and returns only to settings",
         %{session: session, person: person} do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{sanctum_session_token: session.token})
        |> post("/auth/link/oidcc", %{"return_to" => "/a/test/settings"})

      assert redirected_to(conn) == "/auth/oidcc"
      held = get_session(conn, "cyfr_link_intent")
      assert held["user_id"] == person.user_id
      assert held["return_to"] == "/a/test/settings"

      elsewhere =
        build_conn()
        |> Plug.Test.init_test_session(%{sanctum_session_token: session.token})
        |> post("/auth/link/oidcc", %{"return_to" => "https://evil.example/a/x/settings"})

      assert get_session(elsewhere, "cyfr_link_intent")["return_to"] == "/"
    end

    test "with no session the start sends the browser to sign in" do
      conn = post(build_conn(), "/auth/link/oidcc", %{})
      assert redirected_to(conn) == "/login"
    end

    test "the callback mints a ticket for the session that asked, and signs no one in",
         %{session: session, person: person} do
      uid = "link-#{System.unique_integer([:positive])}"
      sessions = Arca.Repo.aggregate(Arca.Schemas.Session, :count)

      conn = linked_callback(session.token, intent(person, session), link_auth(uid))

      assert redirected_to(conn) == "/a/test/settings"
      assert %{"provider" => "oidcc", "ticket" => ticket} = get_session(conn, "cyfr_link_ticket")
      refute get_session(conn, "cyfr_link_intent")
      assert get_session(conn, :sanctum_session_token) == session.token
      refute conn.resp_body =~ ticket
      assert Arca.Repo.aggregate(Arca.Schemas.Session, :count) == sessions

      key = "oidcc|https://idp.test|#{uid}"
      assert {:error, :not_found} = Sanctum.Tenancy.Users.get_by_identity(key)

      {:ok, ctx} = Sanctum.Caller.establish(session.token, refresh: false)

      assert {:ok, %{linked: true}} =
               Sanctum.TestContext.confirming(
                 ctx,
                 &Sanctum.SignIn.link_door(&1, "oidcc", ticket)
               )

      assert {:ok, %{id: user_id}} = Sanctum.Tenancy.Users.get_by_identity(key)
      assert user_id == person.user_id
    end

    test "another session's, an expired intent, or a denied person's links nothing, and signs no one in",
         %{session: session, person: person} do
      other =
        Sanctum.TestContext.issuer!(%{
          Sanctum.TestContext.local()
          | user_id: "local|local|other-#{System.unique_integer([:positive])}"
        })

      {:ok, others} = Sanctum.Session.create(other)
      uid = "link-#{System.unique_integer([:positive])}"

      for {token, intent} <- [
            {others.token, intent(person, session)},
            {session.token, intent(person, session, %{"expires_at" => 0})}
          ] do
        conn = linked_callback(token, intent, link_auth(uid))
        assert conn.status == 401
        refute get_session(conn, "cyfr_link_ticket")
        assert get_session(conn, :sanctum_session_token) == token
      end

      # A person the door no longer admits holds no standing session to
      # link a method to.
      {:ok, row} = Sanctum.Tenancy.Users.get(person.user_id)
      {:ok, _} = Sanctum.Tenancy.Users.deny(row)
      conn = linked_callback(session.token, intent(person, session), link_auth(uid))
      assert conn.status == 401
      refute get_session(conn, "cyfr_link_ticket")

      assert {:error, :not_found} =
               Sanctum.Tenancy.Users.get_by_identity("oidcc|https://idp.test|#{uid}")
    end
  end

  describe "the cyfr door — the challenge hop and the callback" do
    alias Sanctum.Auth.CyfrDoor
    alias Sanctum.Test.DirectoryServer

    @cyfr_browser "cyfr-door-test-browser"

    setup do
      tls = DirectoryServer.tls()
      DirectoryServer.listen!()
      DirectoryServer.seam!(tls)
      Arca.Cache.init()

      on_exit(fn ->
        Arca.Cache.delete_match(Arca.Cache.Keys.match_identity_unreachable())
      end)

      directory = DirectoryServer.start!(tls)

      # An installation already set up: a remote newcomer is admitted only
      # where a person exists (`Sanctum.Newcomer`).
      {:ok, _} =
        Sanctum.Test.People.linked(%{
          id: "github|https://github.com|cyfr-door-installation",
          provider: "github"
        })

      identity = DirectoryServer.identity!(directory.dir, directory.url)
      %{fragment: fragment} = DirectoryServer.carry_fragment(identity, Sanctum.Person.home())
      {:ok, held} = CyfrDoor.challenge(fragment, :none)
      %{directory: directory, identity: identity, held: held}
    end

    defp cyfr_ticket(held, binding \\ @cyfr_browser) do
      ticket = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      Arca.Cache.put(
        {:login_cyfr_ticket, ticket},
        %{held: held, browser_binding: binding},
        60_000
      )

      ticket
    end

    # The browser's session as the start and the hop leave it: the
    # attempt's request, an address's for the challenge's CYFR unless one
    # is given (nil for none), beside the challenge.
    defp holding(conn, held, request \\ :address)

    defp holding(conn, held, :address),
      do: holding(conn, held, %{"home" => held["source"], "expires_at" => in_a_minute()})

    defp holding(conn, held, nil),
      do: Plug.Test.init_test_session(conn, %{"cyfr_challenge" => held})

    defp holding(conn, held, request) do
      Plug.Test.init_test_session(conn, %{"cyfr_challenge" => held, "cyfr_request" => request})
    end

    defp in_a_minute, do: System.os_time(:millisecond) + 60_000

    defp callback(conn, held, fragment, request \\ :address) do
      conn
      |> holding(held, request)
      |> post(~p"/auth/cyfr/callback", %{"fragment" => fragment})
    end

    test "the hop keeps the challenge in this browser's session and answers 303 to the carry's signed return URL",
         %{conn: conn, held: held} do
      ticket = cyfr_ticket(held)

      conn =
        conn
        |> Plug.Test.init_test_session(%{"_csrf_token" => @cyfr_browser})
        |> get("/auth/cyfr?" <> URI.encode_query(%{ticket: ticket}))

      assert conn.status == 303
      assert [location] = get_resp_header(conn, "location")
      assert location == CyfrDoor.redirect_url(held)
      assert String.starts_with?(location, "https://a.example/carry#")
      assert get_session(conn, "cyfr_challenge") == held
      assert Arca.Cache.get({:login_cyfr_ticket, ticket}) == :miss
    end

    test "a ticket another browser presents is spent and sends it back to sign in; a missing one too",
         %{conn: conn, held: held} do
      ticket = cyfr_ticket(held)

      wrong =
        conn
        |> Plug.Test.init_test_session(%{"_csrf_token" => "another-browser"})
        |> get("/auth/cyfr?" <> URI.encode_query(%{ticket: ticket}))

      assert redirected_to(wrong) == "/login"
      refute get_session(wrong, "cyfr_challenge")
      assert Arca.Cache.get({:login_cyfr_ticket, ticket}) == :miss

      assert redirected_to(get(build_conn(), "/auth/cyfr?ticket=nothing")) == "/login"
      assert redirected_to(get(build_conn(), "/auth/cyfr")) == "/login"
    end

    # Where the browser reports how the sign-in ended: the person's home's
    # `/carry`, the return URL the carry's envelope signed, with the outcome.
    defp carry_return(held, outcome) do
      {:ok, return} = Prima.Carry.Return.new(held["action_id"], outcome)
      "https://a.example/carry#" <> Prima.Carry.Return.fragment(return)
    end

    test "the callback admits under the challenge the session holds, sets the session and reports back to the person's home; a retry resumes it",
         %{conn: conn, held: held, identity: identity} do
      {:ok, _} = Sanctum.Door.Store.allow("identifier", identity.identifier, "test")
      fragment = DirectoryServer.assertion_fragment(identity, held, Sanctum.Person.home())

      # The sign-in's request, which the challenge answers.
      request = %{"home" => "https://a.example", "expires_at" => in_a_minute()}

      signed_in = callback(conn, held, fragment, request)

      assert redirected_to(signed_in, 303) == carry_return(held, :admitted)
      token = get_session(signed_in, :sanctum_session_token)
      assert token == CyfrDoor.session_token(held)
      refute get_session(signed_in, "cyfr_challenge")
      refute get_session(signed_in, "cyfr_request")

      # Admitted to nothing here: no athanor of their own is minted, and the
      # page they land on tells them so.
      landed = get(recycle(signed_in), "/")
      assert redirected_to(landed) == "/login?error=no_athanor"

      # The response was lost: the browser still holds the challenge and
      # the request, and its retry resumes the one session and reports the
      # same outcome.
      again = callback(build_conn(), held, fragment, request)
      assert redirected_to(again, 303) == carry_return(held, :admitted)
      assert get_session(again, :sanctum_session_token) == token
    end

    test "the callback admits only under a challenge that answers the request this browser's session holds: under none or another CYFR's it refuses, writing nothing",
         %{held: held, identity: identity} do
      {:ok, _} = Sanctum.Door.Store.allow("identifier", identity.identifier, "test")
      fragment = DirectoryServer.assertion_fragment(identity, held, Sanctum.Person.home())

      for {why, request} <- [
            {"no request", nil},
            {"another CYFR's", %{"home" => "https://b.example", "expires_at" => in_a_minute()}}
          ] do
        refused = callback(build_conn(), held, fragment, request)
        assert html_response(refused, 401) =~ "Sign-in failed", why
        refute get_session(refused, :sanctum_session_token), why
      end

      # Refused before the door was asked: no receipt, no person.
      assert Arca.CarryActions.receipt(
               Prima.Actor.system(),
               Sanctum.Person.home(),
               held["challenge_id"]
             ) == {:error, :not_found}

      assert {:error, :not_found} = Sanctum.Tenancy.Users.get_by_identifier(identity.identifier)

      # The same assertion under a request the challenge answers admits.
      admitted =
        callback(build_conn(), held, fragment, %{
          "home" => "https://a.example",
          "expires_at" => in_a_minute()
        })

      assert redirected_to(admitted, 303) == carry_return(held, :admitted)
      assert get_session(admitted, :sanctum_session_token) == CyfrDoor.session_token(held)
    end

    test "the assertion is posted as `fragment`, which the request log redacts; no other field is read",
         %{conn: conn, held: held, identity: identity} do
      {:ok, _} = Sanctum.Door.Store.allow("identifier", identity.identifier, "test")
      fragment = DirectoryServer.assertion_fragment(identity, held, Sanctum.Person.home())

      # The parameters Phoenix logs for this request, as its logger filters
      # them (`Prima.Sanitizer.filter_parameters/0`, installed at boot).
      assert %{"fragment" => "[FILTERED]"} =
               Phoenix.Logger.filter_values(%{"fragment" => fragment})

      # A field of another name admits nobody and keeps the challenge.
      refused =
        conn
        |> holding(held)
        |> post(~p"/auth/cyfr/callback", %{"cyfr" => fragment})

      refute get_session(refused, :sanctum_session_token)

      assert Arca.CarryActions.receipt(
               Prima.Actor.system(),
               Sanctum.Person.home(),
               held["challenge_id"]
             ) ==
               {:error, :not_found}
    end

    test "the report goes only to the signed source's fixed return URL, never to one the request names",
         %{conn: conn, held: held, identity: identity} do
      {:ok, _} = Sanctum.Door.Store.allow("identifier", identity.identifier, "test")
      fragment = DirectoryServer.assertion_fragment(identity, held, Sanctum.Person.home())

      signed_in =
        conn
        |> holding(held)
        |> post(~p"/auth/cyfr/callback", %{
          "fragment" => fragment,
          "return_url" => "https://evil.example/carry",
          "to" => "https://evil.example/"
        })

      assert redirected_to(signed_in, 303) == carry_return(held, :admitted)
    end

    test "an identity the door refuses gets 403, no session, and a link home reporting the refusal",
         %{conn: conn, held: held} = ctx do
      fragment = DirectoryServer.assertion_fragment(ctx.identity, held, Sanctum.Person.home())
      refused = callback(conn, held, fragment)

      body = html_response(refused, 403)
      assert body =~ "Not allowed on this server"
      assert body =~ "Back to Aqua"
      assert body =~ ~s(href="#{carry_return(held, :refused)}")
      refute get_session(refused, :sanctum_session_token)
    end

    test "an assertion for another audience, or no challenge held, signs nobody in",
         %{conn: conn, held: held, identity: identity} do
      {:ok, _} = Sanctum.Door.Store.allow("identifier", identity.identifier, "test")

      fragment =
        DirectoryServer.assertion_fragment(identity, held, Sanctum.Person.home(),
          audience: "https://elsewhere.example"
        )

      refused = callback(conn, held, fragment)
      body = html_response(refused, 401)
      assert body =~ "Begin it again from your CYFR"
      assert body =~ ~s(href="#{carry_return(held, :refused)}")
      refute get_session(refused, :sanctum_session_token)

      # A browser holding no challenge has no home to report to.
      unheld =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> post(~p"/auth/cyfr/callback", %{
          "fragment" => DirectoryServer.assertion_fragment(identity, held, Sanctum.Person.home())
        })

      refute html_response(unheld, 401) =~ "Back to Aqua"
      refute get_session(unheld, :sanctum_session_token)
    end

    test "a retried login under another assertion, after the first was admitted, reports nothing new",
         %{conn: conn, held: held, identity: identity} do
      {:ok, _} = Sanctum.Door.Store.allow("identifier", identity.identifier, "test")
      first = DirectoryServer.assertion_fragment(identity, held, Sanctum.Person.home())
      assert redirected_to(callback(conn, held, first), 303) == carry_return(held, :admitted)

      another =
        DirectoryServer.assertion_fragment(identity, held, Sanctum.Person.home(),
          expires_at: System.os_time(:millisecond) + 200_000
        )

      conflicted = callback(build_conn(), held, another)
      refute html_response(conflicted, 401) =~ "Back to Aqua"
    end

    test "a directory that cannot be read answers try again, signs nobody in, and reports nothing home",
         %{conn: conn, held: held, identity: identity, directory: directory} do
      {:ok, _} = Sanctum.Door.Store.allow("identifier", identity.identifier, "test")
      fragment = DirectoryServer.assertion_fragment(identity, held, Sanctum.Person.home())
      DirectoryServer.Server.stop(directory.server)

      paused = callback(conn, held, fragment)
      body = html_response(paused, 503)
      assert body =~ "Try again shortly"
      refute body =~ "Back to Aqua"
      refute get_session(paused, :sanctum_session_token)
    end
  end

  describe "cyfr_start/2 — the start of every cyfr sign-in" do
    @start_browser "cyfr-start-test-browser"
    @identifier "per_" <> String.duplicate("a", 52)

    setup do
      Arca.Cache.init()
      :ok
    end

    # The ticket the sign-in page mints for an attempt: the CYFR's origin
    # and its /carry, beside `attempt`.
    defp start_ticket(attempt \\ %{}) do
      ticket = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      {:ok, to} = Sanctum.Auth.CyfrDoor.signing_home("https://alice.example")

      Arca.Cache.put(
        {:login_cyfr_start, ticket},
        Map.merge(
          %{home: "https://alice.example", to: to, browser_binding: @start_browser},
          attempt
        ),
        60_000
      )

      {ticket, to}
    end

    # The start, presented by a browser whose session holds `session`
    # beside its forgery token.
    defp start(conn, query, session \\ %{}) do
      conn
      |> Plug.Test.init_test_session(Map.merge(%{"_csrf_token" => @start_browser}, session))
      |> get("/auth/cyfr/start" <> query)
    end

    test "keeps the attempt's request in this browser's session for the carry's lifetime, its home alone whatever else the ticket holds, and answers 303 to the CYFR's /carry" do
      lifetime = Sanctum.Auth.CyfrDoor.carry_lifetime_ms()
      kept = %{"home" => "https://alice.example"}

      for attempt <- [%{}, %{identifier: @identifier}] do
        {ticket, to} = start_ticket(attempt)
        before = System.os_time(:millisecond)

        started = start(build_conn(), "?" <> URI.encode_query(%{ticket: ticket}))

        assert started.status == 303
        assert get_resp_header(started, "location") == [to]

        assert to ==
                 "https://alice.example/carry#" <>
                   URI.encode_query(%{"destination" => Sanctum.Person.home()})

        {at, request} = Map.pop(get_session(started, "cyfr_request"), "expires_at")
        assert request == kept
        assert at >= before + lifetime and at <= System.os_time(:millisecond) + lifetime
        assert Arca.Cache.get({:login_cyfr_start, ticket}) == :miss

        # Spent: the same ticket again keeps nothing.
        again = start(build_conn(), "?" <> URI.encode_query(%{ticket: ticket}))
        assert redirected_to(again) == "/login"
        refute get_session(again, "cyfr_request")
      end
    end

    test "replaces the attempt the session held whole: its challenge goes, and the new request takes its request's place" do
      earlier = %{
        "home" => "https://alice.example",
        "expires_at" => System.os_time(:millisecond) + 60_000
      }

      held = %{
        "challenge_id" => "chl_earlier",
        "identifier" => @identifier,
        "source" => "https://alice.example"
      }

      {ticket, to} = start_ticket()

      started =
        start(build_conn(), "?" <> URI.encode_query(%{ticket: ticket}), %{
          "cyfr_challenge" => held,
          "cyfr_request" => earlier
        })

      assert get_resp_header(started, "location") == [to]
      refute get_session(started, "cyfr_challenge")

      assert started |> get_session("cyfr_request") |> Map.delete("expires_at") ==
               %{"home" => "https://alice.example"}
    end

    test "a ticket another browser presents is spent and keeps nothing; a missing one too",
         %{conn: conn} do
      {ticket, _to} = start_ticket()

      wrong =
        start(conn, "?" <> URI.encode_query(%{ticket: ticket}), %{
          "_csrf_token" => "another-browser"
        })

      assert redirected_to(wrong) == "/login"
      refute get_session(wrong, "cyfr_request")
      assert Arca.Cache.get({:login_cyfr_start, ticket}) == :miss

      for query <- ["?ticket=nothing", ""] do
        refused = start(build_conn(), query)
        assert redirected_to(refused) == "/login"
        refute get_session(refused, "cyfr_request")
      end
    end
  end
end
