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
        api_key_type: nil,
        authenticated: true
      }

      {:ok, ctx: ctx}
    end

    test "OIDC session can list", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :list) == true
    end

    test "OIDC session can read", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :read) == true
    end

    test "OIDC session without admin/storage_write cannot write", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :write) == false
    end

    test "OIDC session without admin/storage_write cannot delete", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :delete) == false
    end

    test "OIDC session with admin permission can write" do
      ctx = %Context{
        user_id: "oidc_admin",
        org_id: nil,
        permissions: MapSet.new([:execute, :admin]),
        scope: :personal,
        auth_method: :oidc,
        api_key_type: nil,
        authenticated: true
      }

      assert AccessLevel.authorized?(ctx, :write) == true
      assert AccessLevel.authorized?(ctx, :delete) == true
    end

    test "OIDC session with storage_write permission can write" do
      ctx = %Context{
        user_id: "oidc_storage",
        org_id: nil,
        permissions: MapSet.new([:execute, :storage_write]),
        scope: :personal,
        auth_method: :oidc,
        api_key_type: nil,
        authenticated: true
      }

      assert AccessLevel.authorized?(ctx, :write) == true
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
        api_key_type: :application,
        authenticated: true
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
        api_key_type: :admin,
        authenticated: true
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
  # Authorization Tests - Service API Key
  # ============================================================================

  describe "authorized?/2 with service API key" do
    setup do
      ctx = %Context{
        user_id: "service_user",
        org_id: nil,
        permissions: MapSet.new([:execute, :secrets_read]),
        scope: :personal,
        auth_method: :api_key,
        api_key_type: :service,
        authenticated: true
      }

      {:ok, ctx: ctx}
    end

    test "service key can list", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :list) == true
    end

    test "service key can read", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :read) == true
    end

    test "service key cannot write (enforced at Sanctum permission layer)", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :write) == false
    end

    test "service key cannot delete", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :delete) == false
    end
  end

  # ============================================================================
  # Authorization Tests - Default (unknown) context
  # ============================================================================

  describe "authorized?/2 with unknown context defaults to unauthenticated" do
    setup do
      ctx = %Context{
        user_id: "unknown_user",
        org_id: nil,
        permissions: MapSet.new([]),
        scope: :personal,
        auth_method: :api_key,
        api_key_type: nil,
        authenticated: true
      }

      {:ok, ctx: ctx}
    end

    test "unknown context cannot list", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :list) == false
    end

    test "unknown context cannot read", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :read) == false
    end

    test "unknown context cannot write", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :write) == false
    end

    test "unknown context cannot delete", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :delete) == false
    end
  end

  # ============================================================================
  # Authorization Tests - Unauthenticated Context
  # ============================================================================

  describe "authorized?/2 with unauthenticated context" do
    setup do
      ctx = %Context{
        user_id: nil,
        org_id: nil,
        permissions: MapSet.new([]),
        scope: :personal,
        auth_method: nil,
        api_key_type: nil,
        authenticated: false
      }

      {:ok, ctx: ctx}
    end

    test "unauthenticated context cannot list", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :list) == false
    end

    test "unauthenticated context cannot read", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :read) == false
    end

    test "unauthenticated context cannot write", %{ctx: ctx} do
      assert AccessLevel.authorized?(ctx, :write) == false
    end

    test "unauthenticated context cannot delete", %{ctx: ctx} do
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
        api_key_type: :application,
        authenticated: true
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
        api_key_type: :application,
        authenticated: true
      }

      assert_raise Sanctum.UnauthorizedError, fn ->
        AccessLevel.authorize!(ctx, :delete)
      end
    end
  end
end
