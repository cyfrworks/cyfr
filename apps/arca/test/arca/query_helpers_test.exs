# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.QueryHelpersTest do
  @moduledoc """
  The tenant backstop, read off the actor.

  `where_tenant/2` scopes to the actor's athanor and raises for one that
  carries none; `where_tenant_unless_platform/2` is the one spelling of
  the platform bypass, and it reads `scope`, which is not a wire member
  of `Cyfr.Actor` — nothing a worker returns can claim it.
  """
  use ExUnit.Case, async: true

  alias Arca.QueryHelpers

  import Ecto.Query

  defp base_query, do: from(e in Arca.Execution)

  defp in_athanor(id), do: Cyfr.Actor.in_athanor(id)
  defp platform, do: Cyfr.Actor.system()

  describe "where_tenant/2" do
    test "applies the athanor filter" do
      query = QueryHelpers.where_tenant(base_query(), in_athanor("ath_1"))

      assert length(query.wheres) == 1
    end

    test "a fully named athanor-scope actor passes unchanged" do
      actor = Arca.Test.Actor.local()
      query = QueryHelpers.where_tenant(base_query(), actor)
      assert length(query.wheres) == 1
    end
  end

  describe "where_tenant/2 athanor-less fail-closed backstop" do
    test "an actor with a nil athanor raises" do
      actor = %Cyfr.Actor{athanor_id: nil, authenticated: true}

      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        QueryHelpers.where_tenant(base_query(), actor)
      end
    end

    test "an actor with an empty-string athanor raises, exactly as nil does" do
      # "" is an identity that was never resolved. Admitting it would
      # filter on athanor_id == "", match nothing, and answer an ordinary
      # empty result — a refusal turned into silence.
      actor = %Cyfr.Actor{athanor_id: "", authenticated: true}

      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        QueryHelpers.where_tenant(base_query(), actor)
      end
    end

    test "a platform-scope actor with no athanor raises too" do
      # Platform readers that cross athanors use where_tenant_unless_platform/2;
      # a platform task working inside one athanor carries that athanor.
      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        QueryHelpers.where_tenant(base_query(), platform())
      end
    end

    test "a plain map carrying an athanor is not an actor: no head matches it" do
      assert_raise FunctionClauseError, fn ->
        QueryHelpers.where_tenant(base_query(), %{athanor_id: "ath_1", user_id: "u"})
      end
    end
  end

  describe "where_tenant_unless_platform/2" do
    test "a platform-scope actor reads unfiltered, across every athanor" do
      query = QueryHelpers.where_tenant_unless_platform(base_query(), platform())
      assert query.wheres == []
    end

    test "an athanor-scope actor on the same function is scoped" do
      query = QueryHelpers.where_tenant_unless_platform(base_query(), in_athanor("ath_1"))
      assert length(query.wheres) == 1
    end

    test "the server's own actor narrowed to one athanor gives up the cross-tenant read" do
      narrowed = %{platform() | athanor_id: "ath_1", scope: :athanor}

      query = QueryHelpers.where_tenant_unless_platform(base_query(), narrowed)
      assert length(query.wheres) == 1
    end

    test "a plain map is not an actor here either, whatever scope it claims" do
      assert_raise FunctionClauseError, fn ->
        QueryHelpers.where_tenant_unless_platform(base_query(), %{
          athanor_id: "ath_1",
          scope: :platform
        })
      end
    end
  end

  describe "stamp_tenant!/2" do
    test "stamps the actor's athanor and raises for one that carries none" do
      assert %{athanor_id: "ath_1"} = QueryHelpers.stamp_tenant!(in_athanor("ath_1"), %{})

      for unresolved <- [%Cyfr.Actor{athanor_id: nil}, %Cyfr.Actor{athanor_id: ""}] do
        assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
          QueryHelpers.stamp_tenant!(unresolved, %{})
        end
      end
    end
  end

  describe "no_athanor!/1" do
    test "is the raise a ! entry point owes an actor with no athanor" do
      assert_raise ArgumentError, ~r/a resolved athanor is required/, fn ->
        QueryHelpers.no_athanor!("Arca.Thing.write!/2")
      end
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
