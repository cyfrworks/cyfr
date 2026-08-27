# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.AuthControllerTest do
  @moduledoc """
  Tests for the OAuth authentication controller.

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

    test "GET /auth/github without web-callback credentials is 404, not 500", %{conn: conn} do
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
      # post-session probe fails with `:registry_unavailable` (generic
      # transient error) rather than a real network 401 against the public
      # cyfr.run (which would correctly trigger the `:invalid_access_token`
      # reauth redirect). Tests that specifically cover the reauth redirect
      # live separately.
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
      conn = get(conn, ~p"/auth/github/callback")

      assert html_response(conn, 400) =~ "Invalid sign-in callback"
    end

    test "handles ueberauth failure", %{conn: conn} do
      # Simulate Ueberauth failure
      failure = %Ueberauth.Failure{
        provider: :github,
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
        provider: :github,
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
      user_id = Sanctum.Auth.Identity.builtin_user_id(:github, "99999")
      assert {:error, :not_found} = Sanctum.Tenancy.Users.get(user_id)
    end

    test "a denied identity is refused even when the door is *", %{conn: conn} do
      {:ok, _} = Sanctum.Door.Store.deny("email", "banned@example.com", "test")

      auth = %Ueberauth.Auth{
        uid: "77777",
        provider: :github,
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

    defp github_auth(uid, email) do
      %Ueberauth.Auth{
        uid: uid,
        provider: :github,
        info: %Ueberauth.Auth.Info{email: email, name: "Test User"},
        credentials: %Ueberauth.Auth.Credentials{
          token: "gho_mock_access_token",
          refresh_token: nil,
          expires: false
        },
        extra: %{}
      }
    end

    test "a first-time person whom cyfr.run cannot place gets a page, no session, no cookie",
         %{conn: conn} do
      uid = "first-#{System.unique_integer([:positive])}"

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> assign(:ueberauth_auth, github_auth(uid, "test@example.com"))
        |> EmissaryWeb.AuthController.callback(%{})

      assert conn.status == 503
      assert conn.resp_body =~ "cyfr.run could not be reached"
      assert conn.resp_body =~ "Try again"
      refute Plug.Conn.get_session(conn, :sanctum_session_token)
      refute Map.has_key?(conn.resp_cookies, "_cyfr_pending_probe")
      refute Enum.any?(Plug.Conn.get_resp_header(conn, "content-type"), &(&1 =~ "json"))
      # Nothing was set up: no users row is left carrying a namespace.
      assert {:ok, %{namespace: nil}} =
               Sanctum.Tenancy.Users.get("github|https://github.com|#{uid}")
    end

    test "a returning person signs in and lands in the chat even with cyfr.run unreachable",
         %{conn: conn} do
      uid = "back-#{System.unique_integer([:positive])}"
      user_id = "github|https://github.com|#{uid}"

      {:ok, user} =
        Sanctum.Tenancy.Users.upsert_from_provider(%{
          id: user_id,
          provider: "github",
          email: "back@example.com",
          verified: true
        })

      {:ok, _} =
        Sanctum.Tenancy.Users.set_namespace(user, "back#{System.unique_integer([:positive])}")

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Phoenix.ConnTest.fetch_flash()
        |> assign(:ueberauth_auth, github_auth(uid, "back@example.com"))
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

    defp verified_github_auth(uid, opts \\ []) do
      %Ueberauth.Auth{
        uid: uid,
        provider: :github,
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
          raw_info: %{user: %{"email_verified" => true}}
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
      user_id = "github|https://github.com|#{uid}"

      Bypass.expect_once(bypass, "POST", "/v1/identity/probe", fn c ->
        json_resp(c, 200, %{
          "personal_namespace" => %{"slug" => "alice#{n}", "token" => "cyfr_pt_personal"},
          "memberships" => []
        })
      end)

      conn = callback(conn, verified_github_auth(uid))

      assert redirected_to(conn) == "/"
      assert is_binary(session_of(conn))
      assert {:ok, %{namespace: ns}} = Sanctum.Tenancy.Users.get(user_id)
      assert ns == "alice#{n}"

      assert {:ok, %{token: "cyfr_pt_personal", role: "personal"}} =
               CredentialStore.get(user_id, "registry.test", ns)

      # The session is a working one: the person is authenticated at once...
      assert {:ok, %{authenticated: true, namespace: ^ns} = loaded} =
               Sanctum.Session.load(session_of(conn), surface: :console)

      # ...and it names the athanor that was just minted for them, not the
      # Home seat a platform admin picks up a moment earlier.
      assert {:ok, %{id: personal_id, kind: "person"}} =
               Sanctum.Tenancy.Athanors.get_by_slug("person", ns)

      assert loaded.athanor_id == personal_id
    end

    test "an operator's first sign-in lands in their own athanor, not the Home seat",
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

      conn = callback(conn, verified_github_auth(uid, email: email))

      assert redirected_to(conn) == "/"

      # The Home seat is minted before the namespace is known, so it is the
      # only membership at that moment; the session must still name the
      # athanor the sign-in went on to mint.
      assert {:ok, %{id: personal_id}} = Sanctum.Tenancy.Athanors.get_by_slug("person", "ops#{n}")

      assert {:ok, %{athanor_id: ^personal_id, platform_admin: true}} =
               Sanctum.Session.load(session_of(conn), surface: :console)

      assert Sanctum.Tenancy.Members.member?(
               "github|https://github.com|#{uid}",
               Sanctum.Tenancy.Athanors.home!().id
             )
    end

    test "unclaimed path: no personal → session, IdP token stashed, redirect to /claim-namespace",
         %{conn: conn, bypass: bypass} do
      uid = "auth_cb_unclaimed_#{System.unique_integer([:positive])}"
      user_id = "github|https://github.com|#{uid}"

      Bypass.expect_once(bypass, "POST", "/v1/identity/probe", fn c ->
        json_resp(c, 200, %{"personal_namespace" => nil, "memberships" => []})
      end)

      conn = callback(conn, verified_github_auth(uid))

      assert redirected_to(conn) == "/claim-namespace"
      assert is_binary(session_of(conn))
      assert Map.has_key?(conn.resp_cookies, "_cyfr_pending_probe")
      # A session ahead of its claim is not a working one yet, and it names no
      # athanor: the person's own does not exist until the claim mints it, and
      # a session pinned to something else now would outlast that.
      assert {:ok, %{authenticated: false, namespace: nil, athanor_id: nil}} =
               Sanctum.Session.load(session_of(conn), surface: :console)

      assert :not_found = CredentialStore.get(user_id, "registry.test", "alice")
    end

    test "412: session, IdP token stashed, redirect to /legal/accept",
         %{conn: conn, bypass: bypass} do
      uid = "auth_cb_412_#{System.unique_integer([:positive])}"

      Bypass.expect_once(bypass, "POST", "/v1/identity/probe", fn c ->
        json_resp(c, 412, %{"errors" => [%{"code" => "POLICY_ACCEPTANCE_REQUIRED"}]})
      end)

      conn = callback(conn, verified_github_auth(uid))
      assert redirected_to(conn) == "/legal/accept"
      assert is_binary(session_of(conn))
      assert Map.has_key?(conn.resp_cookies, "_cyfr_pending_probe")
    end

    test "probe 401 for a first-time person: no session, bounce to /login",
         %{conn: conn, bypass: bypass} do
      uid = "auth_cb_401_#{System.unique_integer([:positive])}"
      user_id = "github|https://github.com|#{uid}"

      Bypass.expect_once(bypass, "POST", "/v1/identity/probe", fn c ->
        json_resp(c, 401, %{"error" => "invalid_access_token"})
      end)

      conn = callback(conn, verified_github_auth(uid, token: "expired_token"))

      assert redirected_to(conn) == "/login"
      refute session_of(conn)
      assert :not_found = CredentialStore.get(user_id, "registry.test", "alice")
    end

    test "probe 5xx: a first-time person gets the page and no session; a returning one signs in",
         %{conn: conn, bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/identity/probe", fn c ->
        json_resp(c, 500, %{"error" => "internal"})
      end)

      uid = "auth_cb_5xx_#{System.unique_integer([:positive])}"
      conn1 = callback(conn, verified_github_auth(uid))
      assert conn1.status == 503
      refute session_of(conn1)
      refute Map.has_key?(conn1.resp_cookies, "_cyfr_pending_probe")

      n = System.unique_integer([:positive])
      back = "auth_cb_5xx_back_#{n}"

      {:ok, user} =
        Sanctum.Tenancy.Users.upsert_from_provider(%{
          id: "github|https://github.com|#{back}",
          provider: "github",
          email: "alice@example.com",
          verified: true
        })

      {:ok, _} = Sanctum.Tenancy.Users.set_namespace(user, "back#{n}")
      conn2 = callback(build_conn(), verified_github_auth(back))
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
      user_id = "github|https://github.com|#{uid}"

      Bypass.expect_once(bypass, "POST", "/v1/identity/probe", fn c ->
        json_resp(c, 200, %{
          "personal_namespace" => %{"slug" => "alice#{n}", "token" => "cyfr_pt_personal"},
          "memberships" => []
        })
      end)

      conn = callback(conn, verified_github_auth(uid))

      assert redirected_to(conn) == "/"
      assert {:ok, %{namespace: ns}} = Sanctum.Tenancy.Users.get(user_id)
      assert ns == "alice#{n}"
      assert :not_found = CredentialStore.get(user_id, "registry.test", ns)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "didn't fully sync"
    end

    test "no browser outcome is a JSON document, and no body carries a session token",
         %{conn: conn, bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/identity/probe", fn c ->
        json_resp(c, 500, %{"error" => "internal"})
      end)

      uid = "auth_cb_nojson_#{System.unique_integer([:positive])}"

      # A first-time person: the registry down, and the IdP giving no token.
      for auth <- [verified_github_auth(uid), verified_github_auth(uid, token: nil)] do
        conn = callback(conn, auth)
        assert conn.status == 503
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
      assert json_response(conn, 400)["error"] == "missing_token"
    end

    test "refuses a token in the request body", %{conn: conn} do
      # A credential in a body or query string lands in access logs and
      # Referer headers. The header is the only way in, and POST is no
      # longer routed at all.
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/auth/logout", Jason.encode!(%{"token" => "nonexistent_token"}))

      assert conn.status == 404
    end

    test "ignores a body token on the routed verb", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> delete(~p"/auth/logout", Jason.encode!(%{"token" => "nonexistent_token"}))

      assert json_response(conn, 400)["error"] == "missing_token"
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

      assert json_response(conn, 401)["error"] == "unauthorized"
      assert json_response(conn, 401)["message"] == "No session token provided"
    end

    test "returns invalid_session for nonexistent token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer nonexistent_token")
        |> get(~p"/auth/whoami")

      assert json_response(conn, 401)["error"] == "invalid_session"
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

    defp mint_ticket(payload) do
      ticket = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
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

      conn = get(conn, "/auth/device/complete/#{ticket}")

      assert redirected_to(conn) == "/"
      assert Plug.Conn.get_session(conn, :sanctum_session_token) == session.token
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "didn't fully sync"
    end

    test "a needs_claim ticket lands on the claim page with the suggestion", %{conn: conn} do
      session = mint_session()

      ticket =
        mint_ticket(%{
          session_token: session.token,
          access_token: "idp-token",
          outcome: {:needs_claim, "alice"}
        })

      conn = get(conn, "/auth/device/complete/#{ticket}")

      assert redirected_to(conn) == "/claim-namespace"
      assert Plug.Conn.get_session(conn, :claim_suggested_username) == "alice"
      assert Plug.Conn.get_session(conn, :sanctum_session_token) == session.token
    end
  end
end
