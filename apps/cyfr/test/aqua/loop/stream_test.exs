# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.StreamTest do
  @moduledoc """
  What a viewer keeps of a streaming answer: one answer per source, grown
  by newer deltas only; a later step of a source replaces its earlier one;
  a higher fence starts over and a lower one is ignored; and nothing stale
  gets in — a delta under another fence, a delayed delta from a step older
  than its source's highest, or one for a step that landed or was
  abandoned.
  """

  use ExUnit.Case, async: true

  alias Aqua.Loop.Stream
  alias Arca.Schemas.Message

  @fence 3

  defp delta(step_id, ordinal, seq, text, opts \\ []) do
    %{
      turn_id: "turn_1",
      fence: Keyword.get(opts, :fence, @fence),
      source: Keyword.get(opts, :source, "turn_1"),
      role: Keyword.get(opts, :role),
      step_id: step_id,
      ordinal: ordinal,
      seq: seq,
      text: text
    }
  end

  defp keep(deltas), do: Enum.reduce(deltas, Stream.new(@fence), &Stream.add(&2, &1))

  defp text_row(step_id),
    do: %Message{kind: "text", payload: Jason.encode!(%{"step_id" => step_id})}

  test "a step's text grows by newer deltas, and a replayed delta changes nothing" do
    kept =
      keep([
        delta("s1", 1, {3, 1}, "Hel"),
        delta("s1", 1, {3, 2}, "lo"),
        delta("s1", 1, {3, 2}, "lo"),
        delta("s1", 1, {3, 1}, "Hel")
      ])

    assert [%{step_id: "s1", text: "Hello", role: nil}] = Stream.texts(kept)
  end

  test "a delta under another fence, or before any fence is known, is dropped" do
    assert Stream.texts(keep([delta("s1", 1, {1, 1}, "stale", fence: @fence - 1)])) == []
    assert Stream.texts(Stream.add(Stream.new(), delta("s1", 1, {1, 1}, "early"))) == []
  end

  test "a higher fence starts over, and the same or a lower one changes nothing" do
    kept = keep([delta("s1", 1, {1, 1}, "hi")])

    assert Stream.advance(kept, @fence) == kept
    assert Stream.advance(kept, @fence - 1) == kept
    assert Stream.advance(kept, @fence + 1) == Stream.new(@fence + 1)
    assert Stream.advance(Stream.new(), @fence) == Stream.new(@fence)
  end

  test "a retry's step replaces the one it retried, and a delayed delta from the older step is dropped" do
    kept =
      keep([
        delta("s1", 1, {1, 1}, "first try"),
        delta("s2", 2, {1, 1}, "second"),
        delta("s1", 1, {1, 2}, " late"),
        delta("s0", 0, {9, 9}, "older still")
      ])

    assert [%{step_id: "s2", text: "second"}] = Stream.texts(kept)
  end

  test "each source keeps its own answer, in the order they began" do
    kept =
      keep([
        delta("c1", 1, {1, 1}, "clone says", source: "clone_turn", role: "explorer"),
        delta("s1", 1, {1, 1}, "soul says")
      ])

    assert [%{step_id: "c1", role: "explorer"}, %{step_id: "s1", role: nil}] = Stream.texts(kept)
  end

  test "a step's text row replaces its answer, and a delta for it that arrives after is dropped" do
    call_row = %Message{kind: "tool_call", payload: Jason.encode!(%{"step_id" => "s1"})}

    kept = keep([delta("s1", 1, {1, 1}, "hi")])
    assert Stream.landed(kept, call_row) == kept

    landed = Stream.landed(kept, text_row("s1"))
    assert Stream.texts(landed) == []
    assert Stream.texts(Stream.add(landed, delta("s1", 1, {1, 2}, " again"))) == []
  end

  test "once a step's row lands, a delayed delta from an earlier step stays out" do
    kept = keep([delta("s2", 2, {1, 1}, "answer")]) |> Stream.landed(text_row("s2"))

    assert Stream.texts(Stream.add(kept, delta("s1", 1, {1, 1}, "late"))) == []
    assert [%{step_id: "s3"}] = Stream.texts(Stream.add(kept, delta("s3", 3, {1, 1}, "next")))
  end

  test "an abandoned step's answer is withdrawn and stays out, under its own fence only" do
    kept = keep([delta("s1", 1, {1, 1}, "partial")])
    marker = %{turn_id: "turn_1", fence: @fence, source: "turn_1", step_id: "s1", ordinal: 1}

    assert Stream.abandoned(kept, %{marker | fence: @fence - 1}) == kept

    abandoned = Stream.abandoned(kept, marker)
    assert Stream.texts(abandoned) == []
    assert Stream.texts(Stream.add(abandoned, delta("s1", 1, {1, 2}, " more"))) == []
    assert Stream.texts(Stream.add(abandoned, delta("s0", 0, {1, 1}, "older"))) == []

    abandoned_unseen = Stream.abandoned(Stream.new(@fence), %{marker | step_id: "s4", ordinal: 4})
    assert Stream.texts(Stream.add(abandoned_unseen, delta("s1", 1, {1, 1}, "late"))) == []
  end
end
