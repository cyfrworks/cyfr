defmodule Sanctum.ContextTest do
  use ExUnit.Case, async: true

  alias Sanctum.Context

  describe "local/0" do
    test "returns context with local_user" do
      ctx = Context.local()
      assert ctx.user_id == "local_user"
      assert ctx.org_id == nil
      assert ctx.scope == :project
    end

    test "grants wildcard permissions" do
      ctx = Context.local()
      assert MapSet.member?(ctx.permissions, :*)
    end

    test "is authenticated" do
      ctx = Context.local()
      assert ctx.authenticated == true
    end

    test "includes project_id default" do
      ctx = Context.local()
      assert ctx.project_id == "default"
    end

    test "includes new fields" do
      ctx = Context.local()
      assert ctx.correlation_id == nil
      assert ctx.api_key_id == nil
    end
  end

  describe "for_scheduled/1" do
    test "creates context with default project_id" do
      ctx = Context.for_scheduled("user_1")
      assert ctx.user_id == "user_1"
      assert ctx.project_id == "default"
      assert ctx.auth_method == :scheduled
    end

    test "accepts project_id option" do
      ctx = Context.for_scheduled("user_1", project_id: "proj_1", org_id: "org_1")
      assert ctx.project_id == "proj_1"
      assert ctx.org_id == "org_1"
    end

    test "accepts correlation_id option" do
      ctx = Context.for_scheduled("user_1", correlation_id: "corr_123")
      assert ctx.correlation_id == "corr_123"
    end
  end

  describe "build/1" do
    test "builds context from keyword list" do
      ctx = Context.build(
        user_id: "user_1",
        org_id: "org_1",
        project_id: "proj_1",
        permissions: [:execute, :storage_read],
        scope: :project,
        auth_method: :oidc,
        authenticated: true
      )

      assert ctx.user_id == "user_1"
      assert ctx.org_id == "org_1"
      assert ctx.project_id == "proj_1"
      assert ctx.scope == :project
      assert MapSet.member?(ctx.permissions, :execute)
      assert MapSet.member?(ctx.permissions, :storage_read)
      assert ctx.authenticated == true
    end

    test "builds context from map" do
      ctx = Context.build(%{
        user_id: "user_1",
        permissions: MapSet.new([:execute]),
        authenticated: true
      })

      assert ctx.user_id == "user_1"
      assert MapSet.member?(ctx.permissions, :execute)
    end

    test "defaults to unauthenticated" do
      ctx = Context.build(user_id: "user_1")
      assert ctx.authenticated == false
    end

    test "defaults scope to :project" do
      ctx = Context.build(user_id: "user_1")
      assert ctx.scope == :project
    end

    test "converts list permissions to MapSet" do
      ctx = Context.build(permissions: [:a, :b, :c])
      assert MapSet.size(ctx.permissions) == 3
    end

    test "preserves MapSet permissions" do
      perms = MapSet.new([:x, :y])
      ctx = Context.build(permissions: perms)
      assert ctx.permissions == perms
    end

    test "includes api_key_id" do
      ctx = Context.build(user_id: "u1", api_key_id: "key_123", authenticated: true)
      assert ctx.api_key_id == "key_123"
    end

    test "includes correlation_id" do
      ctx = Context.build(user_id: "u1", correlation_id: "corr_456", authenticated: true)
      assert ctx.correlation_id == "corr_456"
    end
  end

  describe "active_scope/1" do
    test "returns :project when project_id is set" do
      ctx = Context.local()
      assert Context.active_scope(ctx) == :project
    end

    test "returns :org when only org_id is set" do
      ctx = Context.build(user_id: "u1", org_id: "org_1", scope: :org)
      assert Context.active_scope(ctx) == :org
    end

    test "returns :project when no org or project" do
      ctx = Context.build(user_id: "u1")
      assert Context.active_scope(ctx) == :project
    end

    test "returns :platform when scope is :platform" do
      ctx = Context.build(user_id: "u1", scope: :platform)
      assert Context.active_scope(ctx) == :platform
    end
  end

  describe "authenticated field" do
    test "unauthenticated context has authenticated: false" do
      ctx = %Context{
        user_id: nil,
        org_id: nil,
        permissions: MapSet.new(),
        scope: :project,
        authenticated: false
      }

      assert ctx.authenticated == false
    end

    test "default value is false" do
      ctx = %Context{
        user_id: "test",
        org_id: nil,
        permissions: MapSet.new(),
        scope: :project
      }

      assert ctx.authenticated == false
    end
  end

  describe "has_permission?/2" do
    test "returns true for any permission with wildcard" do
      ctx = Context.local()
      assert Context.has_permission?(ctx, :execute)
      assert Context.has_permission?(ctx, :publish)
      assert Context.has_permission?(ctx, :any_random_permission)
    end

    test "returns true for specific permission when granted" do
      ctx = %Context{
        user_id: "test",
        org_id: nil,
        permissions: MapSet.new([:execute, :publish]),
        scope: :project
      }

      assert Context.has_permission?(ctx, :execute)
      assert Context.has_permission?(ctx, :publish)
      refute Context.has_permission?(ctx, :admin)
    end
  end

  describe "require_permission!/2" do
    test "returns :ok when permission exists" do
      ctx = Context.local()
      assert :ok == Context.require_permission!(ctx, :execute)
    end

    test "raises when permission missing" do
      ctx = %Context{
        user_id: "test",
        org_id: nil,
        permissions: MapSet.new([]),
        scope: :project
      }

      assert_raise Sanctum.UnauthorizedError, fn ->
        Context.require_permission!(ctx, :execute)
      end
    end
  end

  describe "authorize/3" do
    test "local context with wildcard always authorized" do
      ctx = Context.local()
      assert :ok == Context.authorize(ctx, :execute)
      assert :ok == Context.authorize(ctx, :admin)
      assert :ok == Context.authorize(ctx, :read, {:execution, %{user_id: "other"}})
    end

    test "unauthenticated context always denied" do
      ctx = Context.build(user_id: nil, authenticated: false)
      assert {:error, _} = Context.authorize(ctx, :execute)
    end

    test "permission-only check succeeds with correct permission" do
      ctx = Context.build(user_id: "u1", permissions: [:execute], authenticated: true, auth_method: :oidc)
      assert :ok == Context.authorize(ctx, :execute)
    end

    test "permission-only check fails without permission" do
      ctx = Context.build(user_id: "u1", permissions: [:storage_read], authenticated: true, auth_method: :oidc)
      assert {:error, _} = Context.authorize(ctx, :execute)
    end

    test "ownership check succeeds when user matches" do
      ctx = Context.build(user_id: "u1", permissions: [:storage_read], authenticated: true, auth_method: :oidc)
      record = %{user_id: "u1"}
      assert :ok == Context.authorize(ctx, :read, {:execution, record})
    end

    test "ownership check fails when user does not match" do
      ctx = Context.build(user_id: "u1", permissions: [:storage_read], authenticated: true, auth_method: :oidc)
      record = %{user_id: "u2"}
      assert {:error, _} = Context.authorize(ctx, :read, {:execution, record})
    end

    test "admin overrides ownership check" do
      ctx = Context.build(user_id: "admin", permissions: [:storage_read, :admin], authenticated: true, auth_method: :oidc)
      record = %{user_id: "other_user"}
      assert :ok == Context.authorize(ctx, :read, {:execution, record})
    end

    test "authorize/2 shorthand works" do
      ctx = Context.local()
      assert :ok == Context.authorize(ctx, :execute)
    end

    test "owned resource check" do
      ctx = Context.build(user_id: "u1", permissions: [:storage_read], authenticated: true, auth_method: :oidc)
      resource = %{user_id: "u1"}
      assert :ok == Context.authorize(ctx, :read, {:owned, resource})
    end

    test "owned resource check fails for wrong user" do
      ctx = Context.build(user_id: "u1", permissions: [:storage_read], authenticated: true, auth_method: :oidc)
      resource = %{user_id: "u2"}
      assert {:error, _} = Context.authorize(ctx, :read, {:owned, resource})
    end
  end

  describe "authorize/3 tenant verification" do
    test "rejects cross-tenant execution access" do
      ctx = Context.build(
        user_id: "u1",
        org_id: "org_a",
        project_id: "proj_a",
        permissions: [:storage_read],
        authenticated: true,
        auth_method: :oidc
      )

      record = %{user_id: "u1", org_id: "org_b", project_id: "proj_b"}
      assert {:error, msg} = Context.authorize(ctx, :read, {:execution, record})
      assert msg =~ "tenant mismatch"
    end

    test "allows same-tenant admin access to other user's execution" do
      ctx = Context.build(
        user_id: "admin_user",
        org_id: "org_a",
        project_id: "proj_a",
        permissions: [:storage_read, :admin],
        authenticated: true,
        auth_method: :oidc
      )

      record = %{user_id: "other_user", org_id: "org_a", project_id: "proj_a"}
      assert :ok == Context.authorize(ctx, :read, {:execution, record})
    end

    test "platform scope bypasses tenant check" do
      ctx = Context.build(
        user_id: "platform_admin",
        permissions: [:storage_read, :*],
        scope: :platform,
        authenticated: true,
        auth_method: :oidc
      )

      record = %{user_id: "other_user", org_id: "org_x", project_id: "proj_x"}
      assert :ok == Context.authorize(ctx, :read, {:execution, record})
    end

    test "core mode (nil org_id) passes tenant check" do
      ctx = Context.build(
        user_id: "u1",
        org_id: nil,
        project_id: "default",
        permissions: [:storage_read],
        authenticated: true,
        auth_method: :oidc
      )

      record = %{user_id: "u1", org_id: "", project_id: "default"}
      assert :ok == Context.authorize(ctx, :read, {:execution, record})
    end
  end

  describe "authorize!/3" do
    test "raises on unauthorized" do
      ctx = Context.build(user_id: "u1", permissions: [], authenticated: true, auth_method: :oidc)

      assert_raise Sanctum.UnauthorizedError, fn ->
        Context.authorize!(ctx, :execute)
      end
    end

    test "returns :ok on authorized" do
      ctx = Context.local()
      assert :ok == Context.authorize!(ctx, :execute)
    end
  end

  describe "build/1 validation" do
    test "rejects invalid scope atom" do
      assert_raise ArgumentError, ~r/invalid scope/, fn ->
        Context.build(scope: :banana)
      end
    end

    test "rejects non-string user_id" do
      assert_raise ArgumentError, ~r/user_id must be a string or nil/, fn ->
        Context.build(user_id: 123)
      end
    end

    test "rejects non-string org_id" do
      assert_raise ArgumentError, ~r/org_id must be a string or nil/, fn ->
        Context.build(org_id: 42)
      end
    end

    test "rejects non-string project_id" do
      assert_raise ArgumentError, ~r/project_id must be a string or nil/, fn ->
        Context.build(project_id: [:list])
      end
    end

    test "rejects non-string request_id" do
      assert_raise ArgumentError, ~r/request_id must be a string or nil/, fn ->
        Context.build(request_id: 999)
      end
    end

    test "rejects non-string correlation_id" do
      assert_raise ArgumentError, ~r/correlation_id must be a string or nil/, fn ->
        Context.build(correlation_id: :atom)
      end
    end

    test "rejects non-string session_id" do
      assert_raise ArgumentError, ~r/session_id must be a string or nil/, fn ->
        Context.build(session_id: 42)
      end
    end

    test "rejects non-string api_key_id" do
      assert_raise ArgumentError, ~r/api_key_id must be a string or nil/, fn ->
        Context.build(api_key_id: 42)
      end
    end

    test "accepts all valid scopes" do
      for scope <- [:org, :project, :platform] do
        ctx = Context.build(user_id: "u1", scope: scope)
        assert ctx.scope == scope
      end
    end

    test "accepts nil for all string fields" do
      ctx = Context.build(
        user_id: nil,
        org_id: nil,
        project_id: nil,
        request_id: nil,
        correlation_id: nil,
        session_id: nil,
        api_key_id: nil
      )

      assert ctx.user_id == nil
      assert ctx.org_id == nil
    end
  end

  describe "construction centralization" do
    test "local/0 produces same result as equivalent build/1" do
      local = Context.local()

      built = Context.build(
        user_id: "local_user",
        project_id: "default",
        permissions: [:*],
        scope: :project,
        auth_method: :local,
        authenticated: true
      )

      assert local.user_id == built.user_id
      assert local.project_id == built.project_id
      assert local.permissions == built.permissions
      assert local.scope == built.scope
      assert local.auth_method == built.auth_method
      assert local.authenticated == built.authenticated
      assert local.org_id == built.org_id
    end

    test "for_scheduled/2 produces same result as equivalent build/1" do
      scheduled = Context.for_scheduled("user_1", org_id: "org_1", project_id: "proj_1", correlation_id: "corr_1")

      built = Context.build(
        user_id: "user_1",
        org_id: "org_1",
        project_id: "proj_1",
        permissions: [:execute, :storage_read, :execution_write, :storage_write],
        scope: :project,
        auth_method: :scheduled,
        correlation_id: "corr_1",
        authenticated: true
      )

      assert scheduled.user_id == built.user_id
      assert scheduled.org_id == built.org_id
      assert scheduled.project_id == built.project_id
      assert scheduled.permissions == built.permissions
      assert scheduled.scope == built.scope
      assert scheduled.auth_method == built.auth_method
      assert scheduled.correlation_id == built.correlation_id
      assert scheduled.authenticated == built.authenticated
    end
  end
end
