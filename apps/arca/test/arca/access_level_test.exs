defmodule Arca.AccessLevelTest do
  use ExUnit.Case, async: true

  alias Arca.AccessLevel
  alias Sanctum.Context

  # ============================================================================
  # Required Level Tests
  # ============================================================================

  describe "required_level/1" do
    test "list requires application level" do
      assert AccessLevel.required_level(:list) == :application
    end

    test "read requires application level" do
      assert AccessLevel.required_level(:read) == :application
    end

    test "write requires admin level" do
      assert AccessLevel.required_level(:write) == :admin
    end

    test "delete requires admin level" do
      assert AccessLevel.required_level(:delete) == :admin
    end

    test "unknown actions default to admin (most restrictive)" do
      assert AccessLevel.required_level(:unknown) == :admin
    end

    test "accepts string actions" do
      assert AccessLevel.required_level("list") == :application
      assert AccessLevel.required_level("write") == :admin
    end

    test "invalid string actions default to admin" do
      assert AccessLevel.required_level("not_an_action") == :admin
    end
  end

  # ============================================================================
  # Authorization Tests - Local Context
  # ============================================================================

  describe "authorized?/2 with local context" do
    setup do
      {:ok, ctx: Context.local()}
    end

    test "local context can list", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :list) == true
    end

    test "local context can read", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :read) == true
    end

    test "local context can write", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :write) == true
    end

    test "local context can delete", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :delete) == true
    end
  end

  # ============================================================================
  # Authorization Tests - OIDC Context
  # ============================================================================

  describe "authorized?/2 with OIDC context" do
    setup do
      ctx = %Context{
        user_id: "oidc_user",
        org_id: nil,
        permissions: MapSet.new([:execute]),
        scope: :personal,
        auth_method: :oidc,
        api_key_type: nil
      }

      {:ok, ctx: ctx}
    end

    test "OIDC session can list", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :list) == true
    end

    test "OIDC session can read", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :read) == true
    end

    test "OIDC session can write (admin level)", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :write) == true
    end

    test "OIDC session can delete (admin level)", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :delete) == true
    end
  end

  # ============================================================================
  # Authorization Tests - Application API Key
  # ============================================================================

  describe "authorized?/2 with application API key" do
    setup do
      ctx = %Context{
        user_id: "api_user",
        org_id: nil,
        permissions: MapSet.new([:execute]),
        scope: :personal,
        auth_method: :api_key,
        api_key_type: :application
      }

      {:ok, ctx: ctx}
    end

    test "application key can list", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :list) == true
    end

    test "application key can read", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :read) == true
    end

    test "application key cannot write", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :write) == false
    end

    test "application key cannot delete", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :delete) == false
    end
  end

  # ============================================================================
  # Authorization Tests - Admin API Key
  # ============================================================================

  describe "authorized?/2 with admin API key" do
    setup do
      ctx = %Context{
        user_id: "admin_api_user",
        org_id: nil,
        permissions: MapSet.new([:execute]),
        scope: :personal,
        auth_method: :api_key,
        api_key_type: :admin
      }

      {:ok, ctx: ctx}
    end

    test "admin key can list", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :list) == true
    end

    test "admin key can read", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :read) == true
    end

    test "admin key can write", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :write) == true
    end

    test "admin key can delete", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :delete) == true
    end
  end

  # ============================================================================
  # Authorization Tests - Public API Key
  # ============================================================================

  describe "authorized?/2 with public API key" do
    setup do
      ctx = %Context{
        user_id: "public_user",
        org_id: nil,
        permissions: MapSet.new([]),
        scope: :personal,
        auth_method: :api_key,
        api_key_type: :public
      }

      {:ok, ctx: ctx}
    end

    test "public key can list", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :list) == true
    end

    test "public key can read", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :read) == true
    end

    test "public key cannot write", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :write) == false
    end

    test "public key cannot delete", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :delete) == false
    end
  end

  # ============================================================================
  # authorize/2 Tests
  # ============================================================================

  describe "authorize/2" do
    test "returns :ok when authorized" do
      ctx = Context.local()
      assert AccessLevel.authorize(ctx, :write) == :ok
    end

    test "returns {:error, :unauthorized} when not authorized" do
      ctx = %Context{
        user_id: "app_user",
        permissions: MapSet.new([]),
        scope: :personal,
        auth_method: :api_key,
        api_key_type: :application
      }

      assert AccessLevel.authorize(ctx, :write) == {:error, :unauthorized}
    end
  end

  # ============================================================================
  # authorize!/2 Tests
  # ============================================================================

  describe "authorize!/2" do
    test "returns :ok when authorized" do
      ctx = Context.local()
      assert AccessLevel.authorize!(ctx, :write) == :ok
    end

    test "raises UnauthorizedError when not authorized" do
      ctx = %Context{
        user_id: "app_user",
        permissions: MapSet.new([]),
        scope: :personal,
        auth_method: :api_key,
        api_key_type: :application
      }

      assert_raise Sanctum.UnauthorizedError, fn ->
        AccessLevel.authorize!(ctx, :delete)
      end
    end
  end
end
