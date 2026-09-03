# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AquaAgentTest do
  @moduledoc """
  The agent file format: frontmatter round-trips byte-stably, and a
  disabled role leaves the closet without leaving the tree. Which file is
  the soul is the tree's to say, never the frontmatter's.
  """

  use ExUnit.Case, async: true

  alias Compendium.AquaAgent

  defp agent(overrides \\ %{}) do
    Map.merge(
      %{
        name: "scribe",
        title: "Scribe",
        description: "writes things — carefully: with \"quotes\" and colons",
        disabled: false,
        catalyst_ref: "catalyst:moonmoon69.claude",
        model: "claude-sonnet-4-6",
        tool_policy: %{"files.read" => "auto", "aqua_web.*" => "auto", "native_search" => "ask"},
        prompt: "You are the scribe.\n\n## Style\n\n- terse"
      },
      overrides
    )
  end

  test "serialize/parse round-trips every field" do
    original = agent()
    assert {:ok, parsed} = AquaAgent.parse("scribe", AquaAgent.serialize(original))
    assert parsed == original

    soul = agent(%{name: "aqua", disabled: true})

    assert {:ok, parsed} = AquaAgent.parse("aqua", AquaAgent.serialize(soul))
    assert parsed == soul
  end

  test "serialization is stable — a second round-trip is byte-identical" do
    binary = AquaAgent.serialize(agent())
    {:ok, parsed} = AquaAgent.parse("scribe", binary)
    assert AquaAgent.serialize(parsed) == binary
  end

  test "the name comes from the filename, never the frontmatter" do
    {:ok, parsed} = AquaAgent.parse("other", AquaAgent.serialize(agent()))
    assert parsed.name == "other"
  end

  test "a portable minimal file parses — frontmatter defaults fill in" do
    minimal = "---\ndescription: does things\n---\n\nYou are minimal.\n"

    assert {:ok, parsed} = AquaAgent.parse("min", minimal)
    assert parsed.title == "min"
    assert parsed.tool_policy == %{}
    assert parsed.prompt == "You are minimal."
  end

  test "a file without frontmatter is a typed refusal" do
    assert {:error, :frontmatter_missing} = AquaAgent.parse("x", "just a prompt")
    assert {:error, :frontmatter_unterminated} = AquaAgent.parse("x", "---\ntitle: X\n")
  end
end
