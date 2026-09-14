# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.StreamTest do
  @moduledoc """
  What a viewer keeps of a streaming answer: one answer per source, grown
  by newer deltas only; a later step of a source replaces its earlier one,
  and nothing stale gets in — a delta of another generation, a delayed
  delta from an older step, or one for a step whose text row landed.
  """

  use ExUnit.Case, async: true

  alias Aqua.Loop.Stream
  alias Arca.Schemas.Message

  @generation "gen-current"

  defp delta(step_id, ordinal, seq, text, opts \\ []) do
    %{
      turn_id: "turn_1",
      generation: Keyword.get(opts, :generation, @generation),
      source: Keyword.get(opts, :source, "turn_1"),
      role: Keyword.get(opts, :role),
      step_id: step_id,
      ordinal: ordinal,
      seq: seq,
      text: text
    }
  end

  defp keep(deltas), do: Enum.reduce(deltas, Stream.new(@generation), &Stream.add(&2, &1))

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

  test "a delta of another generation, or before any generation is known, is dropped" do
    assert Stream.texts(keep([delta("s1", 1, {1, 1}, "stale", generation: "gen-old")])) == []

    assert Stream.texts(Stream.add(Stream.new(), delta("s1", 1, {1, 1}, "early"))) == []
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
    text_row = %Message{kind: "text", payload: Jason.encode!(%{"step_id" => "s1"})}
    call_row = %Message{kind: "tool_call", payload: Jason.encode!(%{"step_id" => "s1"})}

    kept = keep([delta("s1", 1, {1, 1}, "hi")])
    assert Stream.landed(kept, call_row) == kept

    landed = Stream.landed(kept, text_row)
    assert Stream.texts(landed) == []
    assert Stream.texts(Stream.add(landed, delta("s1", 1, {1, 2}, " again"))) == []
  end

  test "a generation names no fence" do
    fence = "fence-" <> Base.encode16(:crypto.strong_rand_bytes(8))
    generation = Stream.generation(%Arca.Schemas.Turn{fence: fence})

    assert byte_size(generation) == 16
    refute generation =~ fence
    assert Stream.generation(%Arca.Schemas.Turn{fence: fence}) == generation
  end
end
