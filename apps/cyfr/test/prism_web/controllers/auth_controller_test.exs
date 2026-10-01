# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AuthControllerTest do
  @moduledoc """
  Tests for the browser's sign-in controller.

  Tests cover:
  - request/2: Unknown provider handling
  - callback/2: Success and failure cases
  - device_complete/2: The device-flow ticket
  - post_legal_accept/2: The probe after policy acceptance
  """
  use CyfrWeb.ConnCase

  import Ecto.Query, only: [from: 2]

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
      original = Application.get_env(:sanctum, :auth_provider)
      Application.put_env(:sanctum, :auth_provider, Sanctum.Test.AltAuthProvider)
      # The door: these callbacks sign in whoever the provider authenticates.
      {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "test")

      # Point the cyfr.run REST client at an unreachable address so the
      # post-session probe fails fast with a transient error rather than
      # reaching the public cyfr.run.
      original_registry = Application.get_env(:cyfr, :registry_url)
      Application.put_env(:cyfr, :registry_url, "127.0.0.1:19")

      on_exit(fn ->
        if original do
          Application.put_env(:sanctum, :auth_provider, original)
        else
          Application.delete_env(:sanctum, :auth_provider)
        end

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
        |> assign(:ueberauth_failure, failure)
        |> PrismWeb.AuthController.callback(%{})

      assert html_response(conn, 401) =~ "Sign-in failed"
      assert html_response(conn, 401) =~ "Access denied"
    end

    test "a callback for an identity the door refuses gets a 403 and no session", %{conn: conn} do
      # Take the wildcard away: only the operators may sign in now.
      [entry] = Sanctum.Door.Store.list()
      :ok = Sanctum.Door.Store.remove(entry.id)

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
      assert conn.resp_body =~ "not allowed on this server"
      refute get_session(conn, :sanctum_session_token)
      user_id = "oidcc|https://idp.test|99999"
      assert {:error, :not_found} = Sanctum.Tenancy.Users.get_by_identity(user_id)
    end

    test "a denied identity is refused even when the door is *", %{conn: conn} do
      {:ok, _} = Sanctum.Door.Store.deny("email", "banned@example.com", "test")

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

    test "a first-time person signs in on their own athanor even with cyfr.run unreachable",
         %{conn: conn} do
      uid = "first-#{System.unique_integer([:positive])}"
      user_id = "oidcc|https://idp.test|#{uid}"

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> assign(:ueberauth_auth, oidcc_auth(uid, "test@example.com"))
        |> PrismWeb.AuthController.callback(%{})

      assert redirected_to(conn) == "/"
      assert is_binary(Plug.Conn.get_session(conn, :sanctum_session_token))

      assert {:ok, %{namespace: nil, personal_athanor_id: pid}} =
               Sanctum.Tenancy.Users.get(person_id(user_id))

      assert {:ok, %{kind: "person", owner_user_id: owner}} = Sanctum.Tenancy.Athanors.get(pid)
      assert owner == person_id(user_id)
    end

    test "a returning person signs in and lands in the chat even with cyfr.run unreachable",
         %{conn: conn} do
      uid = "back-#{System.unique_integer([:positive])}"
      user_id = "oidcc|https://idp.test|#{uid}"

      {:ok, user} =
        Sanctum.Tenancy.Users.upsert_from_provider(%{
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
      assert {:ok, %{authenticated: true}} = Sanctum.Session.load(token, surface: :console)
      # The token travels in the cookie only.
      refute conn.resp_body =~ token
    end
  end

  describe "callback/2 — probe integration (Bypass)" do
    alias Compendium.Registry.CredentialStore

    setup do
      original_provider = Application.get_env(:sanctum, :auth_provider)
      Application.put_env(:sanctum, :auth_provider, Sanctum.Test.AltAuthProvider)
      {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "test")

      bypass = Bypass.open()
      original_url = Application.get_env(:cyfr, :registry_url)
      original_scheme = Application.get_env(:cyfr, :registry_scheme)
      original_oci = Application.get_env(:cyfr, :oci_registry_url)

      Application.put_env(:cyfr, :registry_url, "127.0.0.1:#{bypass.port}")
      Application.put_env(:cyfr, :registry_scheme, "http")
      Application.put_env(:cyfr, :oci_registry_url, "registry.test")

      on_exit(fn ->
        if original_provider,
          do: Application.put_env(:sanctum, :auth_provider, original_provider),
          else: Application.delete_env(:sanctum, :auth_provider)

        if original_url,
          do: Application.put_env(:cyfr, :registry_url, original_url),
          else: Application.delete_env(:cyfr, :registry_url)

        if original_scheme,
          do: Application.put_env(:cyfr, :registry_scheme, original_scheme),
          else: Application.delete_env(:cyfr, :registry_scheme)

        if original_oci,
          do: Application.put_env(:cyfr, :oci_registry_url, original_oci),
          else: Application.delete_env(:cyfr, :oci_registry_url)
      end)

      {:ok, bypass: bypass}
    end

    defp json_resp(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
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

    # SQL-sandbox rollback between tests races with Bypass/Finch worker
    # processes that outlive the test process, so writes to CredentialStore
    # can leak across tests. Each test uses a unique uid so writes don't
    # collide.

    defp callback(conn, auth) do
      # The pending-probe cookie is encrypted: the conn needs a key base, as
      # the endpoint gives it in production.
      %{conn | secret_key_base: String.duplicate("a", 64)}
      |> Plug.Test.init_test_session(%{})
      |> Phoenix.ConnTest.fetch_flash()
      |> assign(:ueberauth_auth, auth)
      |> PrismWeb.AuthController.callback(%{})
    end

    defp session_of(conn), do: Plug.Conn.get_session(conn, :sanctum_session_token)

    test "happy path: namespace recorded, tokens stored, redirect to the chat",
         %{conn: conn, bypass: bypass} do
      n = System.unique_integer([:positive])
      uid = "auth_cb_happy_#{n}"
      user_id = "oidcc|https://idp.test|#{uid}"

      Bypass.expect_once(bypass, "POST", "/v1/identity/probe", fn c ->
        json_resp(c, 200, %{
          "personal_namespace" => %{"slug" => "alice#{n}", "token" => "cyfr_pt_personal"},
          "memberships" => []
        })
      end)

      conn = callback(conn, verified_oidcc_auth(uid))

      assert redirected_to(conn) == "/"
      assert is_binary(session_of(conn))
      assert {:ok, %{namespace: ns}} = Sanctum.Tenancy.Users.get(person_id(user_id))
      assert ns == "alice#{n}"

      assert {:ok, %{token: "cyfr_pt_personal", role: "personal"}} =
               CredentialStore.get(person_context(user_id), "registry.test", ns)

      # The session is a working one: the person is authenticated at once...
      assert {:ok, %{authenticated: true, namespace: ^ns} = loaded} =
               Sanctum.Session.load(session_of(conn), surface: :console)

      # ...and it names their own athanor, minted at admission. Its address
      # is the namespace only when the namespace was known first.
      assert {:ok, %{id: personal_id, kind: "person"}} =
               Sanctum.Tenancy.Athanors.get_by_owner(person_id(user_id))

      assert loaded.athanor_id == personal_id
    end

    test "signing in does not carry the pre-login session across",
         %{conn: conn, bypass: bypass} do
      # The anonymous session's `_csrf_token` is what binds a device-flow
      # ticket to a browser, so anything an attacker could plant on this
      # origin before sign-in must not survive it. Nothing set before the
      # exchange is still readable after.
      n = System.unique_integer([:positive])
      uid = "auth_cb_renew_#{n}"

      Bypass.expect_once(bypass, "POST", "/v1/identity/probe", fn c ->
        json_resp(c, 200, %{
          "personal_namespace" => %{"slug" => "renew#{n}", "token" => "cyfr_pt_personal"},
          "memberships" => []
        })
      end)

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

    test "a full server turns a stranger away with a capacity answer and no session",
         %{conn: conn} do
      # Nothing is shared server-wide for a refused mint to fall back on, so
      # admitting the person without an athanor would hand them a session
      # with nowhere to work. The door says so instead.
      Cyfr.Test.Settings.put("max_athanors", 1)

      n = System.unique_integer([:positive])
      conn = callback(conn, verified_oidcc_auth("full_#{n}", email: "full#{n}@example.com"))

      body = html_response(conn, 401)
      assert body =~ "full"
      refute body =~ "An error occurred during authentication"
      refute session_of(conn)
    end

    test "an operator's first sign-in lands in their own athanor",
         %{conn: conn, bypass: bypass} do
      n = System.unique_integer([:positive])
      uid = "auth_cb_ops_#{n}"
      email = "ops#{n}@example.com"
      prev = Application.get_env(:sanctum, :platform_admin_emails, [])
      Application.put_env(:sanctum, :platform_admin_emails, [email])
      on_exit(fn -> Application.put_env(:sanctum, :platform_admin_emails, prev) end)

      Bypass.expect_once(bypass, "POST", "/v1/identity/probe", fn c ->
        json_resp(c, 200, %{
          "personal_namespace" => %{"slug" => "ops#{n}", "token" => "cyfr_pt_personal"},
          "memberships" => []
        })
      end)

      conn = callback(conn, verified_oidcc_auth(uid, email: email))

      assert redirected_to(conn) == "/"

      # Their own athanor is minted at admission and is what the session
      # names; the operator bit is a platform row beside it, not a seat.
      assert {:ok, %{id: personal_id}} =
               Sanctum.Tenancy.Athanors.get_by_owner(person_id("oidcc|https://idp.test|#{uid}"))

      assert {:ok, %{athanor_id: ^personal_id, platform_admin: true}} =
               Sanctum.Session.load(session_of(conn), surface: :console)
    end

    test "no personal namespace: signed in on their own athanor, IdP token kept for the claim",
         %{conn: conn, bypass: bypass} do
      uid = "auth_cb_unclaimed_#{System.unique_integer([:positive])}"
      user_id = "oidcc|https://idp.test|#{uid}"

      Bypass.expect_once(bypass, "POST", "/v1/identity/probe", fn c ->
        json_resp(c, 200, %{"personal_namespace" => nil, "memberships" => []})
      end)

      conn = callback(conn, verified_oidcc_auth(uid))

      assert redirected_to(conn) == "/"
      assert is_binary(session_of(conn))
      assert Map.has_key?(conn.resp_cookies, "_cyfr_pending_probe")

      assert {:ok, %{personal_athanor_id: pid}} = Sanctum.Tenancy.Users.get(person_id(user_id))
      assert is_binary(pid)

      assert {:ok, %{authenticated: true, namespace: nil, athanor_id: ^pid}} =
               Sanctum.Session.load(session_of(conn), surface: :console)

      assert {:error, :not_found} =
               CredentialStore.get(person_context(user_id), "registry.test", "alice")
    end

    test "412: signed in, the policy owed at publish, IdP token kept", %{
      conn: conn,
      bypass: bypass
    } do
      uid = "auth_cb_412_#{System.unique_integer([:positive])}"

      Bypass.expect_once(bypass, "POST", "/v1/identity/probe", fn c ->
        json_resp(c, 412, %{"errors" => [%{"code" => "POLICY_ACCEPTANCE_REQUIRED"}]})
      end)

      conn = callback(conn, verified_oidcc_auth(uid))
      assert redirected_to(conn) == "/"
      assert is_binary(session_of(conn))
      assert Map.has_key?(conn.resp_cookies, "_cyfr_pending_probe")
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "updated its policy"
    end

    test "probe 401: signed in, the refusal flashed, nothing cached", %{
      conn: conn,
      bypass: bypass
    } do
      uid = "auth_cb_401_#{System.unique_integer([:positive])}"
      user_id = "oidcc|https://idp.test|#{uid}"

      Bypass.expect_once(bypass, "POST", "/v1/identity/probe", fn c ->
        json_resp(c, 401, %{"error" => "invalid_access_token"})
      end)

      conn = callback(conn, verified_oidcc_auth(uid, token: "expired_token"))

      assert redirected_to(conn) == "/"
      assert is_binary(session_of(conn))
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "refused the sign-in token"

      assert {:error, :not_found} =
               CredentialStore.get(person_context(user_id), "registry.test", "alice")
    end

    test "probe 5xx: a first-time person and a returning one both sign in",
         %{conn: conn, bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/identity/probe", fn c ->
        json_resp(c, 500, %{"error" => "internal"})
      end)

      uid = "auth_cb_5xx_#{System.unique_integer([:positive])}"
      conn1 = callback(conn, verified_oidcc_auth(uid))
      assert redirected_to(conn1) == "/"
      assert is_binary(session_of(conn1))
      assert Phoenix.Flash.get(conn1.assigns.flash, :error) =~ "couldn't be reached"

      n = System.unique_integer([:positive])
      back = "auth_cb_5xx_back_#{n}"

      {:ok, user} =
        Sanctum.Tenancy.Users.upsert_from_provider(%{
          id: "oidcc|https://idp.test|#{back}",
          provider: "oidcc",
          email: "alice@example.com",
          verified: true
        })

      {:ok, _} = Sanctum.Tenancy.Users.set_namespace(user, "back#{n}")
      conn2 = callback(build_conn(), verified_oidcc_auth(back))
      assert redirected_to(conn2) == "/"
      assert is_binary(session_of(conn2))
      assert Phoenix.Flash.get(conn2.assigns.flash, :error) =~ "couldn't be reached"
    end

    test "the namespace is the identity: a push token that cannot be stored still signs the person in",
         %{conn: conn, bypass: bypass} do
      n = System.unique_integer([:positive])
      uid = "auth_cb_putfail_#{n}"
      user_id = "oidcc|https://idp.test|#{uid}"

      # The person exists before the keyring goes: a first sign-in seals
      # the person's own keys, and one that cannot is refused.
      {:ok, _person} =
        Sanctum.Tenancy.Users.upsert_from_provider(%{
          id: user_id,
          provider: "oidcc",
          email: "alice@example.com",
          verified: true
        })

      # Force at-rest encryption to fail by clearing the resolved keyring:
      # the push-token seal (`Sanctum.Cipher.encrypt`) raises without it.
      original_keyring = Application.get_env(:sanctum, :crypto_keyring)
      Application.delete_env(:sanctum, :crypto_keyring)

      on_exit(fn ->
        if original_keyring,
          do: Application.put_env(:sanctum, :crypto_keyring, original_keyring),
          else: Application.delete_env(:sanctum, :crypto_keyring)
      end)

      Bypass.expect_once(bypass, "POST", "/v1/identity/probe", fn c ->
        json_resp(c, 200, %{
          "personal_namespace" => %{"slug" => "alice#{n}", "token" => "cyfr_pt_personal"},
          "memberships" => []
        })
      end)

      conn = callback(conn, verified_oidcc_auth(uid))

      assert redirected_to(conn) == "/"
      assert {:ok, %{namespace: ns}} = Sanctum.Tenancy.Users.get(person_id(user_id))
      assert ns == "alice#{n}"

      assert {:error, :not_found} =
               CredentialStore.get(person_context(user_id), "registry.test", ns)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "didn't fully sync"
    end

    test "no browser outcome is a JSON document, and no body carries a session token",
         %{conn: conn, bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/identity/probe", fn c ->
        json_resp(c, 500, %{"error" => "internal"})
      end)

      uid = "auth_cb_nojson_#{System.unique_integer([:positive])}"

      # The registry down, and the IdP giving no token: a redirect each time.
      for auth <- [verified_oidcc_auth(uid), verified_oidcc_auth(uid, token: nil)] do
        conn = callback(conn, auth)
        assert conn.status == 302
        refute Enum.any?(Plug.Conn.get_resp_header(conn, "content-type"), &(&1 =~ "json"))
        refute conn.resp_body =~ "session_token"
      end
    end
  end

  describe "device_complete/2 — the ticket carries the outcome" do
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

    test "a proceed ticket flashes the report's warnings", %{conn: conn} do
      # The device path once decoded the ticket's :next flag and dropped
      # the report entirely — unsynced-token warnings the Ueberauth
      # callback flashed were silently lost on device sign-in.
      session = mint_session()

      ticket =
        mint_ticket(%{
          session_token: session.token,
          access_token: nil,
          outcome: {:proceed, %{unsynced: ["ns1"], probe: :ok}}
        })

      conn = get(browser_conn(conn), "/auth/device/complete/#{ticket}")

      assert redirected_to(conn) == "/"
      assert Plug.Conn.get_session(conn, :sanctum_session_token) == session.token
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "didn't fully sync"
    end

    test "of two requests presenting one ticket, one signs in", %{conn: conn} do
      session = mint_session()

      ticket =
        mint_ticket(%{
          session_token: session.token,
          access_token: nil,
          outcome: {:proceed, %{unsynced: [], probe: :ok}}
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
          session_token: session.token,
          access_token: nil,
          outcome: {:proceed, %{unsynced: [], probe: :ok}}
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
          session_token: session.token,
          access_token: nil,
          outcome: {:proceed, %{unsynced: [], probe: :ok}}
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
          session_token: session.token,
          access_token: nil,
          outcome: {:proceed, %{unsynced: [], probe: :ok}}
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
      original = Application.get_env(:sanctum, :auth_provider)
      Application.put_env(:sanctum, :auth_provider, Sanctum.Test.AltAuthProvider)
      {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "test")

      on_exit(fn ->
        if original,
          do: Application.put_env(:sanctum, :auth_provider, original),
          else: Application.delete_env(:sanctum, :auth_provider)
      end)

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

      {:ok, ctx} = Sanctum.Caller.establish(session.token, task_supervisor: nil)

      assert {:ok, %{linked: true}} =
               Sanctum.TestContext.confirming(
                 ctx,
                 &Sanctum.SignIn.link_door(&1, "oidcc", ticket)
               )

      assert {:ok, %{id: user_id}} = Sanctum.Tenancy.Users.get_by_identity(key)
      assert user_id == person.user_id
    end

    test "another session's, an expired or a refused intent links nothing, and signs no one in",
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

      [entry] = Enum.filter(Sanctum.Door.Store.list(), &(&1.kind == "wildcard"))
      :ok = Sanctum.Door.Store.remove(entry.id)
      conn = linked_callback(session.token, intent(person, session), link_auth(uid))
      assert conn.status == 403
      refute get_session(conn, "cyfr_link_ticket")

      assert {:error, :not_found} =
               Sanctum.Tenancy.Users.get_by_identity("oidcc|https://idp.test|#{uid}")
    end
  end

  describe "post_legal_accept/2 — the probe runs only for a session that stands" do
    setup do
      # cyfr.run unreachable, so a probe that does run answers at once.
      prev = Application.get_env(:cyfr, :registry_url)
      Application.put_env(:cyfr, :registry_url, "127.0.0.1:19")

      on_exit(fn ->
        if prev,
          do: Application.put_env(:cyfr, :registry_url, prev),
          else: Application.delete_env(:cyfr, :registry_url)
      end)

      person = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
      {:ok, session} = Sanctum.Session.create(person)
      {:ok, session: session}
    end

    defp probe_cookie do
      secret = CyfrWeb.Endpoint.config(:secret_key_base)

      %{value: value} =
        build_conn()
        |> Map.put(:secret_key_base, secret)
        |> put_resp_cookie("_cyfr_pending_probe", "gho_probe", encrypt: true, max_age: 600)
        |> Map.fetch!(:resp_cookies)
        |> Map.fetch!("_cyfr_pending_probe")

      value
    end

    defp post_legal_accept(token) do
      build_conn()
      |> Plug.Test.init_test_session(%{sanctum_session_token: token})
      |> Plug.Test.put_req_cookie("_cyfr_pending_probe", probe_cookie())
      |> get("/auth/post-legal-accept")
    end

    test "a standing session completes the sign-in", %{session: session} do
      refute redirected_to(post_legal_accept(session.token)) == "/login"
    end

    test "a session revoked with nobody told is sent to sign in, not probed", %{session: session} do
      hash = Sanctum.Session.token_hash(session.token)

      Arca.Repo.delete_all(from(s in Arca.Schemas.Session, where: s.token_hash == ^hash))

      assert redirected_to(post_legal_accept(session.token)) == "/login"
    end

    test "a store that cannot answer says try again, and signs nobody in", %{session: session} do
      Arca.Repo.query!("ALTER TABLE sessions RENAME TO sessions_unavailable")
      conn = post_legal_accept(session.token)
      assert conn.status == 503
      assert conn.resp_body =~ "Try again shortly"
    end

    test "a remote person whose identity could not be confirmed fresh is told to try again, " <>
           "their session standing",
         %{session: session} do
      stale_remote!(session.user_id)

      {conn, log} = ExUnit.CaptureLog.with_log(fn -> post_legal_accept(session.token) end)

      assert log =~ "freshness bound"
      assert conn.status == 503
      assert conn.resp_body =~ "Try again shortly"

      hash = Sanctum.Session.token_hash(session.token)
      assert Arca.Repo.exists?(from(s in Arca.Schemas.Session, where: s.token_hash == ^hash))
    end

    # `person_id` made a person whose keys are at another home: their
    # identity row `remote`, their head cached but past its bound, and their
    # directory a loopback port nothing listens on, so it cannot be
    # refreshed.
    defp stale_remote!(person_id) do
      directory = "https://localhost:1"

      Arca.Repo.delete_all(from(p in Arca.Schemas.PersonIdentity, where: p.user_id == ^person_id))

      {live, _} = :crypto.generate_key(:eddsa, :ed25519)
      {operational_pub, operational} = :crypto.generate_key(:eddsa, :ed25519)
      {recovery, _} = :crypto.generate_key(:eddsa, :ed25519)

      {:ok, genesis} =
        Prima.Identity.Entry.genesis(
          live_key: live,
          operational_key: operational_pub,
          recovery_keys: [recovery],
          directory: directory
        )

      genesis = Prima.Identity.sign(genesis, operational)
      identifier = Prima.Identity.identifier(genesis)
      head = Prima.Identity.hash(genesis)

      {:ok, _} =
        Arca.PersonIdentities.create(Prima.Actor.system(), %{
          user_id: person_id,
          provenance: "remote",
          identifier: identifier,
          directory_url: directory
        })

      {:ok, _} =
        Arca.DirectoryHeads.put(Prima.Actor.system(), %{
          identifier: identifier,
          genesis: Prima.Identity.canonical(genesis),
          directory_url: directory,
          head_hash: head,
          key_epoch: head,
          recovery_epoch: head,
          state: ~s({"head":"#{head}"})
        })

      Arca.Repo.update_all(
        from(h in Arca.Schemas.DirectoryHead, where: h.identifier == ^identifier),
        set: [verified_at: DateTime.add(DateTime.utc_now(), -400, :second)]
      )

      :ok
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
      identity = DirectoryServer.identity!(directory.dir, directory.url)
      %{fragment: fragment} = DirectoryServer.carry_fragment(identity, Sanctum.Person.home())
      {:ok, held} = CyfrDoor.challenge(fragment)
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

    defp holding(conn, held),
      do: Plug.Test.init_test_session(conn, %{"cyfr_challenge" => held})

    defp callback(conn, held, fragment),
      do: conn |> holding(held) |> post(~p"/auth/cyfr/callback", %{"cyfr" => fragment})

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

      signed_in = callback(conn, held, fragment)
      assert redirected_to(signed_in, 303) == carry_return(held, :admitted)
      token = get_session(signed_in, :sanctum_session_token)
      assert token == CyfrDoor.session_token(held)
      refute get_session(signed_in, "cyfr_challenge")

      # Admitted to nothing here: no athanor of their own is minted, and the
      # page they land on tells them so.
      landed = get(recycle(signed_in), "/")
      assert redirected_to(landed) == "/login?error=no_athanor"

      # The response was lost: the browser still holds the challenge, and
      # its retry resumes the one session and reports the same outcome.
      again = callback(build_conn(), held, fragment)
      assert redirected_to(again, 303) == carry_return(held, :admitted)
      assert get_session(again, :sanctum_session_token) == token
    end

    test "the report goes only to the signed source's fixed return URL, never to one the request names",
         %{conn: conn, held: held, identity: identity} do
      {:ok, _} = Sanctum.Door.Store.allow("identifier", identity.identifier, "test")
      fragment = DirectoryServer.assertion_fragment(identity, held, Sanctum.Person.home())

      signed_in =
        conn
        |> holding(held)
        |> post(~p"/auth/cyfr/callback", %{
          "cyfr" => fragment,
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
      assert body =~ "Back to your home"
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
      assert body =~ "Begin it again from your home"
      assert body =~ ~s(href="#{carry_return(held, :refused)}")
      refute get_session(refused, :sanctum_session_token)

      # A browser holding no challenge has no home to report to.
      unheld =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> post(~p"/auth/cyfr/callback", %{
          "cyfr" => DirectoryServer.assertion_fragment(identity, held, Sanctum.Person.home())
        })

      refute html_response(unheld, 401) =~ "Back to your home"
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
      refute html_response(conflicted, 401) =~ "Back to your home"
    end

    test "a directory that cannot be read answers try again, signs nobody in, and reports nothing home",
         %{conn: conn, held: held, identity: identity, directory: directory} do
      {:ok, _} = Sanctum.Door.Store.allow("identifier", identity.identifier, "test")
      fragment = DirectoryServer.assertion_fragment(identity, held, Sanctum.Person.home())
      DirectoryServer.Server.stop(directory.server)

      paused = callback(conn, held, fragment)
      body = html_response(paused, 503)
      assert body =~ "Try again shortly"
      refute body =~ "Back to your home"
      refute get_session(paused, :sanctum_session_token)
    end
  end
end
