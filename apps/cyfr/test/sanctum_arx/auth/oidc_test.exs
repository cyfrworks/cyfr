defmodule SanctumArx.Auth.OIDCTest do
  use ExUnit.Case, async: false

  alias SanctumArx.Auth.OIDC
  alias Sanctum.User
  alias Sanctum.Session

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # Use a temp directory for file-based tests
    test_dir = Path.join(System.tmp_dir!(), "cyfr_oidc_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)

    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, test_dir: test_dir}
  end

  describe "authenticate/1 with Ueberauth.Auth struct" do
    test "creates user from GitHub auth" do
      auth = %{
        __struct__: Ueberauth.Auth,
        uid: "12345",
        provider: :github,
        info: %{
          email: "alice@example.com",
          nickname: "alice"
        },
        extra: nil
      }

      {:ok, user} = OIDC.authenticate(auth)

      assert user.id == "github|https://github.com|12345"
      assert user.email == "alice@example.com"
      assert user.provider == "github"
      assert is_list(user.permissions)
    end

    test "creates user from Google auth" do
      auth = %{
        __struct__: Ueberauth.Auth,
        uid: "google_user_123",
        provider: :google,
        info: %{
          email: "bob@gmail.com"
        },
        extra: nil
      }

      {:ok, user} = OIDC.authenticate(auth)

      assert user.id == "google|https://accounts.google.com|google_user_123"
      assert user.email == "bob@gmail.com"
      assert user.provider == "google"
    end

    test "handles missing email" do
      auth = %{
        __struct__: Ueberauth.Auth,
        uid: "12345",
        provider: :github,
        info: %{nickname: "alice"},
        extra: nil
      }

      {:ok, user} = OIDC.authenticate(auth)

      assert user.id == "github|https://github.com|12345"
      assert user.email == nil
    end

    test "extracts email from extra.raw_info when info.email is nil" do
      auth = %{
        __struct__: Ueberauth.Auth,
        uid: "12345",
        provider: :github,
        info: %{nickname: "alice"},
        extra: %{
          raw_info: %{"email" => "alice@extra.com"}
        }
      }

      {:ok, user} = OIDC.authenticate(auth)

      assert user.email == "alice@extra.com"
    end

    test "grants default permissions" do
      auth = %{
        __struct__: Ueberauth.Auth,
        uid: "12345",
        provider: :github,
        info: %{},
        extra: nil
      }

      {:ok, user} = OIDC.authenticate(auth)

      assert :execute in user.permissions
      assert :read in user.permissions
    end
  end

  describe "authenticate/1 with session token" do
    test "authenticates with valid session token" do
      # First create a session
      user = %User{
        id: "user_123",
        email: "test@example.com",
        provider: "github",
        permissions: [:execute]
      }

      {:ok, session} = Session.create(user)

      # Authenticate with the token
      {:ok, authenticated_user} = OIDC.authenticate(%{token: session.token})

      assert authenticated_user.id == "user_123"
      assert authenticated_user.email == "test@example.com"
    end

    test "returns error for invalid session token" do
      assert {:error, :invalid_session} = OIDC.authenticate(%{token: "invalid_token"})
    end
  end

  describe "authenticate/1 with API key" do
    setup %{test_dir: _test_dir} do
      # Create an API key for testing
      ctx = Sanctum.Context.local()

      {:ok, key_result} =
        Sanctum.ApiKey.create(ctx, %{
          name: "test-api-key",
          type: :application
        })

      {:ok, api_key: key_result.key}
    end

    test "authenticates with valid API key", %{api_key: api_key} do
      {:ok, user} = OIDC.authenticate(%{api_key: api_key})

      assert String.starts_with?(user.id, "api_key:")
      assert user.provider == "api_key"
      assert is_list(user.permissions)
    end

    test "returns error for invalid API key" do
      # Keys without valid cyfr_ prefix return :invalid_key_format
      assert {:error, :invalid_key_format} = OIDC.authenticate(%{api_key: "invalid_key"})
    end

    test "returns error for revoked API key", %{api_key: api_key} do
      ctx = Sanctum.Context.local()
      :ok = Sanctum.ApiKey.revoke(ctx, "test-api-key")

      assert {:error, :revoked} = OIDC.authenticate(%{api_key: api_key})
    end
  end

  describe "authenticate/1 with invalid params" do
    test "returns error for empty params" do
      assert {:error, :invalid_credentials} = OIDC.authenticate(%{})
    end

    test "returns error for unknown params" do
      assert {:error, :invalid_credentials} = OIDC.authenticate(%{unknown: "value"})
    end
  end

  describe "current_user/1" do
    test "returns nil when no authentication present" do
      # Use a plain map - the module handles non-Plug.Conn gracefully
      conn = %{assigns: %{}}
      assert nil == OIDC.current_user(conn)
    end

    test "returns user from session token in assigns" do
      # Create a session
      user = %User{id: "user_123", email: "test@example.com", provider: "github", permissions: []}
      {:ok, session} = Session.create(user)

      conn = %{
        assigns: %{session_token: session.token}
      }

      authenticated_user = OIDC.current_user(conn)

      assert authenticated_user.id == "user_123"
    end

    test "returns user from Bearer token with real Plug.Conn" do
      # Create a session
      user = %User{id: "user_123", email: "test@example.com", provider: "github", permissions: []}
      {:ok, session} = Session.create(user)

      # Create a real Plug.Conn struct
      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{session.token}")
        |> Map.put(:assigns, %{})

      authenticated_user = OIDC.current_user(conn)

      assert authenticated_user.id == "user_123"
    end

    test "returns nil for invalid session token" do
      conn = %{assigns: %{session_token: "invalid_token"}}
      assert nil == OIDC.current_user(conn)
    end
  end

  describe "behaviour compliance" do
    test "implements Sanctum.Auth behaviour" do
      behaviours = OIDC.__info__(:attributes)[:behaviour]
      assert Sanctum.Auth in behaviours
    end
  end

  describe "Arx mode error handling" do
    setup do
      original_edition = Application.get_env(:cyfr, :edition)
      original_license = :persistent_term.get(:sanctum_arx_license, nil)

      Application.put_env(:cyfr, :edition, :arx)
      # Set license to nil so require_arx() returns {:error, :license_expired}
      :persistent_term.put(:sanctum_arx_license, nil)

      on_exit(fn ->
        if original_edition do
          Application.put_env(:cyfr, :edition, original_edition)
        else
          Application.delete_env(:cyfr, :edition)
        end

        if original_license do
          :persistent_term.put(:sanctum_arx_license, original_license)
        else
          :persistent_term.put(:sanctum_arx_license, :core)
        end
      end)

      :ok
    end

    test "resolve_membership logs error when Memberships.list_by_user returns error" do
      import ExUnit.CaptureLog

      auth = %{
        __struct__: Ueberauth.Auth,
        uid: "arx_user_1",
        provider: :github,
        info: %{email: "arx@example.com"},
        extra: nil
      }

      log =
        capture_log(fn ->
          {:ok, user} = OIDC.authenticate(auth)
          # User should still be returned (graceful degradation)
          assert user.id == "github|https://github.com|arx_user_1"
          # org_id should be nil since membership resolution failed
          assert user.org_id == nil
        end)

      assert log =~ "[OIDC] Failed to resolve membership"
      assert log =~ "license_expired"
    end
  end
end
