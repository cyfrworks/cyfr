# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AquaAgentTest do
  @moduledoc """
  The agent file format: frontmatter round-trips byte-stably, a disabled
  crew member leaves the crew without leaving the tree, and a crew file
  holds no policy of its own: a member runs under the soul's. Which file
  is the soul is the tree's to say, never the frontmatter's.
  """

  use ExUnit.Case, async: true

  alias Compendium.AquaAgent

  defp member(overrides \\ %{}) do
    Map.merge(
      %{
        name: "scribe",
        title: "Scribe",
        description: "writes things — carefully: with \"quotes\" and colons",
        avoid: "numbers: never",
        disabled: false,
        catalyst_ref: "catalyst:moonmoon69.claude",
        model: "claude-sonnet-5-5",
        options: %{"effort" => "high", "budget" => 8, "thinking" => true, "label" => "true"},
        tool_policy: %{},
        prompt: "You are the scribe.\n\n## Style\n\n- terse"
      },
      overrides
    )
  end

  defp soul(overrides \\ %{}) do
    member(
      Map.merge(
        %{
          name: "aqua",
          avoid: "",
          tool_policy: %{"files.read" => "auto", "web.*" => "auto", "native_search" => "ask"}
        },
        overrides
      )
    )
  end

  test "serialize/parse round-trips every field, each option keeping its kind" do
    original = member()
    assert {:ok, parsed} = AquaAgent.parse("scribe", AquaAgent.serialize(original))
    assert parsed == original
    # A string that reads like a boolean stays a string.
    assert parsed.options["label"] == "true"

    soul = soul(%{disabled: true})

    assert {:ok, parsed} = AquaAgent.parse("aqua", AquaAgent.serialize(soul))
    assert parsed == soul
  end

  test "serialization is stable — a second round-trip is byte-identical" do
    for {name, agent} <- [{"scribe", member()}, {"aqua", soul()}] do
      binary = AquaAgent.serialize(agent)
      {:ok, parsed} = AquaAgent.parse(name, binary)
      assert AquaAgent.serialize(parsed) == binary
    end
  end

  test "the wire type is the tree's: the reserved name is the soul, every other name crew" do
    assert AquaAgent.type_of(soul()) == AquaAgent.soul_type()
    assert AquaAgent.type_of(member()) == AquaAgent.crew_type()
    # Persisted picks and the console's filters read these values back, so
    # the spelling is pinned with the fact that it is read from here.
    assert AquaAgent.soul_type() == "soul"
    assert AquaAgent.crew_type() == "crew"
  end

  test "the name comes from the filename, never the frontmatter" do
    {:ok, parsed} = AquaAgent.parse("other", AquaAgent.serialize(member()))
    assert parsed.name == "other"
  end

  test "a portable minimal file parses — frontmatter defaults fill in" do
    minimal = "---\ndescription: does things\n---\n\nYou are minimal.\n"

    assert {:ok, parsed} = AquaAgent.parse("min", minimal)
    assert parsed.title == "min"
    assert parsed.avoid == ""
    assert parsed.options == %{}
    assert parsed.tool_policy == %{}
    assert parsed.prompt == "You are minimal."
  end

  test "a file without frontmatter is a typed refusal" do
    assert {:error, :frontmatter_missing} = AquaAgent.parse("x", "just a prompt")
    assert {:error, :frontmatter_unterminated} = AquaAgent.parse("x", "---\ntitle: X\n")
  end

  defp with_policy(yaml), do: "---\ntool_policy:\n#{yaml}---\n\nprompt\n"

  test "a crew file holds no policy: one that names any refuses the file, the soul's parses" do
    assert {:error, :crew_has_no_tool_policy} =
             AquaAgent.parse("scribe", with_policy("  files.read: auto\n"))

    assert {:ok, %{tool_policy: %{"files.read" => "auto"}}} =
             AquaAgent.parse("aqua", with_policy("  files.read: auto\n"))

    # Whatever the map holds, a crew member serializes without a policy.
    binary = AquaAgent.serialize(member(%{tool_policy: %{"files.read" => "auto"}}))
    refute binary =~ "tool_policy"
    assert {:ok, %{tool_policy: %{}}} = AquaAgent.parse("scribe", binary)
  end

  test "options are a flat map of strings, integers and booleans" do
    assert {:error, :options_invalid} =
             AquaAgent.parse("x", "---\noptions: high\n---\n\nprompt\n")

    assert {:error, :options_invalid} =
             AquaAgent.parse("x", "---\noptions:\n  effort:\n    level: high\n---\n\nprompt\n")

    assert {:ok, %{options: %{"effort" => "high", "budget" => 4}}} =
             AquaAgent.parse("x", "---\noptions:\n  effort: high\n  budget: 4\n---\n\nprompt\n")
  end

  test "a crew member runs under the soul's policy, the soul as it is" do
    policy = %{"files.read" => "auto", "crew.ask" => "auto"}

    assert %{tool_policy: ^policy} = AquaAgent.under_soul(member(), policy)
    assert AquaAgent.under_soul(soul(), %{}) == soul()
  end

  test "the policy grammar parses: ask/auto over tool.action, tool.* and native_search" do
    file = with_policy("  files.read: auto\n  web.*: ask\n  native_search: auto\n")

    assert {:ok, %{tool_policy: policy}} = AquaAgent.parse("aqua", file)
    assert policy == %{"files.read" => "auto", "web.*" => "ask", "native_search" => "auto"}

    # An absent policy is the empty allowlist; an empty one parses too.
    assert {:ok, %{tool_policy: %{}}} = AquaAgent.parse("aqua", "---\ntitle: X\n---\n\nprompt\n")
    assert :ok = AquaAgent.validate_tool_policy(%{})
  end

  test "a policy outside the grammar refuses the file with its typed reason" do
    # The guest treats only "auto" as automatic and anything else as ask,
    # so a value outside the vocabulary must never reach it.
    assert {:error, {:tool_policy_invalid_value, "files.read", "never"}} =
             AquaAgent.parse("aqua", with_policy("  files.read: never\n"))

    assert {:error, {:tool_policy_invalid_value, "files.read", true}} =
             AquaAgent.parse("aqua", with_policy("  files.read: true\n"))

    assert {:error, {:tool_policy_invalid_key, "files"}} =
             AquaAgent.parse("aqua", with_policy("  files: auto\n"))

    assert {:error, {:tool_policy_invalid_key, "a.b.c"}} =
             AquaAgent.parse("aqua", with_policy("  a.b.c: auto\n"))

    assert {:error, :tool_policy_not_a_map} =
             AquaAgent.parse("aqua", "---\ntool_policy: auto\n---\n\nprompt\n")

    # The same rule at the tool door.
    assert {:error, {:tool_policy_invalid_value, "a.b", "allow"}} =
             AquaAgent.validate_tool_policy(%{"a.b" => "allow"})

    assert {:error, {:tool_policy_invalid_key, 1}} =
             AquaAgent.validate_tool_policy(%{1 => "auto"})

    assert {:error, :tool_policy_not_a_map} = AquaAgent.validate_tool_policy("auto")
  end

  # The security-relevant subset: what an agent is and may do, never what
  # it says. Two agents that differ only in prose share a capability.
  test "to_manifest/1 projects the capability and nothing of the prose" do
    scout = %{
      name: "scout",
      title: "Scout",
      description: "Looks around",
      avoid: "Writing",
      disabled: false,
      catalyst_ref: "catalyst:moonmoon69.claude",
      model: "claude-sonnet-5-5",
      options: %{},
      tool_policy: %{"files.read" => "auto"},
      prompt: "You look around."
    }

    manifest = AquaAgent.to_manifest(scout)
    assert manifest["name"] == "scout"
    assert manifest["type"] == AquaAgent.crew_type()
    assert manifest["catalyst_ref"] == "catalyst:moonmoon69.claude"
    assert manifest["tool_policy"] == %{"files.read" => "auto"}
    refute Map.has_key?(manifest, "options")
    refute Map.has_key?(manifest, "prompt")
    refute Map.has_key?(manifest, "title")
    refute Map.has_key?(manifest, "avoid")

    {:ok, digest} = AquaAgent.capability_digest(scout)

    {:ok, same} =
      AquaAgent.capability_digest(%{
        scout
        | prompt: "Something else.",
          title: "Renamed",
          avoid: "Anything"
      })

    assert digest == same

    {:ok, other} = AquaAgent.capability_digest(%{scout | tool_policy: %{"files.read" => "ask"}})
    refute digest == other

    # The brain's options are what it runs with: they move the capability.
    {:ok, tuned} = AquaAgent.capability_digest(%{scout | options: %{"effort" => "high"}})
    refute digest == tuned

    assert AquaAgent.to_manifest(%{scout | options: %{"effort" => "high"}})["options"] == %{
             "effort" => "high"
           }
  end

  # What an authored policy may say, on top of the grammar: the rule the
  # `aqua` tool door applies to every write.
  describe "validate_tool_policy/1" do
    test "a destructive or external action is never auto" do
      assert {:error, msg} =
               AquaAgent.validate_tool_policy(%{"files.delete" => "auto"})

      assert msg =~ "always asks"

      assert {:error, _} =
               AquaAgent.validate_tool_policy(%{"http.delete" => "auto"})

      assert :ok =
               AquaAgent.validate_tool_policy(%{"files.delete" => "ask"})

      assert :ok =
               AquaAgent.validate_tool_policy(%{"files.write" => "auto"})
    end

    test "an action declared to take no agent-wide standing allow is never auto" do
      # A pin, an endorsement, a scroll's writes and a launch are asked at
      # every call, and a kept note takes a standing allow for one thread
      # only, so an authored auto, which holds in every thread, would be a
      # standing answer they never take.
      for key <-
            ~w(notes.pin notes.endorse notes.keep aqua.skill_create aqua.skill_update execution.run) do
        assert {:error, msg} =
                 AquaAgent.validate_tool_policy(%{key => "auto"})

        assert msg == "#{key} always asks — it cannot be set to auto"
        assert :ok = AquaAgent.validate_tool_policy(%{key => "ask"})
      end

      assert {:error, msg} =
               AquaAgent.validate_tool_policy(%{"notes.*" => "auto"})

      assert msg =~ "notes.pin"

      assert :ok =
               AquaAgent.validate_tool_policy(%{"notes.read" => "auto"})
    end

    test "a glob at auto that covers a destructive action is refused with the actions named" do
      assert {:error, msg} =
               AquaAgent.validate_tool_policy(%{"files.*" => "auto"})

      assert msg =~ "files.delete"
      assert :ok = AquaAgent.validate_tool_policy(%{"files.*" => "ask"})
    end

    test "a glob of a tool no table holds, and the search gate, pass" do
      assert :ok =
               AquaAgent.validate_tool_policy(%{"builder.*" => "auto", "native_search" => "auto"})
    end

    test "a UI event is auto or absent" do
      assert {:error, msg} =
               AquaAgent.validate_tool_policy(%{"request_setup.open" => "ask"})

      assert msg =~ "runs on its own"

      assert :ok =
               AquaAgent.validate_tool_policy(%{
                 "request_setup.open" => "auto",
                 "files.read" => "ask"
               })
    end

    test "a catalogued tool's kind is its operation-table annotation" do
      assert {:error, msg} =
               AquaAgent.validate_tool_policy(%{"component.delete" => "auto"})

      assert msg =~ "always asks"

      assert {:error, msg} =
               AquaAgent.validate_tool_policy(%{"component.*" => "auto"})

      assert msg =~ "component.delete"

      # An upstream server's tool is external whatever the action; a tool
      # neither table holds has no kind and is left to the runtime ceiling.
      assert {:error, _} =
               AquaAgent.validate_tool_policy(%{"srv:search.run" => "auto"})

      assert :ok =
               AquaAgent.validate_tool_policy(%{"nosuch.thing" => "auto"})
    end

    test "the grammar is checked first, with its typed reason" do
      assert {:error, {:tool_policy_invalid_value, "files.read", "never"}} =
               AquaAgent.validate_tool_policy(%{"files.read" => "never"})

      assert {:error, :tool_policy_not_a_map} =
               AquaAgent.validate_tool_policy("auto")
    end
  end
end
