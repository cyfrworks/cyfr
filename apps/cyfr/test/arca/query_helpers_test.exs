# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.QueryHelpersTest do
  use ExUnit.Case, async: true

  alias Arca.QueryHelpers
  alias Sanctum.Context

  import Ecto.Query

  defp base_query, do: from(e in Arca.Execution)

  describe "where_tenant/2" do
    test "applies the athanor filter" do
      ctx = Context.build(user_id: "u1", athanor_id: "ath_1")
      query = QueryHelpers.where_tenant(base_query(), ctx)

      assert length(query.wheres) == 1
    end

    test "the test context passes unchanged" do
      ctx = Sanctum.TestContext.local()
      query = QueryHelpers.where_tenant(base_query(), ctx)
      assert length(query.wheres) == 1
    end
  end

  describe "where_tenant/2 athanor-less fail-closed backstop" do
    test "authenticated context with nil athanor_id raises" do
      ctx =
        Context.build(
          user_id: "u1",
          namespace: "u1",
          athanor_id: nil,
          scope: :athanor,
          authenticated: true
        )

      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        QueryHelpers.where_tenant(base_query(), ctx)
      end
    end

    test "a hand-rolled struct with an empty-string athanor_id raises" do
      # Context.build/1 refuses "", so only a struct literal can carry it —
      # the guard must still fail closed on it.
      ctx = %Context{user_id: "u1", athanor_id: "", scope: :athanor, authenticated: true}

      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        QueryHelpers.where_tenant(base_query(), ctx)
      end
    end

    test "a platform-scope context with no athanor raises too" do
      # Platform readers that cross athanors use where_tenant_unless_platform/2;
      # a platform task working inside one athanor carries that athanor.
      ctx =
        Sanctum.TestContext.platform(user_id: "admin")

      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        QueryHelpers.where_tenant(base_query(), ctx)
      end
    end

    test "an unauthenticated context with no athanor raises (nothing to scope to)" do
      ctx = Context.build(user_id: "u1", athanor_id: nil)

      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        QueryHelpers.where_tenant(base_query(), ctx)
      end
    end
  end

  describe "where_tenant_unless_platform/2" do
    test "a platform context reads unfiltered" do
      ctx =
        Sanctum.TestContext.platform(user_id: "admin")

      query = QueryHelpers.where_tenant_unless_platform(base_query(), ctx)
      assert query.wheres == []
    end

    test "an athanor context is scoped" do
      ctx = Context.build(user_id: "u1", athanor_id: "ath_1")
      query = QueryHelpers.where_tenant_unless_platform(base_query(), ctx)
      assert length(query.wheres) == 1
    end
  end

  describe "where_athanor/2" do
    test "filters by a bare athanor id" do
      query = QueryHelpers.where_athanor(base_query(), "ath_1")
      assert length(query.wheres) == 1
    end

    test "nil and empty raise" do
      assert_raise ArgumentError, fn -> QueryHelpers.where_athanor(base_query(), nil) end
      assert_raise ArgumentError, fn -> QueryHelpers.where_athanor(base_query(), "") end
    end
  end

  describe "maybe_put/3" do
    test "adds key-value when value is non-nil" do
      assert QueryHelpers.maybe_put([], :limit, 10) == [limit: 10]
    end

    test "returns list unchanged when value is nil" do
      assert QueryHelpers.maybe_put([limit: 10], :status, nil) == [limit: 10]
    end

    test "overwrites existing key" do
      assert QueryHelpers.maybe_put([limit: 10], :limit, 20) == [limit: 20]
    end

    test "works with empty list and nil" do
      assert QueryHelpers.maybe_put([], :key, nil) == []
    end
  end
end
