# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/support.exs", __DIR__)

defmodule Cyfr.Cluster.ThreadTest do
  @moduledoc """
  Which member holds a thread, and what the other one does about it.

  `cell-ownership.md` §4.2 gives the thread its claim: one statement
  naming the turn **and** the consumed sequence the claimant read, so of
  two members reading the same thread at the same moment one claim lands.
  §6 gives the rule that makes a join harmless: a member that finds no
  local runner reads the thread row, and a turn whose `runner_id` is a
  live member's boot is a **peer's** — it does not recover it, does not
  count a recovery against it, and answers the caller that the turn is
  running elsewhere.

  Every loss arm of that in wave 1 was verified against a constructed
  second member. Here the second member is a node.
  """

  use Cyfr.Cluster.Case, async: false

  # §4.1's takeover bound: a member that stops without releasing is taken
  # over within its lease plus its successor's next tick.
  @takeover_bound_ms 20_000

  describe "two turns competing for one thread" do
    test "a turn started on the peer meets the one holding the thread" do
      %{athanor: athanor, thread: thread} = estate(:a, "busy")

      first = Cell.call(:a, Cyfr.Cluster.Fixtures, :accept!, [athanor, thread, "@aqua one"])

      assert {:ok, started} =
               Cell.call(:a, Cyfr.Cluster.Fixtures, :start_turn, [
                 athanor,
                 first.turn_id,
                 first.turn_seq,
                 first.fence
               ])

      assert started.status == "running"
      assert started.runner_id == Cell.call(:a, Cyfr.Cluster.Fixtures, :boot, [])

      # The peer accepts the next message, so it holds the sequence the
      # thread now reads — the only condition left to refuse it is the
      # claim itself.
      second = Cell.call(:b, Cyfr.Cluster.Fixtures, :accept!, [athanor, thread, "@aqua two"])

      assert Cell.call(:b, Cyfr.Cluster.Fixtures, :start_turn, [
               athanor,
               second.turn_id,
               second.turn_seq,
               second.fence
             ]) == {:error, {:held_elsewhere, first.turn_id}}

      assert Observer.thread(thread)["active_turn_id"] == first.turn_id
    end

    test "a claim whose sequence moved under it writes nothing, and the loser re-reads" do
      %{athanor: athanor, thread: thread} = estate(:a, "stale")

      # The first member reads the thread, then the peer accepts the next
      # message — the interleaving is made by the order of these two
      # calls, not by hoping one is slower than the other.
      first = Cell.call(:a, Cyfr.Cluster.Fixtures, :accept!, [athanor, thread, "@aqua one"])
      _second = Cell.call(:b, Cyfr.Cluster.Fixtures, :accept!, [athanor, thread, "@aqua two"])

      assert Cell.call(:a, Cyfr.Cluster.Fixtures, :start_turn, [
               athanor,
               first.turn_id,
               first.turn_seq,
               first.fence
             ]) == {:error, :stale},
             "a claim naming a sequence a peer had moved was admitted"

      assert Observer.thread(thread)["active_turn_id"] == nil,
             "a refused claim wrote the thread anyway"

      # Re-reading is what the loser does, and then its claim lands: the
      # refusal is a stale read, not a lost turn.
      current = Cell.call(:a, Cyfr.Cluster.Fixtures, :thread, [athanor, thread])

      assert {:ok, _turn} =
               Cell.call(:a, Cyfr.Cluster.Fixtures, :start_turn, [
                 athanor,
                 first.turn_id,
                 current.turn_seq,
                 first.fence
               ])

      assert Observer.thread(thread)["active_turn_id"] == first.turn_id
    end

    test "two members claiming one thread at one instant land one claim" do
      %{athanor: athanor, thread: thread} = estate(:a, "instant")

      # §4.2's statement on its own, which is where the race lives: both
      # members name the same consumed sequence — the one the thread
      # reads — and two different turns.
      current = Cell.call(:a, Cyfr.Cluster.Fixtures, :thread, [athanor, thread])
      seq = current.turn_seq || 0
      mine = "turn_cluster_a_#{System.unique_integer([:positive])}"
      theirs = "turn_cluster_b_#{System.unique_integer([:positive])}"

      results =
        Barrier.race(
          a: {Cyfr.Cluster.Fixtures, :claim_thread, [athanor, thread, mine, seq]},
          b: {Cyfr.Cluster.Fixtures, :claim_thread, [athanor, thread, theirs, seq]}
        )

      won = for {member, {:ok, holder}} <- results, do: {member, holder}

      assert length(won) == 1,
             "two members both took one thread's claim: #{inspect(results)}"

      [{_member, holder}] = won
      assert holder in [mine, theirs]
      assert Observer.thread(thread)["active_turn_id"] == holder

      # The loser is only ever *refused*. Which refusal it gets depends on
      # which statement reached the row first, and pinning that would be
      # asserting more than the mechanism guarantees.
      losers = for {_m, answer} <- results, not match?({:ok, _}, answer), do: answer
      assert Enum.all?(losers, &match?({:error, _}, &1)), inspect(results)
    end
  end

  describe "a peer's running turn" do
    test "is not recovered, not counted against, and reported as running elsewhere" do
      %{athanor: athanor, thread: thread} = estate(:a, "peers")

      accepted = Cell.call(:a, Cyfr.Cluster.Fixtures, :accept!, [athanor, thread, "@aqua go"])

      assert {:ok, _turn} =
               Cell.call(:a, Cyfr.Cluster.Fixtures, :start_turn, [
                 athanor,
                 accepted.turn_id,
                 accepted.turn_seq,
                 accepted.fence
               ])

      # The peer has no local runner for this thread, and that is never
      # evidence. It reads the row, finds a live member's boot, and says
      # so.
      holder = Cell.call(:b, Cyfr.Cluster.Fixtures, :claim_holder, [athanor, thread])
      assert holder.turn_id == accepted.turn_id
      assert holder.live_peer?, "the peer did not recognise a live member's turn"

      assert Cell.call(:b, Cyfr.Cluster.Fixtures, :ensure_runner, [athanor, thread]) ==
               {:error, :held_elsewhere},
             "the peer started a runner for a thread a live member holds"

      # Nothing about the peer's look cost the turn a recovery, which is
      # the fault §6 exists to close: three joins used to end a healthy
      # turn `uncertain`.
      assert Observer.turn(accepted.turn_id)["recovery_attempts"] == 0
      assert Observer.turn(accepted.turn_id)["status"] == "running"
      assert Observer.thread(thread)["active_turn_id"] == accepted.turn_id
    end

    test "becomes takeable once its holder is not a live member, and only then" do
      %{athanor: athanor, thread: thread} = estate(:a, "takeover")

      accepted = Cell.call(:a, Cyfr.Cluster.Fixtures, :accept!, [athanor, thread, "@aqua go"])

      assert {:ok, _turn} =
               Cell.call(:a, Cyfr.Cluster.Fixtures, :start_turn, [
                 athanor,
                 accepted.turn_id,
                 accepted.turn_seq,
                 accepted.fence
               ])

      # Process death: nothing released, nothing logged. The holder's
      # boot goes on naming the turn until its slot lapses on the cell's
      # clock, and until then the peer must keep its hands off.
      Cell.kill(:a)

      assert Cell.call(:b, Cyfr.Cluster.Fixtures, :claim_holder, [athanor, thread]).live_peer?,
             "the peer stopped counting a dead member as live before its lease ran out"

      {noticed_ms, _} =
        Wait.measure!(
          fn ->
            not Cell.call(:b, Cyfr.Cluster.Fixtures, :claim_holder, [athanor, thread]).live_peer?
          end,
          "the dead member's turn never stopped reading as a live peer's"
        )

      Wait.report("a dead holder's turn becomes takeable", noticed_ms, @takeover_bound_ms)

      assert noticed_ms <= @takeover_bound_ms,
             "the turn was takeable only after #{noticed_ms} ms, past §4.1's #{@takeover_bound_ms} ms"

      # And now the survivor may act on the thread, which is the whole
      # point of waiting: recovery is admitted only for a turn whose
      # claim the member has taken.
      assert Cell.call(:b, Cyfr.Cluster.Fixtures, :ensure_runner, [athanor, thread]) == :started
    end
  end

  # An athanor and a thread of this case's own, made on one member and
  # read by both because they are rows.
  defp estate(id, label) do
    athanor = Cell.call(id, Cyfr.Cluster.Fixtures, :athanor!, [label])
    thread = Cell.call(id, Cyfr.Cluster.Fixtures, :thread!, [athanor.id, "cluster #{label}"])
    %{athanor: athanor.id, thread: thread.id}
  end
end
