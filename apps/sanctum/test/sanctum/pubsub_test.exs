# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.PubSubTest do
  use ExUnit.Case, async: true

  alias Sanctum.PubSub, as: PubSubHelper

  defp ctx(athanor_id) do
    Sanctum.Context.build(
      user_id: "u1",
      athanor_id: athanor_id,
      permissions: [:*],
      scope: :athanor,
      auth_method: :oidc,
      namespace: "testns",
      authenticated: true
    )
  end

  describe "topic/2 with a Context" do
    test "prefixes with the resolved athanor" do
      assert "tenant:ath_1:execution:events" ==
               PubSubHelper.topic("execution:events", ctx("ath_1"))
    end

    test "two athanors never share a topic" do
      refute PubSubHelper.topic("execution:events", ctx("ath_1")) ==
               PubSubHelper.topic("execution:events", ctx("ath_2"))
    end

    test "raises for a nil context" do
      assert_raise ArgumentError, ~r/non-nil context/, fn ->
        PubSubHelper.topic("execution:events", nil)
      end
    end

    test "raises for a context with an unresolved (nil) athanor_id" do
      # nil is the only athanor-less state a built Context can carry — the
      # transient pre-resolution auth state. topic/2 fails closed on it.
      assert_raise ArgumentError, ~r/non-empty athanor_id/, fn ->
        PubSubHelper.topic("execution:events", ctx(nil))
      end
    end

    test "an empty-string athanor_id never reaches topic/2 — build/1 rejects it" do
      # There is no sentinel to coerce into: Context.build/1 raises on "".
      # (The raw-struct guard is covered in pubsub_missing_athanor_test.exs.)
      assert_raise ArgumentError, ~r/athanor_id must be a resolved id or nil/, fn ->
        ctx("")
      end
    end
  end
end
