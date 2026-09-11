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

    rows = [
      row(1, "text", "ask"),
      row(2, "text", "reply", "s1"),
      row(3, "tool_call", "files.read", "s1"),
      row(4, "tool_result", big, "s1"),
      row(5, "text", "more", "s2"),
      row(6, "tool_call", "files.read", "s2"),
      row(7, "tool_result", big, "s2"),
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

  test "the summary request carries the previous summary, the rows and the instruction" do
    messages = [%{"role" => "user", "content" => [%{"type" => "text", "text" => "hi"}]}]

    request =
      Planner.summary_request(messages,
        model: "m",
        previous_summary: "earlier",
        tools: [%{"name" => "notes.keep"}]
      )

    assert request["model"] == "m"
    [first, second, last] = request["messages"]
    assert [%{"text" => "[Summary so far]\nearlier"}] = first["content"]
    assert second == hd(messages)
    assert hd(last["content"])["text"] =~ "handoff summary"
    assert [%{"name" => "notes.keep"}] = request["tools"]
    refute Map.has_key?(Planner.summary_request(messages, model: "m"), "tools")
    assert Planner.estimate_tokens("abcdefgh") == 2
  end
end
