# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.RefusedWordsTest do
  @moduledoc """
  What a refused turn says: the action follows what opened the turn
  (`Aqua.Loop.Turn.again/1`), and a refusal for Aqua's grant reads as its
  row's sentence (`Prima.Refusal`).
  """

  use ExUnit.Case, async: true

  alias Aqua.Loop.Turn

  test "a refused turn's action follows what opened it" do
    person = %{origin: "interactive", sent_by: "person", request_id: nil}

    assert Turn.again(person) == :message
    assert Turn.again(%{person | request_id: "msg_req"}) == :ask

    # A page's call runs under the origin of the turn that put the page,
    # opened by the agent: the row has no action for it.
    assert Turn.again(%{person | sent_by: "aqua"}) == :none
    # A crew member's reply that opened Aqua's turn.
    assert Turn.again(%{person | sent_by: "planner"}) == :none
    # A schedule's line is sent as the person's, under the schedule's origin.
    assert Turn.again(%{person | origin: "schedule"}) == :none
    assert Turn.again(%{person | origin: "programmatic"}) == :none
  end

  # A turn refused for Aqua's grant, by the grant's state, reads as its
  # row's sentence with what starts it again where it is read; that no
  # reason a turn's record answers ends a turn as its atom is the runner's
  # proof (`Aqua.RunnerTest`), which ends turns through the loop's end.
  test "a turn refused for Aqua's grant reads as a sentence in every state and ending" do
    for state <- [:agent_changed, :ungranted, :grant_revoked, :consent_moved, :consent_revoked],
        then <- [:message, :ask, :none] do
      text = Aqua.Loop.turn_words({state, "Aqua", then})
      assert String.ends_with?(text, "."), "#{inspect({state, then})} reads as #{inspect(text)}"
      refute text =~ Atom.to_string(state)
    end
  end
end
