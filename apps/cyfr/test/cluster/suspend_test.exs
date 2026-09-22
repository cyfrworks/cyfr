# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/support.exs", __DIR__)

defmodule Cyfr.Cluster.SuspendTest do
  @moduledoc """
  A turn set down on one member and carried on by the other, with a
  message queued and an approval pending across the move.

  `cell-ownership.md` §9 gives `turn.suspend` its one job beyond what the
  approval pause already does durably: it **releases
  `threads.active_turn_id`**, so a suspended turn is resumable on another
  member. An approval pause keeps the claim; a suspend gives it up. What
  a suspend must not do is lose anything — every Tape row is preserved,
  and that includes a message accepted while the turn was down and an
  approval still waiting on a person.

  `turn.recover` takes the thread's claim and the recovery count in **one
  transaction**, so a member that did not take the claim cannot spend a
  recovery. The cap is three, and it is the cell's: spent anywhere, the
  turn ends `uncertain`.
  """

  use Cyfr.Cluster.Case, async: false

  describe "a turn suspended on one member" do
    test "gives the thread up with every row intact, and the peer carries it on" do
      %{athanor: athanor, thread: thread} = estate(:a, "suspend")

      accepted = Cell.call(:a, Cyfr.Cluster.Fixtures, :accept!, [athanor, thread, "@aqua go"])

      assert {:ok, _} =
               Cell.call(:a, Cyfr.Cluster.Fixtures, :start_turn, [
                 athanor,
                 accepted.turn_id,
                 accepted.turn_seq,
                 accepted.fence,
                 [root: true]
               ])

      running = Cell.call(:a, Cyfr.Cluster.Fixtures, :turn, [athanor, accepted.turn_id])
      approval = Cell.call(:a, Cyfr.Cluster.Fixtures, :approval!, [athanor, thread])
      before = Cell.call(:a, Cyfr.Cluster.Fixtures, :messages, [athanor, thread])

      # Down it goes, on the member that was running it.
      assert {:ok, down} =
               Cell.call(:a, Cyfr.Cluster.Fixtures, :suspend_turn, [
                 athanor,
                 accepted.turn_id,
                 running.fence,
                 "stepping away"
               ])

      assert down.status == "paused"
      assert down.paused_reason == "suspended"
      assert down.fence > running.fence

      assert Observer.thread(thread)["active_turn_id"] == nil,
             "a suspend did not release the thread's claim, so no peer can pick the turn up"

      # A message arrives while the turn is down, on the other member.
      _queued = Cell.call(:b, Cyfr.Cluster.Fixtures, :accept!, [athanor, thread, "and also this"])

      # The peer sees every row: the ones the turn had made, the one that
      # arrived while it was down, and the approval still waiting.
      assert Cell.call(:b, Cyfr.Cluster.Fixtures, :messages, [athanor, thread]) > before
      assert approval in Cell.call(:b, Cyfr.Cluster.Fixtures, :pending_approvals, [athanor, thread])

      # And the peer carries the turn on: the claim is its, the runner is
      # its boot, and the recovery is counted in the same transaction.
      assert {:ok, recovered} =
               Cell.call(:b, Cyfr.Cluster.Fixtures, :recover_turn, [
                 athanor,
                 accepted.turn_id,
                 down.fence
               ])

      assert recovered.recovery_attempts == down.recovery_attempts + 1
      assert recovered.runner_id == Cell.call(:b, Cyfr.Cluster.Fixtures, :boot, [])
      assert recovered.fence > down.fence
      assert Observer.thread(thread)["active_turn_id"] == accepted.turn_id

      # The member that set it down holds a fence the turn has moved past,
      # so anything it still tries to write is refused.
      assert Cell.call(:a, Cyfr.Cluster.Fixtures, :suspend_turn, [
               athanor,
               accepted.turn_id,
               down.fence,
               "too late"
             ]) == {:error, :superseded}
    end

    test "is not recovered by a member while a live peer is running it" do
      %{athanor: athanor, thread: thread} = estate(:a, "recover-busy")

      accepted = Cell.call(:a, Cyfr.Cluster.Fixtures, :accept!, [athanor, thread, "@aqua go"])

      assert {:ok, _} =
               Cell.call(:a, Cyfr.Cluster.Fixtures, :start_turn, [
                 athanor,
                 accepted.turn_id,
                 accepted.turn_seq,
                 accepted.fence,
                 [root: true]
               ])

      running = Cell.call(:a, Cyfr.Cluster.Fixtures, :turn, [athanor, accepted.turn_id])

      assert Cell.call(:b, Cyfr.Cluster.Fixtures, :recover_turn, [
               athanor,
               accepted.turn_id,
               running.fence
             ]) == {:error, :busy},
             "a peer recovered a turn a live member was running"

      assert Observer.turn(accepted.turn_id)["recovery_attempts"] == 0,
             "a refused recovery spent one anyway"
    end

    test "ends uncertain once the cell's recovery budget is spent, on either member" do
      %{athanor: athanor, thread: thread} = estate(:a, "cap")

      accepted = Cell.call(:a, Cyfr.Cluster.Fixtures, :accept!, [athanor, thread, "@aqua go"])

      assert {:ok, _} =
               Cell.call(:a, Cyfr.Cluster.Fixtures, :start_turn, [
                 athanor,
                 accepted.turn_id,
                 accepted.turn_seq,
                 accepted.fence,
                 [root: true]
               ])

      running = Cell.call(:a, Cyfr.Cluster.Fixtures, :turn, [athanor, accepted.turn_id])

      assert {:ok, down} =
               Cell.call(:a, Cyfr.Cluster.Fixtures, :suspend_turn, [
                 athanor,
                 accepted.turn_id,
                 running.fence,
                 "down"
               ])

      # The budget is on the row, so it is the cell's however many members
      # spent it.
      Cell.call(:a, Cyfr.Cluster.Fixtures, :spend_recoveries, [athanor, accepted.turn_id])

      assert Cell.call(:b, Cyfr.Cluster.Fixtures, :recover_turn, [
               athanor,
               accepted.turn_id,
               down.fence
             ]) == {:error, :recovery_exhausted}
    end
  end

  describe "a pending approval" do
    test "is decided once, whichever member decides it" do
      %{athanor: athanor, thread: thread} = estate(:a, "approval")
      approval = Cell.call(:a, Cyfr.Cluster.Fixtures, :approval!, [athanor, thread])

      results =
        Barrier.race(
          a: {Cyfr.Cluster.Fixtures, :decide, [athanor, approval, "approved"]},
          b: {Cyfr.Cluster.Fixtures, :decide, [athanor, approval, "denied"]}
        )

      decided = for {member, {:ok, status}} <- results, do: {member, status}

      assert length(decided) == 1,
             "two members both decided one approval: #{inspect(results)}"

      [{_member, status}] = decided
      assert status in ["approved", "denied"]

      assert Cell.call(:b, Cyfr.Cluster.Fixtures, :pending_approvals, [athanor, thread]) == [],
             "the approval is still pending after being decided"
    end
  end

  defp estate(id, label) do
    athanor = Cell.call(id, Cyfr.Cluster.Fixtures, :athanor!, [label])
    thread = Cell.call(id, Cyfr.Cluster.Fixtures, :thread!, [athanor.id, "cluster #{label}"])
    %{athanor: athanor.id, thread: thread.id}
  end
end
