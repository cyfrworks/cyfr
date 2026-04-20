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

      assert json_response(conn, 404)["error"] == "unknown_provider"
      assert json_response(conn, 404)["message"] =~ "OAuth provider not configured"
    end
  end

  describe "callback/2" do
    setup do
      original = Application.get_env(:cyfr, :auth_provider)
      Application.put_env(:cyfr, :auth_provider, SanctumArx.Auth.OIDC)

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

      assert json_response(conn, 400)["error"] == "invalid_callback"
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

      assert json_response(conn, 401)["error"] == "oauth_failure"
      assert json_response(conn, 401)["message"] =~ "Access denied"
    end

    test "successful OAuth callback creates session and returns JSON", %{conn: conn} do
      # Simulate successful Ueberauth auth from GitHub
      auth = %Ueberauth.Auth{
        uid: "12345",
        provider: :github,
        info: %Ueberauth.Auth.Info{
          email: "test@example.com",
          name: "Test User"
        },
        credentials: %Ueberauth.Auth.Credentials{
          token: "gho_mock_access_token",
          refresh_token: nil,
          expires: false
        },
        extra: %{}
      }

      # Initialize session (required for get_session calls in callback)
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> assign(:ueberauth_auth, auth)
        |> EmissaryWeb.AuthController.callback(%{})

      response = json_response(conn, 200)
      assert response["ok"] == true
      assert response["session"]["token"]
      assert response["session"]["expires_at"]
      assert response["user"]["email"] == "test@example.com"
      assert response["user"]["provider"] == "github"
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
      Application.put_env(:cyfr, :auth_provider, SanctumArx.Auth.OIDC)

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

    test "happy path: probe succeeds, tokens stored, 200 JSON response",
         %{conn: conn, bypass: bypass} do
      uid = "auth_cb_happy_#{System.unique_integer([:positive])}"
      user_id = "github|https://github.com|#{uid}"

      Bypass.expect_once(bypass, "POST", "/v1/identity/probe", fn c ->
        json_resp(c, 200, %{
          "personal_namespace" => %{"slug" => "alice", "token" => "cyfr_pt_personal"},
          "memberships" => []
        })
      end)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> assign(:ueberauth_auth, verified_github_auth(uid))
        |> EmissaryWeb.AuthController.callback(%{})

      response = json_response(conn, 200)
      assert response["ok"] == true
      assert response["user"]["email"] == "alice@example.com"

      assert {:ok, %{token: "cyfr_pt_personal", role: "personal"}} =
               CredentialStore.get(user_id, "registry.test", "alice")
    end

    test "unclaimed path: probe succeeds, no personal → redirect to /claim-namespace",
         %{conn: conn, bypass: bypass} do
      uid = "auth_cb_unclaimed_#{System.unique_integer([:positive])}"
      user_id = "github|https://github.com|#{uid}"

      Bypass.expect_once(bypass, "POST", "/v1/identity/probe", fn c ->
        json_resp(c, 200, %{"personal_namespace" => nil, "memberships" => []})
      end)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> assign(:ueberauth_auth, verified_github_auth(uid))
        |> EmissaryWeb.AuthController.callback(%{})

      assert redirected_to(conn) == "/claim-namespace"
      assert Plug.Conn.get_session(conn, :sanctum_session_token)

      assert :not_found = CredentialStore.get(user_id, "registry.test", "alice")
    end

    test "probe 401: session destroyed, bounce to /auth/<provider>",
         %{conn: conn, bypass: bypass} do
      uid = "auth_cb_401_#{System.unique_integer([:positive])}"
      user_id = "github|https://github.com|#{uid}"

      Bypass.expect_once(bypass, "POST", "/v1/identity/probe", fn c ->
        json_resp(c, 401, %{"error" => "invalid_access_token"})
      end)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> assign(:ueberauth_auth, verified_github_auth(uid, token: "expired_token"))
        |> EmissaryWeb.AuthController.callback(%{})

      assert redirected_to(conn) =~ ~r{^/auth/github}

      assert :not_found = CredentialStore.get(user_id, "registry.test", "alice")
    end

    test "probe 5xx: session survives, CredentialStore empty, 200 JSON",
         %{conn: conn, bypass: bypass} do
      uid = "auth_cb_5xx_#{System.unique_integer([:positive])}"
      user_id = "github|https://github.com|#{uid}"

      Bypass.expect(bypass, "POST", "/v1/identity/probe", fn c ->
        json_resp(c, 500, %{"error" => "internal"})
      end)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> assign(:ueberauth_auth, verified_github_auth(uid))
        |> EmissaryWeb.AuthController.callback(%{})

      response = json_response(conn, 200)
      assert response["ok"] == true

      assert :not_found = CredentialStore.get(user_id, "registry.test", "alice")
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

    test "accepts token via POST body", %{conn: conn} do
      # Session.destroy is idempotent - destroying nonexistent token returns :ok
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/auth/logout", Jason.encode!(%{"token" => "nonexistent_token"}))

      response = json_response(conn, 200)
      assert response["ok"] == true
      assert response["message"] == "Logged out successfully"
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
      user = %Sanctum.User{
        id: "user_whoami_test",
        email: "whoami@example.com",
        provider: "github",
        permissions: [:execute, :read]
      }

      {:ok, session} = Sanctum.Session.create(user)

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
end
