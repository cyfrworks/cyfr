# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/support.exs", __DIR__)

defmodule Cyfr.Cluster.ScheduleTest do
  @moduledoc """
  Two schedulers, one due occurrence.

  `cell-ownership.md` §4.8 says firing is already safe: occurrence
  uniqueness on `(schedule_id, scheduled_for)` plus the transactional
  cursor advance means two members racing one due schedule produce one
  occurrence. Every member arms its own timer for every active schedule,
  so in a cell that race happens on every tick of every schedule — which
  is why it is worth a case with two real schedulers rather than three
  strings standing in for members.
  """

  use Cyfr.Cluster.Case, async: false

  describe "one due schedule" do
    test "is claimed by one member, and the other is told it is held" do
      athanor = Cell.call(:a, Cyfr.Cluster.Fixtures, :athanor!, ["schedule"])
      schedule = Cell.call(:a, Cyfr.Cluster.Fixtures, :due_schedule!, [athanor.id, 60])
      next = DateTime.add(DateTime.utc_now(), 3600, :second)

      first = Cell.call(:a, Cyfr.Cluster.Fixtures, :claim_occurrence, [schedule.id, next])
      second = Cell.call(:b, Cyfr.Cluster.Fixtures, :claim_occurrence, [schedule.id, next])

      assert {:ok, occurrence} = first
      assert occurrence.state == "claimed"
      assert second == :held, "the peer claimed an occurrence a member already had"

      # One occurrence, read from outside both, and it names the boot that
      # won it — a boot, not a node: a restarted member does not inherit
      # its predecessor's claim.
      assert [row] = Observer.occurrences(schedule.id)
      assert row["id"] == occurrence.id
      assert row["claimed_by"] == Cell.call(:a, Cyfr.Cluster.Fixtures, :boot, [])
    end

    test "raced from a barrier, produces exactly one occurrence" do
      athanor = Cell.call(:a, Cyfr.Cluster.Fixtures, :athanor!, ["schedule-race"])
      schedule = Cell.call(:a, Cyfr.Cluster.Fixtures, :due_schedule!, [athanor.id, 60])
      next = DateTime.add(DateTime.utc_now(), 3600, :second)

      claim = {Cyfr.Cluster.Fixtures, :claim_occurrence, [schedule.id, next]}
      results = Barrier.race(a: claim, b: claim)

      won = for {member, {:ok, occurrence}} <- results, do: {member, occurrence}
      assert length(won) == 1, "two members claimed one occurrence: #{inspect(results)}"

      losers = for {_m, answer} <- results, not match?({:ok, _}, answer), do: answer
      assert losers == [:held], inspect(results)

      assert length(Observer.occurrences(schedule.id)) == 1
    end

    test "is not claimed again once the cursor has moved past it" do
      athanor = Cell.call(:a, Cyfr.Cluster.Fixtures, :athanor!, ["schedule-cursor"])
      schedule = Cell.call(:a, Cyfr.Cluster.Fixtures, :due_schedule!, [athanor.id, 60])
      next = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert {:ok, _} = Cell.call(:a, Cyfr.Cluster.Fixtures, :claim_occurrence, [schedule.id, next])

      # The cursor advanced in the same transaction as the claim, so the
      # schedule is no longer due — on the cell's clock, which is what
      # keeps a member with a fast clock from firing early for its peers.
      assert Cell.call(:b, Cyfr.Cluster.Fixtures, :claim_occurrence, [schedule.id, next]) == :held
      assert Cell.call(:a, Cyfr.Cluster.Fixtures, :claim_occurrence, [schedule.id, next]) == :held
      assert length(Observer.occurrences(schedule.id)) == 1
    end
  end
end
