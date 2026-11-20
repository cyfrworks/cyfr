# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AquaAgentTest do
  @moduledoc """
  The agent file format: frontmatter round-trips byte-stably, a disabled
  crew member leaves the crew without leaving the tree, every member has
  a mode of its own, and a crew file holds no tools of its own: a member
  is offered the soul's. A file still holding the retired `tool_policy`
  is refused whole. Which file is the soul is the tree's to say, never
  the frontmatter's.
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
        program: nil,
        install: nil,
        model: "claude-sonnet-5-5",
        options: %{"effort" => "high", "budget" => 8, "thinking" => true, "label" => "true"},
        mode: "read-only",
        tools: [],
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
          mode: "auto",
          tools: ["files.read", "github:search", "native_search", "web.fetch"]
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
    assert parsed.mode == "auto"
    assert parsed.tools == []
    assert parsed.prompt == "You are minimal."
  end

  # A brain is named once: a catalyst or a program row by its name, whose
  # model is one its harness lists, with the command its install form is
  # prefilled with beside it.
  test "a brain named as a program round-trips with its install, and a file naming a catalyst too refuses" do
    coder =
      member(%{
        catalyst_ref: nil,
        program: "claude",
        install: "cyfr-claude-code npx -y @anthropic-ai/claude-code@2.1.323",
        model: "opus"
      })

    binary = AquaAgent.serialize(coder)
    assert binary =~ "\nprogram: claude\n"
    assert binary =~ ~s(\ninstall: "cyfr-claude-code npx -y @anthropic-ai/claude-code@2.1.323"\n)
    refute binary =~ "catalyst_ref"
    assert {:ok, ^coder} = AquaAgent.parse("scribe", binary)
    assert AquaAgent.serialize(coder) == binary

    # Without an install the line is absent, and a blank one is none.
    plain = %{coder | install: nil}
    refute AquaAgent.serialize(plain) =~ "install"
    assert {:ok, ^plain} = AquaAgent.parse("scribe", AquaAgent.serialize(plain))

    assert {:ok, %{program: "claude", install: nil}} =
             AquaAgent.parse("scribe", "---\nprogram: claude\ninstall: \"\"\n---\n\nprompt\n")

    assert {:error, :catalyst_and_program} =
             AquaAgent.parse(
               "scribe",
               "---\ncatalyst_ref: catalyst:local.claude\nprogram: claude\n---\n\nprompt\n"
             )

    # A blank one names none, as a blank catalyst does.
    assert {:ok, %{catalyst_ref: "catalyst:local.claude", program: nil}} =
             AquaAgent.parse(
               "scribe",
               "---\ncatalyst_ref: catalyst:local.claude\nprogram: \"\"\n---\n\nprompt\n"
             )

    assert {:ok, %{catalyst_ref: nil, program: nil}} =
             AquaAgent.parse("scribe", "---\ntitle: X\n---\n\nprompt\n")
  end

  test "a file without frontmatter is a typed refusal" do
    assert {:error, :frontmatter_missing} = AquaAgent.parse("x", "just a prompt")
    assert {:error, :frontmatter_unterminated} = AquaAgent.parse("x", "---\ntitle: X\n")
  end

  test "serialize writes the soul's tools as a list, one per line, in one form" do
    binary = AquaAgent.serialize(soul(%{tools: ["web.fetch", "files.read", "files.read"]}))

    assert binary =~
             "\nmode: auto\noptions:\n" <>
               "  budget: 8\n  effort: \"high\"\n  label: \"true\"\n  thinking: true\n" <>
               "tools:\n  - files.read\n  - web.fetch\n---\n"

    assert {:ok, %{tools: ["files.read", "web.fetch"]}} = AquaAgent.parse("aqua", binary)

    # An outside server's tool takes the scalar spelling YAML reads back.
    binary = AquaAgent.serialize(soul(%{tools: ["github:search"]}))
    assert binary =~ "tools:\n  - \"github:search\"\n"
    assert {:ok, %{tools: ["github:search"]}} = AquaAgent.parse("aqua", binary)
  end

  test "every member has a mode of its own: read-only or auto, a file without one auto" do
    for mode <- ["read-only", "auto"], name <- ["aqua", "scribe"] do
      assert {:ok, %{mode: ^mode}} =
               AquaAgent.parse(name, "---\nmode: #{mode}\n---\n\nprompt\n")
    end

    assert {:error, {:mode_invalid, "manual"}} =
             AquaAgent.parse("scribe", "---\nmode: manual\n---\n\nprompt\n")

    assert {:error, {:mode_invalid, true}} =
             AquaAgent.parse("aqua", "---\nmode: true\n---\n\nprompt\n")

    assert AquaAgent.modes() == ["read-only", "auto"]
  end

  test "the soul's tools are explicit: an absent list offers nothing, a crew file names none" do
    assert {:ok, %{tools: []}} = AquaAgent.parse("aqua", "---\ntitle: Aqua\n---\n\nprompt\n")

    assert {:ok, %{tools: ["files.read", "native_search"]}} =
             AquaAgent.parse(
               "aqua",
               "---\ntools:\n  - native_search\n  - files.read\n---\n\nprompt\n"
             )

    assert {:error, :crew_has_no_tools} =
             AquaAgent.parse("scribe", "---\ntools:\n  - files.read\n---\n\nprompt\n")

    # A crew member's file carries no tools, whatever its map holds.
    binary = AquaAgent.serialize(member(%{tools: ["files.read"]}))
    refute binary =~ "tools"
    assert {:ok, %{tools: []}} = AquaAgent.parse("scribe", binary)
  end

  test "a tools list outside the grammar refuses the file with its typed reason" do
    for {yaml, reason} <- [
          {"tools: files.read", :tools_not_a_list},
          {"tools:\n  files.read: auto", :tools_not_a_list},
          {"tools:\n  - files", {:tools_invalid_entry, "files"}},
          {"tools:\n  - a.b.c", {:tools_invalid_entry, "a.b.c"}},
          {"tools:\n  - 1", {:tools_invalid_entry, 1}},
          {"tools:\n  - \"srv:a:b\"", {:tools_invalid_entry, "srv:a:b"}}
        ] do
      assert {:error, ^reason} = AquaAgent.parse("aqua", "---\n#{yaml}\n---\n\nprompt\n")
    end

    assert :ok =
             AquaAgent.check_tools(["files.read", "files.write", "native_search", "srv:search"])

    assert {:error, :tools_not_a_list} = AquaAgent.check_tools(%{"files.read" => "auto"})
  end

  test "a file still holding tool_policy is refused whole, soul or crew, with one sentence" do
    for name <- ["aqua", "scribe"] do
      assert {:error, :tool_policy_retired} =
               AquaAgent.parse(name, "---\ntool_policy:\n  files.read: auto\n---\n\nprompt\n")
    end

    assert {:error, :tool_policy_retired} =
             AquaAgent.parse("aqua", "---\ntool_policy: {}\ntools: []\n---\n\nprompt\n")

    assert Prima.AgentRef.tool_policy_retired() ==
             "Aqua's file still lists its tools under `tool_policy:`, which CYFR no longer " <>
               "reads, so Aqua can't answer. In Files, open aqua/aqua.md and replace that " <>
               "header with `tools:`, writing each tool on its own line as `- name`, without " <>
               "its `auto` or `ask`. Nothing else in the file needs to change."
  end

  test "options are a flat map of strings, integers and booleans" do
    assert {:error, :options_invalid} =
             AquaAgent.parse("x", "---\noptions: high\n---\n\nprompt\n")

    assert {:error, :options_invalid} =
             AquaAgent.parse("x", "---\noptions:\n  effort:\n    level: high\n---\n\nprompt\n")

    assert {:ok, %{options: %{"effort" => "high", "budget" => 4}}} =
             AquaAgent.parse("x", "---\noptions:\n  effort: high\n  budget: 4\n---\n\nprompt\n")
  end

  test "a crew member is offered the soul's tools and keeps its own mode, the soul as it is" do
    tools = ["crew.ask", "files.read"]

    assert %{tools: ^tools, mode: "read-only"} = AquaAgent.under_soul(member(), tools)
    assert AquaAgent.under_soul(soul(), []) == soul()
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
      mode: "auto",
      tools: ["files.read"],
      prompt: "You look around."
    }

    manifest = AquaAgent.to_manifest(scout)
    assert manifest["name"] == "scout"
    assert manifest["type"] == AquaAgent.crew_type()
    assert manifest["catalyst_ref"] == "catalyst:moonmoon69.claude"
    assert manifest["tools"] == ["files.read"]
    assert manifest["mode"] == "auto"
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

    {:ok, other} = AquaAgent.capability_digest(%{scout | tools: ["files.read", "files.write"]})
    refute digest == other

    # The mode is what the member runs of its tools: it moves the capability.
    {:ok, read_only} = AquaAgent.capability_digest(%{scout | mode: "read-only"})
    refute digest == read_only

    # The brain's options are what it runs with: they move the capability.
    {:ok, tuned} = AquaAgent.capability_digest(%{scout | options: %{"effort" => "high"}})
    refute digest == tuned

    assert AquaAgent.to_manifest(%{scout | options: %{"effort" => "high"}})["options"] == %{
             "effort" => "high"
           }

    # A brain that is a program is named by the name its file declares:
    # another name is another capability, and neither is the catalyst's.
    # Its install is a form's suggestion, which moves none.
    coder =
      Map.merge(scout, %{catalyst_ref: nil, program: "claude", install: "cyfr-claude-code claude"})

    manifest = AquaAgent.to_manifest(coder)
    assert manifest["program"] == "claude"
    refute Map.has_key?(manifest, "catalyst_ref")
    refute Map.has_key?(manifest, "install")
    refute Map.has_key?(AquaAgent.to_manifest(scout), "program")

    {:ok, programmed} = AquaAgent.capability_digest(coder)
    {:ok, moved} = AquaAgent.capability_digest(%{coder | program: "claude-work"})
    {:ok, suggested} = AquaAgent.capability_digest(%{coder | install: "cyfr-claude-code other"})
    refute programmed == digest
    refute programmed == moved
    assert programmed == suggested
  end

  test "a null entry in the tools list is refused as grammar" do
    assert {:error, {:tools_invalid_entry, nil}} =
             Compendium.AquaAgent.parse("aqua", "---\ntools:\n  - null\n---\nHello\n")

    assert {:error, {:tools_invalid_entry, nil}} =
             Compendium.AquaAgent.check_tools(["files.read", nil])
  end

  # One action an entry: the list a person reads is the set a turn is
  # offered, so a tool's actions are listed by name, never as a wildcard.
  test "a wildcard in the tools list is refused as grammar, by the parser and the door's check" do
    for entry <- ["storage.*", "*", "github:*", "*.read"] do
      assert {:error, {:tools_invalid_entry, ^entry}} =
               Compendium.AquaAgent.parse("aqua", "---\ntools:\n  - \"#{entry}\"\n---\nHi\n"),
             entry

      assert {:error, {:tools_invalid_entry, ^entry}} =
               Compendium.AquaAgent.check_tools(["files.read", entry])
    end
  end
end
