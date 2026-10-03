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
        tool_policy: %{"files.read" => "auto", "web.*" => "auto", "native_search" => "ask"},
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
    file = with_policy("  files.read: auto\n  web.*: ask\n  native_search: auto\n")

    assert {:ok, %{tool_policy: policy}} = AquaAgent.parse("x", file)
    assert policy == %{"files.read" => "auto", "web.*" => "ask", "native_search" => "auto"}

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

  # The security-relevant subset: what an agent is and may do, never what
  # it says. Two agents that differ only in prose share a capability.
  test "to_manifest/1 projects the capability and nothing of the prose" do
    role = %{
      name: "scout",
      title: "Scout",
      description: "Looks around",
      disabled: false,
      catalyst_ref: "catalyst:moonmoon69.claude",
      model: "claude-sonnet-4-6",
      tool_policy: %{"files.read" => "auto"},
      prompt: "You look around."
    }

    manifest = AquaAgent.to_manifest(role)
    assert manifest["name"] == "scout"
    assert manifest["type"] == AquaAgent.role_type()
    assert manifest["catalyst_ref"] == "catalyst:moonmoon69.claude"
    assert manifest["tool_policy"] == %{"files.read" => "auto"}
    refute Map.has_key?(manifest, "prompt")
    refute Map.has_key?(manifest, "title")

    {:ok, digest} = AquaAgent.capability_digest(role)

    {:ok, same} =
      AquaAgent.capability_digest(%{role | prompt: "Something else.", title: "Renamed"})

    assert digest == same

    {:ok, other} = AquaAgent.capability_digest(%{role | tool_policy: %{"files.read" => "ask"}})
    refute digest == other
  end

  # What an authored policy may say, on top of the grammar: the rule the
  # `aqua` tool door applies to every write.
  describe "validate_tool_policy/2" do
    test "a destructive or external action is never auto, on any agent" do
      assert {:error, msg} =
               AquaAgent.validate_tool_policy(%{"files.delete" => "auto"}, AquaAgent.soul_type())

      assert msg =~ "always asks"

      assert {:error, _} =
               AquaAgent.validate_tool_policy(%{"http.delete" => "auto"}, AquaAgent.role_type())

      assert :ok =
               AquaAgent.validate_tool_policy(%{"files.delete" => "ask"}, AquaAgent.soul_type())

      assert :ok =
               AquaAgent.validate_tool_policy(%{"files.write" => "auto"}, AquaAgent.soul_type())
    end

    test "a glob at auto that covers a destructive action is refused with the actions named" do
      assert {:error, msg} =
               AquaAgent.validate_tool_policy(%{"files.*" => "auto"}, AquaAgent.soul_type())

      assert msg =~ "files.delete"
      assert :ok = AquaAgent.validate_tool_policy(%{"files.*" => "ask"}, AquaAgent.soul_type())
    end

    test "a role holds nothing at ask — it has no card to raise" do
      assert {:error, msg} =
               AquaAgent.validate_tool_policy(%{"files.write" => "ask"}, AquaAgent.role_type())

      assert msg =~ "no card"

      assert :ok =
               AquaAgent.validate_tool_policy(%{"files.write" => "auto"}, AquaAgent.role_type())

      assert :ok =
               AquaAgent.validate_tool_policy(%{"files.write" => "ask"}, AquaAgent.soul_type())
    end

    test "a role's delegation glob and the search gate pass" do
      assert :ok =
               AquaAgent.validate_tool_policy(
                 %{"builder.*" => "auto", "native_search" => "auto"},
                 AquaAgent.soul_type()
               )
    end

    test "a UI event is auto or absent" do
      assert {:error, msg} =
               AquaAgent.validate_tool_policy(
                 %{"request_setup.open" => "ask"},
                 AquaAgent.soul_type()
               )

      assert msg =~ "runs on its own"

      assert :ok =
               AquaAgent.validate_tool_policy(
                 %{"request_setup.open" => "auto", "files.read" => "ask"},
                 AquaAgent.soul_type()
               )
    end

    test "a catalogued tool's kind is its operation-table annotation" do
      assert {:error, msg} =
               AquaAgent.validate_tool_policy(
                 %{"component.delete" => "auto"},
                 AquaAgent.soul_type()
               )

      assert msg =~ "always asks"

      assert {:error, msg} =
               AquaAgent.validate_tool_policy(%{"component.*" => "auto"}, AquaAgent.soul_type())

      assert msg =~ "component.delete"

      # An upstream server's tool is external whatever the action; a tool
      # neither table holds has no kind and is left to the runtime ceiling.
      assert {:error, _} =
               AquaAgent.validate_tool_policy(
                 %{"srv:search.run" => "auto"},
                 AquaAgent.soul_type()
               )

      assert :ok =
               AquaAgent.validate_tool_policy(%{"nosuch.thing" => "auto"}, AquaAgent.soul_type())
    end

    test "the grammar is checked first, with its typed reason" do
      assert {:error, {:tool_policy_invalid_value, "files.read", "never"}} =
               AquaAgent.validate_tool_policy(%{"files.read" => "never"}, AquaAgent.soul_type())

      assert {:error, :tool_policy_not_a_map} =
               AquaAgent.validate_tool_policy("auto", AquaAgent.role_type())
    end
  end
end
