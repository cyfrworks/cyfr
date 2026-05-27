# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.PubSubTest do
  use ExUnit.Case, async: true

  alias Sanctum.PubSub, as: PubSubHelper

  defp ctx(org_id) do
    Sanctum.Context.build(
      user_id: "u1",
      org_id: org_id,
      permissions: [:*],
      scope: :project,
      auth_method: :oidc,
      namespace: "testns",
      authenticated: true
    )
  end

  describe "topic/2 with a Context" do
    test "prefixes with the resolved tenant (org + project)" do
      assert "tenant:org_1:default:execution:events" ==
               PubSubHelper.topic("execution:events", ctx("org_1"))
    end

    test "prefixes with the seeded local org" do
      assert "tenant:local:default:execution:events" ==
               PubSubHelper.topic("execution:events", ctx("local"))
    end

    test "raises for a nil context" do
      assert_raise ArgumentError, ~r/non-nil context/, fn ->
        PubSubHelper.topic("execution:events", nil)
      end
    end

    test "raises for a context with an unresolved (nil) org_id" do
      # nil is the only org-less state a built Context can carry — the transient
      # pre-resolution auth state. topic/2 fails closed on it.
      assert_raise ArgumentError, ~r/non-empty org_id/, fn ->
        PubSubHelper.topic("execution:events", ctx(nil))
      end
    end

    test "an empty-string org_id is coerced to the local sentinel at build time" do
      # Context.build/1 never lets "" through (it normalizes to "local"), so a
      # built context can't reach topic/2 carrying an empty org. (The raw-struct
      # guard is covered in pubsub_empty_org_id_test.exs.)
      assert "tenant:local:default:execution:events" ==
               PubSubHelper.topic("execution:events", ctx(""))
    end
  end

  describe "topic/2 with a raw org_id string" do
    test "prefixes with the tenant" do
      assert "tenant:org_x:events" == PubSubHelper.topic("events", "org_x")
    end

    test "raises for an empty-string org_id" do
      assert_raise ArgumentError, ~r/non-empty org_id/, fn ->
        PubSubHelper.topic("events", "")
      end
    end
  end
end
