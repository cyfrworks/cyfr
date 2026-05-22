# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Phase1g.PubSubEmptyOrgIdTest do
  use ExUnit.Case, async: true

  alias Sanctum.PubSub
  alias Sanctum.Context

  describe "PubSub.topic/2 tenant prefixing" do
    test "raises for a Context with an empty/unresolved org_id" do
      ctx = %Context{user_id: "user_1", org_id: "", project_id: "proj_1"}

      assert_raise ArgumentError, ~r/non-empty org_id/, fn ->
        PubSub.topic("test:topic", ctx)
      end
    end

    test "raises for a bare empty-string org_id" do
      assert_raise ArgumentError, ~r/non-empty org_id/, fn ->
        PubSub.topic("test:topic", "")
      end
    end

    test "prefixes a resolved org Context with the tenant" do
      ctx = %Context{user_id: "user_1", org_id: "local", project_id: "proj_1"}
      assert PubSub.topic("test:topic", ctx) == "tenant:local:proj_1:test:topic"
    end
  end
end
