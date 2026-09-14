# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.AuthControllerTest do
  @moduledoc """
  Tests for the sign-in controller.

  Tests cover:
  - request/2: Unknown provider handling
  - callback/2: Success and failure cases
  - logout/2: Session destruction
  - whoami/2: Current user info
  """
  use EmissaryWeb.ConnCase

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
      original = Application.get_env(:cyfr, :auth_provider)
      Application.put_env(:cyfr, :auth_provider, Sanctum.Test.AltAuthProvider)
      # The door: these callbacks sign in whoever the provider authenticates.
      {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "test")

      # Point the cyfr.run REST client at an unreachable address so the
      # post-session probe fails fast with a transient error rather than
      # reaching the public cyfr.run.
      original_registry = Application.get_env(:cyfr, :registry_url)
      Application.put_env(:cyfr, :registry_url, "127.0.0.1:19")

      on_exit(fn ->
        if original do
          Application.put_env(:cyfr, :auth_provider, original)
        else
          Application.delete_env(:cyfr, :auth_provider)
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
        |> EmissaryWeb.AuthController.callback(%{})

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
        |> EmissaryWeb.AuthController.callback(%{})

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
        |> EmissaryWeb.AuthController.callback(%{})

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
        |> EmissaryWeb.AuthController.callback(%{})

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
        |> EmissaryWeb.AuthController.callback(%{})

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
      # ConnCase (parent) already checks out the Arca.Repo sandbox — don't
      # re-check-out here (raises {:already, :owner}). The sandbox mode needs
      # to be :shared so the Bypass plug request process can see the sandbox
      # connection, matching CredentialStore writes in the test process.
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

      original_provider = Application.get_env(:cyfr, :auth_provider)
      Application.put_env(:cyfr, :auth_provider, Sanctum.Test.AltAuthProvider)
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
          do: Application.put_env(:cyfr, :auth_provider, original_provider),
          else: Application.delete_env(:cyfr, :auth_provider)

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
      |> EmissaryWeb.AuthController.callback(%{})
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
               CredentialStore.get(person_id(user_id), "registry.test", ns)

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
      previous = Application.get_env(:cyfr, :caps, [])
      Application.put_env(:cyfr, :caps, max_athanors: 1)
      on_exit(fn -> Application.put_env(:cyfr, :caps, previous) end)

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
      prev = Application.get_env(:cyfr, :platform_admin_emails, [])
      Application.put_env(:cyfr, :platform_admin_emails, [email])
      on_exit(fn -> Application.put_env(:cyfr, :platform_admin_emails, prev) end)

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

      assert :not_found = CredentialStore.get(person_id(user_id), "registry.test", "alice")
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
      assert :not_found = CredentialStore.get(person_id(user_id), "registry.test", "alice")
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
      # Force at-rest encryption to fail by clearing the resolved keyring:
      # CredentialStore.put → Sanctum.Cipher.encrypt raises without it.
      original_keyring = Application.get_env(:cyfr, :crypto_keyring)
      Application.delete_env(:cyfr, :crypto_keyring)

      on_exit(fn ->
        if original_keyring,
          do: Application.put_env(:cyfr, :crypto_keyring, original_keyring),
          else: Application.delete_env(:cyfr, :crypto_keyring)
      end)

      n = System.unique_integer([:positive])
      uid = "auth_cb_putfail_#{n}"
      user_id = "oidcc|https://idp.test|#{uid}"

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
      assert :not_found = CredentialStore.get(person_id(user_id), "registry.test", ns)
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

  describe "logout/2" do
    test "returns error when no token provided via Bearer header", %{conn: conn} do
      # Use Bearer auth header (no session cookie)
      conn =
        conn
        |> put_req_header("authorization", "Bearer ")
        |> delete(~p"/auth/logout")

      # Empty bearer token should fall through to missing_token
      assert json_response(conn, 400)["code"] == "missing_token"
    end

    test "a token in the request body is ignored", %{conn: conn} do
      # A credential in a body or query string lands in access logs and
      # Referer headers. The header is the only way into the API logout;
      # POST routes to the browser sign-out (CSRF-guarded), which reads
      # only the cookie session and never the body.
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/auth/logout", Jason.encode!(%{"token" => "nonexistent_token"}))

      assert redirected_to(conn) == "/login?error=signed_out"
    end

    test "ignores a body token on the routed verb", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> delete(~p"/auth/logout", Jason.encode!(%{"token" => "nonexistent_token"}))

      assert json_response(conn, 400)["code"] == "missing_token"
    end

    test "accepts token via Bearer header", %{conn: conn} do
      # Session.destroy is idempotent - destroying nonexistent token returns :ok
      conn =
        conn
        |> put_req_header("authorization", "Bearer nonexistent_token")
        |> delete(~p"/auth/logout")

      response = json_response(conn, 200)
      assert response["ok"] == true
    end
  end

  describe "whoami/2" do
    test "returns unauthorized when no token provided", %{conn: conn} do
      conn = get(conn, ~p"/auth/whoami")

      assert json_response(conn, 401)["code"] == "auth_required"
      assert json_response(conn, 401)["error"] == "No session token provided"
    end

    test "returns invalid_session for nonexistent token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer nonexistent_token")
        |> get(~p"/auth/whoami")

      assert json_response(conn, 401)["code"] == "invalid_session"
    end

    test "returns session info for valid token", %{conn: conn} do
      # Create a real session
      ctx =
        Sanctum.Context.build(
          user_id: "user_whoami_test",
          email: "whoami@example.com",
          provider: "github",
          permissions: [:execute, :read],
          namespace: "testns",
          authenticated: true
        )

      {:ok, session} = Sanctum.Session.create(ctx)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{session.token}")
        |> get(~p"/auth/whoami")

      response = json_response(conn, 200)
      assert response["ok"] == true
      assert response["session"]["user_id"] == "user_whoami_test"
      assert response["session"]["email"] == "whoami@example.com"
      assert response["session"]["provider"] == "github"
      assert response["session"]["created_at"] != nil
      assert response["session"]["expires_at"] != nil

      # Clean up
      Sanctum.Session.destroy(session.token)
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

      {:ok, session} = Sanctum.Session.create(ctx)
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
end
