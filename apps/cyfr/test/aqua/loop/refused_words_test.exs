# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.RefusedWordsTest do
  @moduledoc """
  What a refused turn says: the action follows what opened the turn
  (`Aqua.Loop.Turn.again/1`), and no reason the loop can store reaches a
  thread or a turn's error as its atom (`Aqua.Loop.describe/1`).
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Aqua.Loop.Turn

  @lib Path.expand("../../../lib/aqua", __DIR__)

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

  test "no reason the loop can store as a turn's end or line reads as its atom" do
    sources =
      [Path.join(@lib, "loop.ex") | Path.wildcard(Path.join(@lib, "{loop,harness}/*.ex"))]

    # A name only a comment or a doc spells is no atom the running code
    # holds, and no reason the loop can store.
    atoms =
      for path <- sources,
          [_, name] <- Regex.scan(~r/\{:(?:error|failed), :([a-z_]+)\}/, File.read!(path)),
          atom = existing(name),
          atom != nil,
          uniq: true,
          do: atom

    assert :agent_moved in atoms and :no_pin in atoms

    {said, _log} =
      with_log(fn ->
        for atom <- atoms, do: {atom, Aqua.Loop.turn_words(atom)}
      end)

    for {atom, text} <- said do
      assert is_binary(text) and text != "", "#{inspect(atom)} reads as nothing"
      refute text == Atom.to_string(atom), "#{inspect(atom)} reads as its atom"
    end

    for state <- [:agent_changed, :ungranted, :grant_revoked, :consent_moved, :consent_revoked],
        then <- [:message, :ask, :none] do
      text = Aqua.Loop.turn_words({state, "Aqua", then})
      assert String.ends_with?(text, "."), "#{inspect({state, then})} reads as #{inspect(text)}"
      refute text =~ Atom.to_string(state)
    end
  end

  defp existing(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end
end
