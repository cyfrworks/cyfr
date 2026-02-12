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
      original = Application.get_env(:sanctum, :auth_provider)
      Application.put_env(:sanctum, :auth_provider, SanctumArx.Auth.OIDC)

      on_exit(fn ->
        if original do
          Application.put_env(:sanctum, :auth_provider, original)
        else
          Application.delete_env(:sanctum, :auth_provider)
        end
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
