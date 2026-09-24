# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.R6AthanorLessFailClosedTest do
  @moduledoc """
  Defense-in-depth: an actor carrying no athanor must never alias another
  athanor's rows or files.

  1. `Arca.QueryHelpers.where_tenant/2` raises for any actor with a
     nil/"" athanor, so a store that forgets its own head guard still
     cannot read anyone's rows. There is no sentinel to canonicalize to.
  2. `Arca.Storage.tenant_segments/1` fails closed the same way for the
     `data/` tree, and `Arca.Storage.athanor_ready?/1` is the boundary
     spelling of the same invariant for callers that must answer rather
     than raise.
  """

  use ExUnit.Case, async: true

  alias Arca.QueryHelpers
  alias Prima.Actor

  import Ecto.Query

  defp base_query, do: from(e in Arca.Schemas.Execution)

  describe "where_tenant/2 — actors with no athanor" do
    test "raises for an unauthenticated actor with none" do
      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        apply(QueryHelpers, :where_tenant, [base_query(), %Actor{athanor_id: nil}])
      end
    end

    test "raises for an authenticated actor with none" do
      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        apply(QueryHelpers, :where_tenant, [
          base_query(),
          %Actor{athanor_id: nil, authenticated: true}
        ])
      end
    end

    test "raises for the empty string, which is not a tenant named \"\"" do
      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        QueryHelpers.where_tenant(base_query(), %Actor{athanor_id: "", authenticated: true})
      end
    end

    test "a real athanor produces exactly one equality" do
      q = QueryHelpers.where_tenant(base_query(), Actor.in_athanor("ath_alpha"))
      assert length(q.wheres) == 1
    end
  end

  describe "the storage chokepoint rejects an actor with no athanor" do
    test "Arca.Storage.tenant_segments/1 fails closed" do
      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        Arca.Storage.tenant_segments(%Actor{athanor_id: nil, authenticated: true})
      end
    end

    test "an actor with a real athanor passes the chokepoint" do
      assert ["ath_alpha"] = Arca.Storage.tenant_segments(Actor.in_athanor("ath_alpha"))
    end

    test "the id alone names the directory; nothing else on the actor does" do
      actor = %{Actor.in_athanor("ath_alpha") | user_id: "alice"}

      assert Arca.Storage.tenant_segments(actor) == ["ath_alpha"]
    end
  end

  describe "athanor_ready?/1 — the boundary spelling of the same invariant" do
    # Total predicates (`Arca.exists?/2`) and guest-facing refusals
    # (`Crucible.GuestStorage`) consume this instead of catching the raise.
    test "answers exactly where tenant_segments/1 raises" do
      refute Arca.Storage.athanor_ready?(%Actor{athanor_id: nil})
      # The corrupted-row shapes a resolved identity never carries.
      refute Arca.Storage.athanor_ready?(%Actor{athanor_id: ""})
      refute Arca.Storage.athanor_ready?(%Actor{athanor_id: "a.b"})
      refute Arca.Storage.athanor_ready?(%Actor{athanor_id: "../x"})

      assert Arca.Storage.athanor_ready?(%Actor{athanor_id: "ath_alpha"})
    end
  end
end
