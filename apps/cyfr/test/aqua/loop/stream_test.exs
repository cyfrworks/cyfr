# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.StreamTest do
  @moduledoc """
  What a viewer keeps of a streaming answer: each step's text grows by
  newer deltas only, a new step of the same role replaces one that ended
  without a row, and a step's text row takes its place.
  """

  use ExUnit.Case, async: true

  alias Aqua.Loop.Stream
  alias Arca.Schemas.Message

  defp delta(step_id, seq, text, role \\ nil),
    do: %{turn_id: "turn_1", step_id: step_id, seq: seq, text: text, role: role}

  test "a step's text grows by newer deltas, and a replayed delta changes nothing" do
    partials =
      []
      |> Stream.add(delta("s1", {3, 1}, "Hel"))
      |> Stream.add(delta("s1", {3, 2}, "lo"))
      |> Stream.add(delta("s1", {3, 2}, "lo"))
      |> Stream.add(delta("s1", {3, 1}, "Hel"))

    assert [%{step_id: "s1", text: "Hello", seq: {3, 2}}] = partials
  end

  test "a new step replaces its role's earlier one and leaves other roles' text" do
    partials =
      []
      |> Stream.add(delta("s1", {1, 1}, "draft"))
      |> Stream.add(delta("c1", {1, 1}, "clone says", "explorer"))
      |> Stream.add(delta("s2", {2, 1}, "retry"))

    assert [%{step_id: "c1", role: "explorer"}, %{step_id: "s2", text: "retry"}] = partials
  end

  test "a step's text row lands in place of its streamed text; other rows change nothing" do
    partials = [delta("s1", {1, 1}, "hi"), delta("c1", {1, 1}, "yo", "web")]
    partials = Enum.map(partials, &Map.delete(&1, :turn_id))

    text_row = %Message{kind: "text", payload: Jason.encode!(%{"step_id" => "s1"})}
    call_row = %Message{kind: "tool_call", payload: Jason.encode!(%{"step_id" => "c1"})}

    assert [%{step_id: "c1"}] = Stream.landed(partials, text_row)
    assert Stream.landed(partials, call_row) == partials
  end
end
