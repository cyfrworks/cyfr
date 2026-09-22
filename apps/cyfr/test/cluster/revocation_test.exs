# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/support.exs", __DIR__)

defmodule Cyfr.Cluster.RevocationTest do
  @moduledoc """
  A revoked authority against a warm cache on the other member, with the
  control channel up and with it cut.

  `cell-ownership.md` §5 classes the established-caller memo **shared**:
  `invalidate_hash/1` clears only the local table, so a revoked or
  re-pointed session stays valid on a peer for the rest of its TTL. The
  answer is an invalidation over the bus with the TTL as the bound a lost
  broadcast cannot exceed — and the TTL, not the broadcast, is what makes
  it safe. This file holds both halves to that:

    * with distribution up, the peer drops the memo because it **heard**;
    * with distribution cut, the peer drops it because the memo **ran
      out**, and the bound is its own TTL and nothing longer.

  The memo is warm on the peer for a production-shaped TTL here
  (`Cyfr.Cluster.Cell`), because a memo that is never warm cannot show
  what a cell-wide invalidation is for.
  """

  use Cyfr.Cluster.Case, async: false

  describe "a revoked authority" do
    test "is dropped on the peer that heard the announcement" do
      person = Cell.call(:a, Cyfr.Cluster.Fixtures, :person!, [])

      # Both members establish the caller, so both hold a memo of their
      # own: the second member's copy is the thing under test.
      for id <- [:a, :b] do
        assert {:ok, athanor} = Cell.call(id, Cyfr.Cluster.Fixtures, :establish, [person.token])
        assert athanor == person.athanor_id
        assert Cell.call(id, Cyfr.Cluster.Fixtures, :memo?, [person.hash])
      end

      # The archive happens on one member. Nothing about it reaches the
      # other except the announcement.
      assert Cell.call(:a, Cyfr.Cluster.Fixtures, :archive!, [person.athanor_id]) == "archived"

      {heard_ms, _} =
        Wait.measure!(
          fn -> not Cell.call(:b, Cyfr.Cluster.Fixtures, :memo?, [person.hash]) end,
          "the peer never dropped the memo it was told about",
          10_000
        )

      Wait.report("a peer drops a memo it heard about", heard_ms, 10_000)

      # And the peer answers the caller from the rows, which refuse.
      refute match?(
               {:ok, athanor} when athanor == person.athanor_id,
               Cell.call(:b, Cyfr.Cluster.Fixtures, :establish, [person.token])
             )
    end

    test "cannot outlive its memo's own TTL on a peer with the control channel cut" do
      person = Cell.call(:a, Cyfr.Cluster.Fixtures, :person!, [])

      for id <- [:a, :b] do
        assert {:ok, _} = Cell.call(id, Cyfr.Cluster.Fixtures, :establish, [person.token])
        assert Cell.call(id, Cyfr.Cluster.Fixtures, :memo?, [person.hash])
      end

      # The control channel between the members is cut: both keep their
      # database, both keep renewing, and neither hears the other.
      Cell.partition(:a, :b)
      assert Cell.call(:b, Node, :list, []) == []

      assert Cell.call(:a, Cyfr.Cluster.Fixtures, :archive!, [person.athanor_id]) == "archived"

      # The peer still holds the memo, because nothing reached it. That is
      # the exposure §5 names, and its bound is the TTL — not the
      # broadcast, which is why losing the broadcast is survivable.
      assert Cell.call(:b, Cyfr.Cluster.Fixtures, :memo?, [person.hash]),
             "the peer dropped the memo without hearing anything, so the cut proves nothing"

      # What a caller is answered is decided by the rows the moment the
      # memo runs out, and by nothing the peer can extend. Dropping it is
      # what the TTL does; here the case does it and then asks, so the
      # bound under test is "the memo alone stood between a revoked
      # session and admission", not the clock.
      assert Cell.call(:b, Sanctum.Caller, :drop_memo, [person.hash]) == :ok

      refute match?(
               {:ok, athanor} when athanor == person.athanor_id,
               Cell.call(:b, Cyfr.Cluster.Fixtures, :establish, [person.token])
             ),
             "a peer that had run its memo out still admitted a revoked session"

      # And once the members find each other again the announcement is
      # the mechanism once more.
      Cell.heal(:a, :b)
    end
  end
end
