# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/support.exs", __DIR__)

defmodule Cyfr.Cluster.ScheduleNotesTest do
  @moduledoc """
  Two members, one committed schedule completion.

  The completion is published on a topic every member hears
  (`Cyfr.Bus.schedule_completions/0`), and every member runs a notes keeper
  (`Aqua.ScheduleNotes`). Only the member whose slot issued the completion
  writes, so a peer's delivery is no second write; a second delivery to the
  issuer finds the execution already recorded; and a member that lost its
  slot before writing writes nothing, anywhere.
  """

  use Cyfr.Cluster.Case, async: false

  defp completion(member, athanor, label) do
    Cell.call(member, Cyfr.Cluster.Boot, :completion, [
      athanor.id,
      "sched_#{label}",
      "exec_#{label}"
    ])
  end

  defp settle!(members),
    do: for(m <- members, do: Cell.call(m, Cyfr.Cluster.Boot, :settle_notes, []))

  defp note(member, athanor, name),
    do: Cell.call(member, Cyfr.Cluster.Boot, :note, [athanor.id, name])

  test "a completion both members hear is kept once, by the member that issued it" do
    athanor = Cell.call(:a, Cyfr.Cluster.Fixtures, :athanor!, ["notes-one"])
    issued = completion(:a, athanor, "one")

    assert :ok = Cell.call(:b, Cyfr.Cluster.Boot, :publish_completion, [issued])

    # The message crosses to the issuer's keeper over the cell's own
    # distribution, on no schedule this case controls.
    Wait.until!(
      fn -> note(:a, athanor, issued.schedule_id) != :none end,
      "the issuing member to keep the note"
    )

    settle!([:a, :b])
    note = note(:a, athanor, issued.schedule_id)
    assert %{execution: execution, kept_by: kept_by} = note
    assert execution == issued.execution_id
    assert kept_by == "schedule:" <> issued.schedule_id

    # The peer heard it too, and is not its issuer; the issuer, asked again,
    # finds the execution already recorded.
    assert Cell.call(:b, Aqua.ScheduleNotes, :keep, [issued]) == :skipped
    assert Cell.call(:a, Aqua.ScheduleNotes, :keep, [issued]) == :duplicate
    assert note(:a, athanor, issued.schedule_id).kept_at == note.kept_at
  end

  test "a completion issued by the other member is not kept here" do
    athanor = Cell.call(:a, Cyfr.Cluster.Fixtures, :athanor!, ["notes-peer"])
    issued = completion(:b, athanor, "peer")

    assert Cell.call(:a, Aqua.ScheduleNotes, :keep, [issued]) == :skipped
    assert note(:a, athanor, issued.schedule_id) == :none
  end

  test "a member that lost its slot before the write writes nothing, and its peer does not step in" do
    athanor = Cell.call(:a, Cyfr.Cluster.Fixtures, :athanor!, ["notes-lost"])
    issued = completion(:a, athanor, "lost")

    assert Cell.call(:a, Cyfr.Cluster.Boot, :keep_without_slot, [issued]) == :skipped
    assert Cell.call(:b, Aqua.ScheduleNotes, :keep, [issued]) == :skipped
    assert note(:a, athanor, issued.schedule_id) == :none
    assert note(:b, athanor, issued.schedule_id) == :none
  end
end
