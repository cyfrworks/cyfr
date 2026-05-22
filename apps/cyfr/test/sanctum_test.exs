# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule SanctumTest do
  use ExUnit.Case, async: true

  alias Sanctum.Context

  describe "local_context/0" do
    test "returns local context" do
      ctx = Sanctum.TestContext.local()

      assert ctx.user_id == "local|local|testns"
      assert Context.has_permission?(ctx, :execute)
    end
  end

  # A1 regression: build_tincture_context/2 must supply a non-blank namespace.
  # Before the fix it called Context.build/1 with authenticated: true and no
  # :namespace at default (project) scope, which Context.build/1 rejects with
  # ArgumentError — breaking EVERY tincture invocation (both the /t controller
  # and the Prism shell). It must NOT be "fixed" by switching to scope:
  # :platform, since platform scope bypasses tenant isolation.
  describe "build_tincture_context/2" do
    @tincture %{publisher: "alice", name: "widget"}

    test "authenticated caller: inherits namespace, project-scoped, execute-only" do
      caller = Sanctum.TestContext.local()

      ctx = Sanctum.build_tincture_context(caller, @tincture)

      assert ctx.namespace == "testns"
      assert ctx.user_id == "local|local|testns"
      assert ctx.scope == :project
      refute ctx.scope == :platform
      assert ctx.auth_method == :tincture
      assert ctx.authenticated == true
      assert Context.has_permission?(ctx, :execute)
      assert MapSet.equal?(ctx.permissions, MapSet.new([:execute]))
    end

    test "public/unauthenticated caller: dedicated namespace, never blank, no raise" do
      caller = Context.build(authenticated: false, scope: :project)

      ctx = Sanctum.build_tincture_context(caller, @tincture)

      assert ctx.namespace == "_tincture"
      assert ctx.user_id == "tincture:alice.widget"
      assert ctx.scope == :project
      assert ctx.authenticated == true
      assert Context.has_permission?(ctx, :execute)
    end

    test "namespace is never nil or empty for either caller shape" do
      for caller <- [
            Sanctum.TestContext.local(),
            Context.build(authenticated: false, scope: :project)
          ] do
        ctx = Sanctum.build_tincture_context(caller, @tincture)
        refute is_nil(ctx.namespace)
        refute ctx.namespace == ""
      end
    end
  end
end
