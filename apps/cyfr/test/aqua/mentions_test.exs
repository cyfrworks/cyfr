# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.MentionsTest do
  # A mention names an entry of the estate's roster — the soul or a role
  # — and only that: a tape runs its own estate's agents, so there is no
  # second tree a name could come from and nothing to qualify.
  use ExUnit.Case, async: true

  alias Aqua.Turn

  defp entry(name), do: %{"name" => name, "title" => name}

  describe "parse_mention/2" do
    test "a bare mention picks the entry, not just its name" do
      assert {"hello", %{"name" => "aqua"}} = Turn.parse_mention("@aqua hello", [entry("aqua")])
    end

    test "longest handle wins, so a suffixed name is not read as a prefix" do
      roster = [entry("aqua"), entry("planner")]
      assert {"go", %{"name" => "planner"}} = Turn.parse_mention("@planner go", roster)
    end

    test "a mention is a whole word" do
      roster = [entry("aqua")]
      assert {"mail me@aqua.example", nil} = Turn.parse_mention("mail me@aqua.example", roster)
      assert {"see aqua", nil} = Turn.parse_mention("see aqua", roster)
    end

    test "no mention leaves the message alone" do
      assert {"just talking", nil} = Turn.parse_mention("just talking", [entry("aqua")])
    end

    test "an empty roster matches nothing, even with an @ in the text" do
      assert {"@aqua hello", nil} = Turn.parse_mention("@aqua hello", [])
    end

    test "a mention that is the whole message keeps the text" do
      # Stripping it would leave an empty task.
      assert {"@aqua", %{"name" => "aqua"}} = Turn.parse_mention("@aqua", [entry("aqua")])
    end

    test "the roster is names and titles alone — no owner, no qualifier" do
      ctx = Sanctum.TestContext.local()

      for entry <- Turn.roster(ctx) do
        assert Map.keys(entry) == ["name", "title"]
      end
    end
  end
end
