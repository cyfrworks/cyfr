defmodule Sanctum.Auth.SimpleOAuthTest do
  use ExUnit.Case, async: true

  alias Sanctum.Auth.SimpleOAuth
  alias Sanctum.User

  describe "authenticate/1 with GitHub" do
    setup do
      # Store original config
      original = Application.get_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)

      # Configure GitHub OAuth
      Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth,
        client_id: "test_github_id",
        client_secret: "test_github_secret"
      )

      on_exit(fn ->
        if original do
          Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth, original)
        else
          Application.delete_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)
        end
      end)

      :ok
    end

    test "authenticates GitHub user successfully" do
      params = %{
        provider: :github,
        uid: "12345",
        info: %{email: "alice@example.com"}
      }

      {:ok, user} = SimpleOAuth.authenticate(params)

      assert user.id == "12345"
      assert user.email == "alice@example.com"
      assert user.provider == "github"
      assert :* in user.permissions
    end

    test "authenticates GitHub user without email" do
      params = %{
        provider: :github,
        uid: "12345",
        info: %{email: nil}
      }

      {:ok, user} = SimpleOAuth.authenticate(params)

      assert user.id == "12345"
      assert user.email == nil
      assert user.provider == "github"
    end
  end

  describe "authenticate/1 with Google" do
    setup do
      original = Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)

      Application.put_env(:ueberauth, Ueberauth.Strategy.Google.OAuth,
        client_id: "test_google_id",
        client_secret: "test_google_secret"
      )

      on_exit(fn ->
        if original do
          Application.put_env(:ueberauth, Ueberauth.Strategy.Google.OAuth, original)
        else
          Application.delete_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)
        end
      end)

      :ok
    end

    test "authenticates Google user successfully" do
      params = %{
        provider: :google,
        uid: "67890",
        info: %{email: "bob@gmail.com"}
      }

      {:ok, user} = SimpleOAuth.authenticate(params)

      assert user.id == "67890"
      assert user.email == "bob@gmail.com"
      assert user.provider == "google"
      assert :* in user.permissions
    end
  end

  describe "authenticate/1 with unsupported provider" do
    test "rejects Okta (enterprise-only)" do
      params = %{
        provider: :okta,
        uid: "okta123",
        info: %{email: "user@company.com"}
      }

      {:error, {:unsupported_provider, :okta}} = SimpleOAuth.authenticate(params)
    end

    test "rejects Azure AD (enterprise-only)" do
      params = %{
        provider: :azure_ad,
        uid: "azure123",
        info: %{email: "user@company.com"}
      }

      {:error, {:unsupported_provider, :azure_ad}} = SimpleOAuth.authenticate(params)
    end

    test "rejects custom OIDC (enterprise-only)" do
      params = %{
        provider: :oidc,
        uid: "oidc123",
        info: %{email: "user@company.com"}
      }

      {:error, {:unsupported_provider, :oidc}} = SimpleOAuth.authenticate(params)
    end
  end

  describe "authenticate/1 with allowed_user restriction" do
    setup do
      # Configure GitHub OAuth
      Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth,
        client_id: "test_github_id",
        client_secret: "test_github_secret"
      )

      on_exit(fn ->
        Application.delete_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)
        Application.delete_env(:sanctum, :allowed_users)
      end)

      :ok
    end

    test "allows user when email matches allowed_users" do
      Application.put_env(:sanctum, :allowed_users, ["alice@example.com", "bob@example.com"])

      params = %{
        provider: :github,
        uid: "12345",
        info: %{email: "alice@example.com"}
      }

      {:ok, user} = SimpleOAuth.authenticate(params)
      assert user.email == "alice@example.com"
    end

    test "rejects user when email not in allowed_users" do
      Application.put_env(:sanctum, :allowed_users, ["alice@example.com"])

      params = %{
        provider: :github,
        uid: "12345",
        info: %{email: "eve@example.com"}
      }

      {:error, :user_not_allowed} = SimpleOAuth.authenticate(params)
    end

    test "allows any user when allowed_users is nil" do
      Application.delete_env(:sanctum, :allowed_users)

      params = %{
        provider: :github,
        uid: "12345",
        info: %{email: "anyone@example.com"}
      }

      {:ok, _user} = SimpleOAuth.authenticate(params)
    end

    test "allows any user when allowed_users is empty list" do
      Application.put_env(:sanctum, :allowed_users, [])

      params = %{
        provider: :github,
        uid: "12345",
        info: %{email: "anyone@example.com"}
      }

      {:ok, _user} = SimpleOAuth.authenticate(params)
    end
  end

  describe "authenticate/1 with session token" do
    setup do
      # We need to set up a valid session first
      # For this test, we'll just verify the token path works
      :ok
    end

    test "returns error for invalid session token" do
      {:error, :invalid_session} = SimpleOAuth.authenticate(%{token: "invalid_token_123"})
    end
  end

  describe "authenticate/1 with invalid params" do
    test "returns error for empty params" do
      {:error, :invalid_params} = SimpleOAuth.authenticate(%{})
    end

    test "returns error for nil params" do
      {:error, :invalid_params} = SimpleOAuth.authenticate(nil)
    end
  end

  describe "current_user/1" do
    test "returns nil when no session" do
      fake_conn = %Plug.Conn{
        private: %{},
        req_headers: []
      }

      assert SimpleOAuth.current_user(fake_conn) == nil
    end
  end

  describe "supported_providers/0" do
    test "returns github and google" do
      providers = SimpleOAuth.supported_providers()

      assert :github in providers
      assert :google in providers
      refute :okta in providers
      refute :azure_ad in providers
    end
  end

  describe "supported_provider?/1" do
    test "returns true for github" do
      assert SimpleOAuth.supported_provider?(:github)
    end

    test "returns true for google" do
      assert SimpleOAuth.supported_provider?(:google)
    end

    test "returns false for okta" do
      refute SimpleOAuth.supported_provider?(:okta)
    end

    test "returns false for azure_ad" do
      refute SimpleOAuth.supported_provider?(:azure_ad)
    end
  end

  describe "configured_providers/0" do
    setup do
      # Clear all OAuth config
      github_config = Application.get_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)
      google_config = Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)

      Application.delete_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)
      Application.delete_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)

      on_exit(fn ->
        if github_config do
          Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth, github_config)
        end
        if google_config do
          Application.put_env(:ueberauth, Ueberauth.Strategy.Google.OAuth, google_config)
        end
      end)

      :ok
    end

    test "returns empty list when no providers configured" do
      assert SimpleOAuth.configured_providers() == []
    end

    test "returns github when github is configured" do
      Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth,
        client_id: "id",
        client_secret: "secret"
      )

      assert :github in SimpleOAuth.configured_providers()
    end

    test "returns both when both are configured" do
      Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth,
        client_id: "id",
        client_secret: "secret"
      )
      Application.put_env(:ueberauth, Ueberauth.Strategy.Google.OAuth,
        client_id: "id",
        client_secret: "secret"
      )

      providers = SimpleOAuth.configured_providers()
      assert :github in providers
      assert :google in providers
    end
  end

  describe "any_provider_configured?/0" do
    setup do
      github_config = Application.get_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)
      google_config = Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)

      Application.delete_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)
      Application.delete_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)

      on_exit(fn ->
        if github_config do
          Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth, github_config)
        end
        if google_config do
          Application.put_env(:ueberauth, Ueberauth.Strategy.Google.OAuth, google_config)
        end
      end)

      :ok
    end

    test "returns false when no providers configured" do
      refute SimpleOAuth.any_provider_configured?()
    end

    test "returns true when github configured" do
      Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth,
        client_id: "id",
        client_secret: "secret"
      )

      assert SimpleOAuth.any_provider_configured?()
    end
  end

  describe "behaviour compliance" do
    test "implements Sanctum.Auth behaviour" do
      behaviours = SimpleOAuth.__info__(:attributes)[:behaviour]

      assert Sanctum.Auth in behaviours
    end
  end
end
