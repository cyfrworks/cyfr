# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.PlannerTest do
  @moduledoc """
  The planner fits or names a boundary: the window less the output
  ceiling and a margin is what a request may hold; the boundary is the
  start of the oldest step group that still fits, so a tool call is
  never parted from its results; pruning bounds old results in the
  projection alone.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Aqua.Loop.Planner
  alias Arca.Schemas.Message

  @caps %{context_window: 100_000, max_output_tokens: 8_192}

  defp paired(seq, kind, content, step, call_id) do
    row = row(seq, kind, content, step)
    payload = Jason.decode!(row.payload || "{}") |> Map.put("tool_call_id", call_id)
    %{row | payload: Jason.encode!(payload)}
  end

  defp row(seq, kind, content, step \\ nil) do
    %Message{
      id: "msg_#{seq}",
      seq: seq,
      kind: kind,
      author: if(kind == "text" and rem(seq, 2) == 1, do: "usr_a", else: Message.agent_author()),
      content: content,
      payload: if(step, do: Jason.encode!(%{"step_id" => step}), else: nil)
    }
  end

  test "a large call and its small result are kept or dropped together" do
    big = String.duplicate("x", 40_000)

    # The call is what costs; the answer is one word. Grouped by id alone
    # the result stands apart, the walk back keeps it, and the call it
    # answers is summarized away — a `tool_result` with no `tool_call`,
    # which providers reject and which nothing downstream repairs
    # (`Request.answer_dangling_calls/1` only patches the other direction).
    rows = [
      row(1, "text", "reply", "s1"),
      row(2, "tool_call", big, "s1"),
      row(3, "tool_result", "ok", "s1_call"),
      row(4, "text", "done", "s2")
    ]

    assert %{first_kept_seq: 4} = Planner.boundary(rows, 2_000)
  end

  test "a card between a call and its answer does not let the boundary part them" do
    big = String.duplicate("x", 40_000)

    # What a call needing approval writes: the card lands between the call
    # and the result, and carries no step id of its own.
    rows = [
      paired(1, "tool_call", big, "s1", "call_1"),
      row(2, "approval", "may I?"),
      paired(3, "tool_result", "ok", "s1_call", "call_1"),
      row(4, "text", "done", "s2")
    ]

    # Keeping only the newest would drop the call and keep its answer.
    assert %{first_kept_seq: 1} = Planner.boundary(rows, 2_000)
  end

  test "a compacted transcript is measured by what the model reads, not the whole of it" do
    old_rows = for seq <- 1..40, do: row(seq, "text", String.duplicate("x", 40_000))

    compaction =
      %{row(41, "compaction", "the story so far") | payload: %{"first_kept_seq" => 41}}

    rows = old_rows ++ [compaction, row(42, "text", "carry on")]

    # The projection keeps every summarized row; only the request drops
    # them. Measuring all of them compacts again on the first round of
    # every later turn, for one more summary call and one more row.
    assert :fit = Planner.plan(rows, capabilities: @caps, max_tokens: 16_384)

    assert Planner.readable(rows) == [compaction, row(42, "text", "carry on")]
  end

  test "readable keeps only the latest summary" do
    first = %{row(2, "compaction", "first") | payload: %{"first_kept_seq" => 2}}
    second = %{row(4, "compaction", "second") | payload: %{"first_kept_seq" => 4}}
    rows = [row(1, "text", "a"), first, row(3, "text", "b"), second, row(5, "text", "c")]

    assert Planner.readable(rows) == [second, row(5, "text", "c")]
  end

  test "usable is the window less the output ceiling and the margin" do
    assert Planner.usable(@caps, 16_384) == 100_000 - 16_384 - 8_000
  end

  test "a small transcript fits, an observed size past the fill compacts, and bytes past the cap compact" do
    rows = [row(1, "text", "hi"), row(2, "text", "hello")]
    assert :fit = Planner.plan(rows, capabilities: @caps, max_tokens: 16_384)

    # Two tiny rows both fit the kept tail: the boundary is the first row,
    # and the compaction summarizes nothing older than it.
    assert {:compact, %{first_kept_seq: 1, summarized_through_seq: 0}} =
             Planner.plan(rows, capabilities: @caps, max_tokens: 16_384, observed_tokens: 90_000)

    assert {:compact, _} =
             Planner.plan(rows,
               capabilities: @caps,
               max_tokens: 16_384,
               request_bytes: 2_000_000,
               max_request_size: 1_048_576
             )

    assert :fit =
             Planner.plan([], capabilities: @caps, max_tokens: 16_384, observed_tokens: 90_000)
  end

  test "the boundary never parts a tool call from its results" do
    big = String.duplicate("x", 40_000)

    # A result carries its own CALL step's id, not the model step's, which
    # is what `TurnStorage` writes. Giving both the same id describes a
    # transcript the product never produces.
    rows = [
      row(1, "text", "ask"),
      row(2, "text", "reply", "s1"),
      row(3, "tool_call", "files.read", "s1"),
      row(4, "tool_result", big, "s1_call"),
      row(5, "text", "more", "s2"),
      row(6, "tool_call", "files.read", "s2"),
      row(7, "tool_result", big, "s2_call"),
      row(8, "text", "done", "s3")
    ]

    # Keeping ~12k tokens fits the s3 row and the s2 group, not s1.
    assert %{first_kept_seq: 5, summarized_through_seq: 4} = Planner.boundary(rows, 12_000)
    # Too small for even one group: the newest group is kept whole.
    assert %{first_kept_seq: 8} = Planner.boundary(rows, 1)
    # Everything fits: the boundary is the first row.
    assert %{first_kept_seq: 1, summarized_through_seq: 0} = Planner.boundary(rows, 1_000_000)
  end

  property "a boundary always falls on the start of a step group" do
    check all(
            steps <- list_of(integer(1..6), min_length: 1, max_length: 12),
            keep <- integer(1..5_000)
          ) do
      {rows, _} =
        Enum.reduce(Enum.with_index(steps, 1), {[], 1}, fn {n, i}, {acc, seq} ->
          step = "s#{i}"
          content = String.duplicate("y", n * 300)

          group = [
            row(seq, "text", "r", step),
            row(seq + 1, "tool_call", "c", step),
            row(seq + 2, "tool_result", content, step)
          ]

          {acc ++ group, seq + 3}
        end)

      %{first_kept_seq: first} = Planner.boundary(rows, keep)
      starts = rows |> Enum.filter(&(&1.kind == "text")) |> Enum.map(& &1.seq)
      assert first in starts
    end
  end

  test "pruning bounds old tool results in the projection only" do
    long = String.duplicate("z", 2_000)
    rows = for seq <- 1..25, do: row(seq, "tool_result", long, "s#{seq}")
    pruned = Planner.prune(rows)
    assert Enum.take(pruned, 5) |> Enum.all?(&(byte_size(&1.content) < 600))
    assert Enum.drop(pruned, 5) |> Enum.all?(&(&1.content == long))
    assert Enum.all?(rows, &(&1.content == long))
  end

  test "the summary request carries the previous summary, the rows and the instruction, and no tools" do
    messages = [%{"role" => "user", "content" => [%{"type" => "text", "text" => "hi"}]}]

    request =
      Planner.summary_request(messages, model: "m", previous_summary: "earlier")

    assert request["model"] == "m"
    [first, second, last] = request["messages"]
    assert [%{"text" => "[Summary so far]\nearlier"}] = first["content"]
    assert second == hd(messages)
    assert hd(last["content"])["text"] =~ "handoff summary"
    refute Map.has_key?(request, "tools")
    assert Planner.estimate_tokens("abcdefgh") == 2
  end
end
