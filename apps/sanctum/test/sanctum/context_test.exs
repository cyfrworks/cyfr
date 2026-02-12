defmodule Sanctum.ContextTest do
  use ExUnit.Case, async: true

  alias Sanctum.Context

  describe "local/0" do
    test "returns context with local_user" do
      ctx = Context.local()
      assert ctx.user_id == "local_user"
      assert ctx.org_id == nil
      assert ctx.scope == :personal
    end

    test "grants wildcard permissions" do
      ctx = Context.local()
      assert MapSet.member?(ctx.permissions, :*)
    end

    test "is authenticated" do
      ctx = Context.local()
      assert ctx.authenticated == true
    end
  end

  describe "authenticated field" do
    test "unauthenticated context has authenticated: false" do
      ctx = %Context{
        user_id: nil,
        org_id: nil,
        permissions: MapSet.new(),
        scope: :personal,
        authenticated: false
      }

      assert ctx.authenticated == false
    end

    test "default value is false" do
      ctx = %Context{
        user_id: "test",
        org_id: nil,
        permissions: MapSet.new(),
        scope: :personal
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
        scope: :personal
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
        scope: :personal
      }

      assert_raise Sanctum.UnauthorizedError, fn ->
        Context.require_permission!(ctx, :execute)
      end
    end
  end
end
