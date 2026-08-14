# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.OIDCTest do
  use ExUnit.Case, async: false

  alias Sanctum.Auth.OIDC
  alias Sanctum.Context
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

      {:ok, ctx} = OIDC.authenticate(auth)

      assert ctx.user_id == "github|https://github.com|12345"
      assert ctx.email == "alice@example.com"
      assert ctx.provider == "github"
      assert match?(%MapSet{}, ctx.permissions)
    end

    test "creates user from Google auth with verified email" do
      auth = %{
        __struct__: Ueberauth.Auth,
        uid: "google_user_123",
        provider: :google,
        info: %{
          email: "bob@gmail.com"
        },
        extra: %{raw_info: %{user: %{"email_verified" => true}}}
      }

      {:ok, ctx} = OIDC.authenticate(auth)

      assert ctx.user_id == "google|https://accounts.google.com|google_user_123"
      assert ctx.email == "bob@gmail.com"
      assert ctx.provider == "google"
    end

    test "rejects Google auth with email_verified: false" do
      auth = %{
        __struct__: Ueberauth.Auth,
        uid: "google_user_123",
        provider: :google,
        info: %{email: "bob@gmail.com"},
        extra: %{raw_info: %{user: %{"email_verified" => false}}}
      }

      assert {:error, :email_not_verified} = OIDC.authenticate(auth)
    end

    test "rejects missing email" do
      auth = %{
        __struct__: Ueberauth.Auth,
        uid: "12345",
        provider: :github,
        info: %{nickname: "alice"},
        extra: nil
      }

      assert {:error, :missing_email} = OIDC.authenticate(auth)
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

      {:ok, ctx} = OIDC.authenticate(auth)

      assert ctx.email == "alice@extra.com"
    end

    test "grants the full wildcard by default" do
      auth = %{
        __struct__: Ueberauth.Auth,
        uid: "12345",
        provider: :github,
        info: %{email: "alice@example.com"},
        extra: nil
      }

      {:ok, ctx} = OIDC.authenticate(auth)

      # Passing the operator's configured provider means full trust,
      # matching the OAuth/DeviceFlow providers. (The old default granted
      # :read, an atom nothing recognized.)
      assert MapSet.equal?(ctx.permissions, MapSet.new([:*]))
      assert Sanctum.Context.has_permission?(ctx, :execute)
    end

    test "rejects a reserved github.com issuer (direct-provider collision guard)" do
      # The configured issuer is the canonical source; ueberauth_oidcc pointed at
      # github.com would mint colliding ids, so it is rejected at login.
      Application.put_env(:cyfr, :oidc_issuer, "https://github.com")
      on_exit(fn -> Application.delete_env(:cyfr, :oidc_issuer) end)

      auth = %{__struct__: Ueberauth.Auth, uid: "12345", provider: :oidcc, info: %{}, extra: nil}

      assert_raise RuntimeError, ~r/reserved issuer.*github/, fn ->
        OIDC.authenticate(auth)
      end
    end

    test "rejects a reserved accounts.google.com issuer (direct-provider collision guard)" do
      Application.put_env(:cyfr, :oidc_issuer, "https://accounts.google.com")
      on_exit(fn -> Application.delete_env(:cyfr, :oidc_issuer) end)

      auth = %{__struct__: Ueberauth.Auth, uid: "12345", provider: :oidcc, info: %{}, extra: nil}

      assert_raise RuntimeError, ~r/reserved issuer.*google/, fn ->
        OIDC.authenticate(auth)
      end
    end

    test "rejects a generic OIDC login when :cyfr, :oidc_issuer is unset" do
      Application.delete_env(:cyfr, :oidc_issuer)

      auth = %{__struct__: Ueberauth.Auth, uid: "12345", provider: :oidcc, info: %{}, extra: nil}

      assert_raise RuntimeError, ~r/oidc_issuer is not set/, fn ->
        OIDC.authenticate(auth)
      end
    end

    test "uses the configured issuer to build a generic OIDC user id" do
      Application.put_env(:cyfr, :oidc_issuer, "https://auth.example.com")
      on_exit(fn -> Application.delete_env(:cyfr, :oidc_issuer) end)

      auth = %{
        __struct__: Ueberauth.Auth,
        uid: "sub-123",
        provider: :oidcc,
        info: %{email: "alice@example.com"},
        extra: nil
      }

      {:ok, ctx} = OIDC.authenticate(auth)
      assert ctx.user_id == "oidcc|https://auth.example.com|sub-123"
    end
  end

  describe "authenticate/1 with session token" do
    test "authenticates with valid session token" do
      # First create a session
      ctx =
        Context.build(
          user_id: "user_123",
          email: "test@example.com",
          provider: "github",
          permissions: [:execute],
          namespace: "testns",
          authenticated: true
        )

      {:ok, session} = Session.create(ctx)

      # Authenticate with the token
      {:ok, authenticated_ctx} = OIDC.authenticate(%{token: session.token})

      assert authenticated_ctx.user_id == "user_123"
      assert authenticated_ctx.email == "test@example.com"
    end

    test "returns error for invalid session token" do
      assert {:error, :invalid_session} = OIDC.authenticate(%{token: "invalid_token"})
    end
  end

  describe "authenticate/1 with API key params" do
    test "API keys are not an OIDC credential" do
      # Keys authenticate only through EmissaryWeb.Plugs.Authenticate, which
      # resolves the client IP for the allowlist check.
      assert {:error, :invalid_credentials} = OIDC.authenticate(%{api_key: "cyfr_ak_anything"})
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
      ctx =
        Context.build(
          user_id: "user_123",
          email: "test@example.com",
          provider: "github",
          permissions: [],
          namespace: "testns",
          authenticated: true
        )

      {:ok, session} = Session.create(ctx)

      conn = %{
        assigns: %{session_token: session.token}
      }

      authenticated_ctx = OIDC.current_user(conn)

      assert authenticated_ctx.user_id == "user_123"
    end

    test "returns user from Bearer token with real Plug.Conn" do
      # Create a session
      ctx =
        Context.build(
          user_id: "user_123",
          email: "test@example.com",
          provider: "github",
          permissions: [],
          namespace: "testns",
          authenticated: true
        )

      {:ok, session} = Session.create(ctx)

      # Create a real Plug.Conn struct
      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{session.token}")
        |> Map.put(:assigns, %{})

      authenticated_ctx = OIDC.current_user(conn)

      assert authenticated_ctx.user_id == "user_123"
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
end
