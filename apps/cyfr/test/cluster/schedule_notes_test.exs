# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/support.exs", __DIR__)

defmodule Cyfr.Cluster.ScheduleNotesTest do
  @moduledoc """
  Two members, one finished run whose outcome asks to be kept.

  The finish records the outcome in the outbox in its own transaction,
  and the note is kept from that record by whichever member's notes
  keeper (`Aqua.ScheduleNotes`) holds the athanor's `schedule_notes`
  claim. A member that took the claim and died leaves the work to its
  peer once the claim's lease lapses, and the peer keeps the note once;
  two members draining at once keep it once.
  """

  use Cyfr.Cluster.Case, async: false

  defp note(member, athanor, name),
    do: Cell.call(member, Cyfr.Cluster.Boot, :note, [athanor.id, name])

  defp outcome(member, athanor, occurrence_id),
    do: Cell.call(member, Cyfr.Cluster.Boot, :notes_outcome, [athanor.id, occurrence_id])

  test "a member that held the work and died leaves it to its peer, which keeps the note once its claim lapsed" do
    athanor = Cell.call(:a, Fixtures, :athanor!, ["notes-takeover"])
    schedule_id = Cell.call(:a, Cyfr.Cluster.Boot, :keeping_schedule!, [athanor.id, "takeover"])

    # The member takes the athanor's notes, its keeper then stops, and its
    # run finishes there: the outcome is a committed record nobody works.
    _claim = Cell.call(:a, Cyfr.Cluster.Boot, :hold_notes!, [athanor.id, 3_000])

    occurrence_id =
      Cell.call(:a, Cyfr.Cluster.Boot, :finished_run!, [
        athanor.id,
        schedule_id,
        %{"from" => "a"}
      ])

    # While the dead member's claim stands, the peer does not step in.
    assert Cell.call(:b, Cyfr.Cluster.Boot, :drain_notes, [athanor.id]) == :busy
    assert note(:b, athanor, schedule_id) == :none

    Cell.kill(:a)

    Wait.until!(
      fn ->
        Cell.call(:b, Cyfr.Cluster.Boot, :drain_notes, [athanor.id])
        outcome(:b, athanor, occurrence_id) == "applied"
      end,
      "the peer to keep the note once the dead member's claim lapsed"
    )

    assert %{revision: 1, content: content, kept_by: kept_by} = note(:b, athanor, schedule_id)
    assert content =~ ~s("from":"a")
    assert kept_by == "schedule:" <> schedule_id
    assert Cell.call(:b, Cyfr.Cluster.Boot, :drain_notes, [athanor.id]) == {:ok, %{}}
    assert %{revision: 1} = note(:b, athanor, schedule_id)
  end

  test "both members draining one athanor at once keep its note once" do
    athanor = Cell.call(:a, Fixtures, :athanor!, ["notes-race"])
    schedule_id = Cell.call(:a, Cyfr.Cluster.Boot, :keeping_schedule!, [athanor.id, "race"])

    occurrence_id =
      Cell.call(:b, Cyfr.Cluster.Boot, :finished_run!, [athanor.id, schedule_id, "raced"])

    drain = {Cyfr.Cluster.Boot, :drain_notes, [athanor.id]}
    results = Barrier.race(a: drain, b: drain)

    applied = for {member, {:ok, %{"applied" => 1}}} <- results, do: member
    assert length(applied) <= 1, inspect(results)

    # Either a racer kept it, or each found the other holding the claim or
    # the record already answered; the members' own keepers may have
    # reached it first on a completion or a tick.
    Wait.until!(
      fn ->
        Cell.call(:a, Cyfr.Cluster.Boot, :drain_notes, [athanor.id])
        outcome(:a, athanor, occurrence_id) == "applied"
      end,
      "one member to keep the note"
    )

    assert %{revision: 1, content: "raced"} = note(:a, athanor, schedule_id)
    assert %{revision: 1} = note(:b, athanor, schedule_id)
  end
end
