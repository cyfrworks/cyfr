# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.R6AthanorLessFailClosedTest do
  @moduledoc """
  Defense-in-depth: an athanor-less context must never alias another
  athanor's rows or files.

  1. `Arca.QueryHelpers.where_tenant/2` raises for any context with a
     nil/"" athanor, so a store that forgets the Sanctum chokepoint still
     cannot read anyone's rows. There is no sentinel to canonicalize to.
  2. `Arca.Storage.tenant_segments/1` fails closed the same way for the
     `data/` tree.
  """

  use ExUnit.Case, async: true

  alias Arca.QueryHelpers
  alias Sanctum.Context

  import Ecto.Query

  defp base_query, do: from(e in Arca.Execution)

  describe "where_tenant/2 — athanor-less contexts" do
    test "raises for an athanor-less UNauthenticated context" do
      ctx = Context.build(user_id: "u1", athanor_id: nil)

      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        QueryHelpers.where_tenant(base_query(), ctx)
      end
    end

    test "raises for an athanor-less AUTHENTICATED tenant context" do
      ctx = Context.build(user_id: "u1", athanor_id: nil, authenticated: true)

      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        QueryHelpers.where_tenant(base_query(), ctx)
      end
    end

    test "a real athanor produces exactly one equality" do
      ctx = Context.build(user_id: "u1", athanor_id: "ath_alpha")
      q = QueryHelpers.where_tenant(base_query(), ctx)
      assert length(q.wheres) == 1
    end
  end

  describe "Sanctum chokepoints reject an athanor-less context" do
    test "Arca.Storage.tenant_segments/1 fails closed for an athanor-less context" do
      ctx = Context.build(user_id: "u1", namespace: "u1", athanor_id: nil, authenticated: true)

      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        Arca.Storage.tenant_segments(ctx)
      end
    end

    test "a context with a real athanor passes the chokepoint (tenant_segments)" do
      ctx =
        Context.build(
          user_id: "u1",
          namespace: "u1",
          athanor_id: "ath_alpha",
          authenticated: true
        )

      assert ["ath_alpha"] = Arca.Storage.tenant_segments(ctx)
    end

    test "namespace is not part of the path" do
      ctx =
        Context.build(
          user_id: "u1",
          namespace: "alice",
          athanor_id: "ath_alpha",
          authenticated: true
        )

      refute "alice" in Arca.Storage.tenant_segments(ctx)
    end
  end
end
