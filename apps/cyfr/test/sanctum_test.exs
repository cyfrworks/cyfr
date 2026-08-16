# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule SanctumTest do
  use ExUnit.Case, async: true

  alias Sanctum.Context

  describe "Sanctum.TestContext.local/0" do
    test "returns local context" do
      ctx = Sanctum.TestContext.local()

      assert ctx.user_id == "local|local|testns"
      assert Context.has_permission?(ctx, :execute)
    end
  end

  # A1 regression: build_tincture_context/2 must supply a non-blank namespace.
  # Before the fix it called Context.build/1 with authenticated: true and no
  # :namespace at default (athanor) scope, which Context.build/1 rejects with
  # ArgumentError — breaking EVERY tincture invocation (both the /t controller
  # and the Prism shell). It must NOT be "fixed" by switching to scope:
  # :platform, since platform scope bypasses tenant isolation.
  describe "build_tincture_context/2" do
    @tincture %{publisher: "alice", name: "widget"}

    test "authenticated caller: inherits namespace and own permissions, athanor-scoped" do
      caller = Sanctum.TestContext.local()

      ctx = Sanctum.build_tincture_context(caller, @tincture)

      assert ctx.namespace == "testns"
      assert ctx.user_id == "local|local|testns"
      assert ctx.scope == :athanor
      refute ctx.scope == :platform
      assert ctx.auth_method == :tincture
      assert ctx.authenticated == true
      refute ctx.anonymous
      # The invoker's execution is exactly as strong as the invoker — the
      # caller's own permission set rides through, no minting.
      assert MapSet.equal?(ctx.permissions, caller.permissions)
    end

    test "authenticated caller with a narrow permission set stays narrow" do
      caller =
        Context.build(
          user_id: "narrow-user",
          namespace: "testns",
          permissions: [:execute],
          scope: :athanor,
          authenticated: true
        )

      ctx = Sanctum.build_tincture_context(caller, @tincture)

      assert MapSet.equal?(ctx.permissions, MapSet.new([:execute]))
      refute ctx.anonymous
    end

    test "public/unauthenticated caller: dedicated namespace, execute-only, anonymous" do
      caller = Context.build(authenticated: false, scope: :athanor)

      ctx = Sanctum.build_tincture_context(caller, @tincture)

      assert ctx.namespace == "_tincture"
      assert ctx.user_id == "tincture:alice.widget"
      assert ctx.scope == :athanor
      assert ctx.authenticated == true
      assert ctx.anonymous
      assert MapSet.equal?(ctx.permissions, MapSet.new([:execute]))
    end

    test "namespace is never nil or empty for either caller shape" do
      for caller <- [
            Sanctum.TestContext.local(),
            Context.build(authenticated: false, scope: :athanor)
          ] do
        ctx = Sanctum.build_tincture_context(caller, @tincture)
        refute is_nil(ctx.namespace)
        refute ctx.namespace == ""
      end
    end
  end
end
