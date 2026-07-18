# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.OAuthTest do
  use ExUnit.Case, async: false

  alias Sanctum.Auth.OAuth

  # authenticate/1 resolves the caller's org from memberships, which reads the
  # DB — check out the sandbox for the whole module.
  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

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

      {:ok, user} = OAuth.authenticate(params)

      assert user.user_id == "github|https://github.com|12345"
      assert user.email == "alice@example.com"
      assert user.provider == "github"
      assert MapSet.member?(user.permissions, :*)
    end

    test "rejects GitHub user with missing email" do
      params = %{
        provider: :github,
        uid: "12345",
        info: %{email: nil}
      }

      assert {:error, :missing_email} = OAuth.authenticate(params)
    end

    test "rejects GitHub user when provider reports email_verified: false" do
      params = %{
        provider: :github,
        uid: "12345",
        info: %{email: "alice@example.com"},
        extra: %{raw_info: %{user: %{"email_verified" => false}}}
      }

      assert {:error, :email_not_verified} = OAuth.authenticate(params)
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

    test "authenticates Google user with verified email" do
      params = %{
        provider: :google,
        uid: "108xyz",
        info: %{email: "bob@gmail.com"},
        extra: %{raw_info: %{user: %{"email_verified" => true}}}
      }

      {:ok, user} = OAuth.authenticate(params)

      assert user.user_id == "google|https://accounts.google.com|108xyz"
      assert user.email == "bob@gmail.com"
      assert user.provider == "google"
    end

    test "rejects Google user with email_verified: false" do
      params = %{
        provider: :google,
        uid: "108xyz",
        info: %{email: "bob@gmail.com"},
        extra: %{raw_info: %{user: %{"email_verified" => false}}}
      }

      assert {:error, :email_not_verified} = OAuth.authenticate(params)
    end

    test "rejects Google user when email_verified claim is missing" do
      params = %{
        provider: :google,
        uid: "108xyz",
        info: %{email: "bob@gmail.com"},
        extra: %{raw_info: %{user: %{}}}
      }

      assert {:error, :email_not_verified} = OAuth.authenticate(params)
    end
  end

  describe "authenticate/1 with unsupported provider" do
    test "rejects Okta (handled by the OIDC provider, not OAuth)" do
      params = %{
        provider: :okta,
        uid: "okta123",
        info: %{email: "user@company.com"}
      }

      {:error, {:unsupported_provider, :okta}} = OAuth.authenticate(params)
    end

    test "rejects Azure AD (handled by the OIDC provider, not OAuth)" do
      params = %{
        provider: :azure_ad,
        uid: "azure123",
        info: %{email: "user@company.com"}
      }

      {:error, {:unsupported_provider, :azure_ad}} = OAuth.authenticate(params)
    end

    test "rejects a generic OIDC provider (handled by Sanctum.Auth.OIDC, not OAuth)" do
      params = %{
        provider: :oidc,
        uid: "oidc123",
        info: %{email: "user@company.com"}
      }

      {:error, {:unsupported_provider, :oidc}} = OAuth.authenticate(params)
    end
  end

  describe "authenticate/1 with session token" do
    test "returns error for invalid session token" do
      {:error, :invalid_session} = OAuth.authenticate(%{token: "invalid_token_123"})
    end
  end

  describe "authenticate/1 with invalid params" do
    test "returns error for empty params" do
      {:error, :invalid_params} = OAuth.authenticate(%{})
    end

    test "returns error for nil params" do
      {:error, :invalid_params} = OAuth.authenticate(nil)
    end
  end

  describe "current_user/1" do
    test "returns nil when no session" do
      fake_conn = %Plug.Conn{
        private: %{},
        req_headers: []
      }

      assert OAuth.current_user(fake_conn) == nil
    end
  end

  describe "supported_providers/0" do
    test "returns github and google in default mode" do
      providers = OAuth.supported_providers()

      assert :github in providers
      assert :google in providers
      refute :okta in providers
      refute :azure_ad in providers
    end
  end

  describe "supported_provider?/1" do
    test "returns true for github" do
      assert OAuth.supported_provider?(:github)
    end

    test "returns true for google" do
      assert OAuth.supported_provider?(:google)
    end

    test "returns false for okta" do
      refute OAuth.supported_provider?(:okta)
    end

    test "returns false for azure_ad" do
      refute OAuth.supported_provider?(:azure_ad)
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
      assert OAuth.configured_providers() == []
    end

    test "returns github when github is configured" do
      Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth,
        client_id: "id",
        client_secret: "secret"
      )

      assert :github in OAuth.configured_providers()
    end

    test "returns both github and google when both are configured" do
      Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth,
        client_id: "id",
        client_secret: "secret"
      )

      Application.put_env(:ueberauth, Ueberauth.Strategy.Google.OAuth,
        client_id: "id",
        client_secret: "secret"
      )

      providers = OAuth.configured_providers()
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
      refute OAuth.any_provider_configured?()
    end

    test "returns true when github configured" do
      Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth,
        client_id: "id",
        client_secret: "secret"
      )

      assert OAuth.any_provider_configured?()
    end
  end

  describe "behaviour compliance" do
    test "implements Sanctum.Auth behaviour" do
      behaviours = OAuth.__info__(:attributes)[:behaviour]

      assert Sanctum.Auth in behaviours
    end
  end
end
