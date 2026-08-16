# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.PubSubMissingAthanorTest do
  use ExUnit.Case, async: true

  alias Sanctum.PubSub
  alias Sanctum.Context

  describe "PubSub.topic/2 tenant prefixing" do
    test "raises for a Context with an empty athanor_id" do
      ctx = %Context{user_id: "user_1", athanor_id: ""}

      assert_raise ArgumentError, ~r/non-empty athanor_id/, fn ->
        PubSub.topic("test:topic", ctx)
      end
    end

    test "raises for a Context whose athanor is unresolved (nil)" do
      ctx = %Context{user_id: "user_1", athanor_id: nil}

      assert_raise ArgumentError, ~r/non-empty athanor_id/, fn ->
        PubSub.topic("test:topic", ctx)
      end
    end

    test "raises without a context at all" do
      assert_raise ArgumentError, ~r/non-nil context/, fn ->
        PubSub.topic("test:topic", nil)
      end
    end

    test "prefixes a resolved Context with its athanor" do
      ctx = %Context{user_id: "user_1", athanor_id: "ath_1"}
      assert PubSub.topic("test:topic", ctx) == "tenant:ath_1:test:topic"
    end
  end
end
