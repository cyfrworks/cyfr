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

  test "the wire type is the tree's: the reserved name is the soul, every other name a role" do
    assert AquaAgent.type_of(agent(%{name: "aqua"})) == AquaAgent.soul_type()
    assert AquaAgent.type_of(agent()) == AquaAgent.role_type()
    # Persisted picks and the console's filters read these values back, so
    # the spelling is pinned with the fact that it is read from here.
    assert AquaAgent.soul_type() == "soul"
    assert AquaAgent.role_type() == "role"
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

  defp with_policy(yaml), do: "---\ntool_policy:\n#{yaml}---\n\nprompt\n"

  test "the policy grammar parses: ask/auto over tool.action, tool.* and native_search" do
    file = with_policy("  files.read: auto\n  aqua_web.*: ask\n  native_search: auto\n")

    assert {:ok, %{tool_policy: policy}} = AquaAgent.parse("x", file)
    assert policy == %{"files.read" => "auto", "aqua_web.*" => "ask", "native_search" => "auto"}

    # An absent policy is the empty allowlist; an empty one parses too.
    assert {:ok, %{tool_policy: %{}}} = AquaAgent.parse("x", "---\ntitle: X\n---\n\nprompt\n")
    assert :ok = AquaAgent.check_tool_policy(%{})
  end

  test "a policy outside the grammar refuses the file with its typed reason" do
    # The guest treats only "auto" as automatic and anything else as ask,
    # so a value outside the vocabulary must never reach it.
    assert {:error, {:tool_policy_invalid_value, "files.read", "never"}} =
             AquaAgent.parse("x", with_policy("  files.read: never\n"))

    assert {:error, {:tool_policy_invalid_value, "files.read", true}} =
             AquaAgent.parse("x", with_policy("  files.read: true\n"))

    assert {:error, {:tool_policy_invalid_key, "files"}} =
             AquaAgent.parse("x", with_policy("  files: auto\n"))

    assert {:error, {:tool_policy_invalid_key, "a.b.c"}} =
             AquaAgent.parse("x", with_policy("  a.b.c: auto\n"))

    assert {:error, :tool_policy_not_a_map} =
             AquaAgent.parse("x", "---\ntool_policy: auto\n---\n\nprompt\n")

    # The same rule, asked directly — the tool door calls this one.
    assert {:error, {:tool_policy_invalid_value, "a.b", "allow"}} =
             AquaAgent.check_tool_policy(%{"a.b" => "allow"})

    assert {:error, {:tool_policy_invalid_key, 1}} = AquaAgent.check_tool_policy(%{1 => "auto"})
    assert {:error, :tool_policy_not_a_map} = AquaAgent.check_tool_policy("auto")
  end
end
