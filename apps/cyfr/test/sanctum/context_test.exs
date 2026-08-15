# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ContextTest do
  # async: false — `for_scheduled/2` without an explicit `:namespace` resolves
  # it from the credential store (DB). Run serially with an owned sandbox
  # connection so a concurrent test flipping global shared mode can't strand it.
  use ExUnit.Case, async: false

  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
  end

  describe "local/0" do
    test "returns context with canonical local id and namespace" do
      ctx = Sanctum.TestContext.local()
      assert ctx.user_id == "local|local|testns"
      assert ctx.namespace == "testns"
      # The single-user test context resolves to the seeded "local" org.
      assert ctx.org_id == "local"
      assert ctx.scope == :project
    end

    test "grants wildcard permissions" do
      ctx = Sanctum.TestContext.local()
      assert MapSet.member?(ctx.permissions, :*)
    end

    test "is authenticated" do
      ctx = Sanctum.TestContext.local()
      assert ctx.authenticated == true
    end

    test "includes project_id default" do
      ctx = Sanctum.TestContext.local()
      assert ctx.project_id == "default"
    end

    test "includes new fields" do
      ctx = Sanctum.TestContext.local()
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

    test "builds context from map" do
      ctx =
        Context.build(%{
          user_id: "user_1",
          permissions: MapSet.new([:execute]),
          namespace: "testns",
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
      ctx =
        Context.build(
          user_id: "u1",
          api_key_id: "key_123",
          namespace: "testns",
          authenticated: true
        )

      assert ctx.api_key_id == "key_123"
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
      ctx = Sanctum.TestContext.local()
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

  describe "require_permission/2" do
    test "returns :ok when permission granted" do
      ctx = Sanctum.TestContext.local()
      assert :ok == Context.require_permission(ctx, :execute)
    end

    test "returns error with API key hint when auth_method is :api_key" do
      ctx =
        Context.build(
          user_id: "u1",
          permissions: [:storage_read],
          namespace: "testns",
          authenticated: true,
          auth_method: :api_key
        )

      {:error, msg} = Context.require_permission(ctx, :execute)
      assert msg =~ "missing required permission 'execute'"
      assert msg =~ "recreate with --scope execute"
    end

    test "returns error without hint for non-api_key auth" do
      ctx =
        Context.build(
          user_id: "u1",
          permissions: [:storage_read],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      {:error, msg} = Context.require_permission(ctx, :execute)
      assert msg =~ "missing required permission 'execute'"
      refute msg =~ "recreate"
    end
  end

  describe "authorize/3" do
    test "local context with wildcard always authorized" do
      ctx = Sanctum.TestContext.local()
      assert :ok == Context.authorize(ctx, :execute)
      assert :ok == Context.authorize(ctx, :admin)
      assert :ok == Context.authorize(ctx, :storage_read, {:execution, %{user_id: "other"}})
    end

    test "unauthenticated context always denied" do
      ctx = Context.build(user_id: nil, authenticated: false)
      assert {:error, _} = Context.authorize(ctx, :execute)
    end

    test "permission-only check succeeds with correct permission" do
      ctx =
        Context.build(
          user_id: "u1",
          permissions: [:execute],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      assert :ok == Context.authorize(ctx, :execute)
    end

    test "permission-only check fails without permission" do
      ctx =
        Context.build(
          user_id: "u1",
          permissions: [:storage_read],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      assert {:error, _} = Context.authorize(ctx, :execute)
    end

    test "ownership check succeeds when user matches" do
      ctx =
        Context.build(
          user_id: "u1",
          permissions: [:storage_read],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      record = %{user_id: "u1"}
      assert :ok == Context.authorize(ctx, :storage_read, {:execution, record})
    end

    test "execution is accessible to any same-tenant member (interchangeable)" do
      ctx =
        Context.build(
          user_id: "u1",
          permissions: [:storage_read],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      # u2's record, same (default) tenant — there is no owner gate, so u1 is
      # authorized. Cross-tenant access is still rejected (see tenant tests).
      record = %{user_id: "u2"}
      assert :ok == Context.authorize(ctx, :storage_read, {:execution, record})
    end

    test "admin overrides ownership check" do
      ctx =
        Context.build(
          user_id: "admin",
          permissions: [:storage_read, :admin],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      record = %{user_id: "other_user"}
      assert :ok == Context.authorize(ctx, :storage_read, {:execution, record})
    end

    test "authorize/2 shorthand works" do
      ctx = Sanctum.TestContext.local()
      assert :ok == Context.authorize(ctx, :execute)
    end

    test "owned resource check" do
      ctx =
        Context.build(
          user_id: "u1",
          permissions: [:storage_read],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      resource = %{user_id: "u1"}
      assert :ok == Context.authorize(ctx, :storage_read, {:owned, resource})
    end

    test "owned resource is accessible to any same-tenant member" do
      ctx =
        Context.build(
          user_id: "u1",
          permissions: [:storage_read],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      resource = %{user_id: "u2"}
      assert :ok == Context.authorize(ctx, :storage_read, {:owned, resource})
    end
  end

  describe "authorize/3 tenant verification" do
    test "rejects cross-tenant execution access" do
      ctx =
        Context.build(
          user_id: "u1",
          org_id: "org_a",
          project_id: "proj_a",
          permissions: [:storage_read],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      record = %{user_id: "u1", org_id: "org_b", project_id: "proj_b"}
      assert {:error, msg} = Context.authorize(ctx, :storage_read, {:execution, record})
      assert msg =~ "tenant mismatch"
    end

    test "allows same-tenant admin access to other user's execution" do
      ctx =
        Context.build(
          user_id: "admin_user",
          org_id: "org_a",
          project_id: "proj_a",
          permissions: [:storage_read, :admin],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      record = %{user_id: "other_user", org_id: "org_a", project_id: "proj_a"}
      assert :ok == Context.authorize(ctx, :storage_read, {:execution, record})
    end

    test "platform scope bypasses tenant check" do
      ctx =
        Context.build(
          user_id: "platform_admin",
          permissions: [:storage_read, :*],
          scope: :platform,
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      record = %{user_id: "other_user", org_id: "org_x", project_id: "proj_x"}
      assert :ok == Context.authorize(ctx, :storage_read, {:execution, record})
    end

    test "a local-org context passes the tenant check against a local record" do
      ctx =
        Context.build(
          user_id: "u1",
          org_id: "local",
          project_id: "default",
          permissions: [:storage_read],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      record = %{user_id: "u1", org_id: "local", project_id: "default"}
      assert :ok == Context.authorize(ctx, :storage_read, {:execution, record})
    end
  end

  describe "authorize/3 malformed tagged resources fail closed" do
    test "{:owned, map} with no :user_id is rejected (not silently downgraded)" do
      ctx =
        Context.build(
          user_id: "u1",
          permissions: [:storage_read],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      assert {:error, msg} = Context.authorize(ctx, :storage_read, {:owned, %{}})
      assert msg =~ "malformed owned resource"
    end

    test "{:execution, map} with no :user_id is rejected" do
      ctx =
        Context.build(
          user_id: "u1",
          permissions: [:storage_read],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      assert {:error, msg} = Context.authorize(ctx, :storage_read, {:execution, %{org_id: "org_a"}})
      assert msg =~ "malformed execution resource"
    end

    test "{:tenant, non_map} payload is rejected" do
      ctx =
        Context.build(
          user_id: "u1",
          permissions: [:storage_read],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      assert {:error, msg} = Context.authorize(ctx, :storage_read, {:tenant, "not-a-map"})
      assert msg =~ "malformed tenant resource"
    end

    test "wildcard/admin does NOT bypass per-record tenant check" do
      ctx =
        Context.build(
          user_id: "admin_user",
          org_id: "org_a",
          project_id: "proj_a",
          permissions: [:storage_read, :*, :admin],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      record = %{user_id: "other_user", org_id: "org_b", project_id: "proj_b"}
      assert {:error, msg} = Context.authorize(ctx, :storage_read, {:owned, record})
      assert msg =~ "tenant mismatch"
    end

    test "well-formed tagged resource still authorized (no regression)" do
      ctx =
        Context.build(
          user_id: "u1",
          permissions: [:storage_read],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      assert :ok == Context.authorize(ctx, :storage_read, {:owned, %{user_id: "u1"}})
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
      ctx =
        Context.build(
          user_id: nil,
          org_id: nil,
          project_id: nil,
          request_id: nil,
          api_key_id: nil
        )

      assert ctx.user_id == nil
      # An explicit `org_id: nil` is preserved (org-less); only an *absent*
      # org_id key defaults to the "local" sentinel off-platform.
      assert ctx.org_id == nil
    end

    test "allows authenticated non-platform context with nil namespace (identity-only)" do
      # namespace is no longer required — it is a pure identity field, not a
      # storage primitive. A user who hasn't claimed a cyfr.run slug is valid.
      ctx = Context.build(user_id: "u1", scope: :project, authenticated: true)
      assert ctx.namespace == nil
      assert ctx.authenticated
    end

    test "allows authenticated non-platform context with empty-string namespace" do
      ctx = Context.build(user_id: "u1", namespace: "", scope: :project, authenticated: true)
      assert ctx.authenticated
    end

    test "allows nil namespace when authenticated: false (pre-claim transient state)" do
      ctx = Context.build(user_id: "u1", scope: :project, authenticated: false)
      assert ctx.namespace == nil
      refute ctx.authenticated
    end

    test "allows nil namespace when scope: :platform (system tasks set namespace explicitly)" do
      ctx = Context.build(user_id: "system", scope: :platform, authenticated: true)
      assert ctx.namespace == nil
      assert ctx.scope == :platform
    end

    test "accepts authenticated non-platform context with valid namespace" do
      ctx =
        Context.build(
          user_id: "u1",
          namespace: "alice",
          scope: :project,
          authenticated: true
        )

      assert ctx.namespace == "alice"
      assert ctx.authenticated
    end
  end

  describe "construction centralization" do
    test "local/0 produces same result as equivalent build/1" do
      local = Sanctum.TestContext.local()

      built =
        Context.build(
          user_id: "local|local|testns",
          provider: "local",
          namespace: "testns",
          project_id: "default",
          permissions: [:*],
          scope: :project,
          auth_method: :oidc,
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
      scheduled =
        Context.for_scheduled("user_1",
          org_id: "org_1",
          project_id: "proj_1"
        )

      built =
        Context.build(
          user_id: "user_1",
          org_id: "org_1",
          project_id: "proj_1",
          permissions: [:execute, :storage_read, :execution_write, :storage_write],
          scope: :project,
          auth_method: :scheduled,
          namespace: "testns",
          authenticated: true
        )

      assert scheduled.user_id == built.user_id
      assert scheduled.org_id == built.org_id
      assert scheduled.project_id == built.project_id
      assert scheduled.permissions == built.permissions
      assert scheduled.scope == built.scope
      assert scheduled.auth_method == built.auth_method
      assert scheduled.authenticated == built.authenticated
    end

    test "internal/1 builds the single server-internal context (:system, platform)" do
      ctx = Context.internal()

      assert ctx.auth_method == :system
      assert ctx.scope == :platform
      assert ctx.user_id == "system"
      # namespace is identity-only now; the system context carries no sentinel.
      assert ctx.namespace == nil
      assert ctx.authenticated
    end

    test "internal/1 honors caller coordinates; provenance stays :system" do
      ctx =
        Context.internal(
          user_id: "u|i|s",
          namespace: "alice",
          scope: :project,
          org_id: "o1",
          project_id: "p1",
          permissions: [:execution_write]
        )

      assert ctx.auth_method == :system
      assert ctx.scope == :project
      assert ctx.namespace == "alice"
      assert ctx.org_id == "o1"
      assert ctx.project_id == "p1"
      assert ctx.permissions == MapSet.new([:execution_write])
      assert ctx.authenticated
    end

    test "for_scheduled/2 keeps :scheduled provenance and delegates to internal/1" do
      scheduled = Context.for_scheduled("user_1", org_id: "o", project_id: "p")

      assert scheduled.auth_method == :scheduled

      delegated =
        Context.internal(
          user_id: "user_1",
          namespace: scheduled.namespace,
          org_id: "o",
          project_id: "p",
          scope: :project,
          auth_method: :scheduled
        )

      # Single construction path: for_scheduled/2 is byte-identical to the
      # equivalent internal/1 call (only the provenance tag differs from
      # internal/1's :system default).
      assert scheduled == delegated
    end

    test "TestContext.local/0 impersonates a logged-in user (:oidc)" do
      assert Sanctum.TestContext.local().auth_method == :oidc
    end
  end
end
