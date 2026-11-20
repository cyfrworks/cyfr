# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AquaAgentTest do
  @moduledoc """
  The agent file format: frontmatter round-trips byte-stably, a disabled
  crew member leaves the crew without leaving the tree, every member has
  a mode of its own, and a crew file holds no tools of its own: a member
  is offered the soul's. A crew file is its frontmatter alone: the soul
  has a prompt, and a crew file with one is refused with the sentence
  that says where its words go. A file still holding the retired `tool_policy`
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
        prompt: nil,
        member: nil,
        holder: nil
      },
      overrides
    )
  end

  # The soul names the crew member it runs on and no brain of its own.
  defp soul(overrides \\ %{}) do
    member(
      Map.merge(
        %{
          name: "aqua",
          avoid: "",
          catalyst_ref: nil,
          model: nil,
          options: %{},
          mode: "auto",
          tools: ["files.read", "github:search", "native_search", "web.fetch"],
          prompt: "You are Aqua.\n\n## Style\n\n- terse",
          member: "scribe"
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
    minimal = "---\ndescription: does things\n---\n"

    assert {:ok, parsed} = AquaAgent.parse("min", minimal)
    assert parsed.title == "min"
    assert parsed.avoid == ""
    assert parsed.options == %{}
    assert parsed.mode == "auto"
    assert parsed.tools == []
    assert parsed.prompt == nil
  end

  # Only the soul has a prompt: the job a member is handed says what to do,
  # and how a kind of job is done is a scroll. A crew file still holding
  # words below its frontmatter is refused, never run with them unseen.
  test "a crew file is its frontmatter alone: a body is refused with its sentence, the soul's is its prompt" do
    for body <- ["You are the scribe.", "\n\n# Scribe\n\nWrite.\n"] do
      assert {:error, :crew_has_no_prompt} =
               AquaAgent.parse("scribe", "---\ntitle: Scribe\n---\n" <> body)
    end

    # Blank lines after the fence are framing, not a prompt.
    assert {:ok, %{prompt: nil}} = AquaAgent.parse("scribe", "---\ntitle: Scribe\n---\n\n\n")

    assert {:ok, %{prompt: "You are Aqua."}} =
             AquaAgent.parse("aqua", "---\ntitle: Aqua\n---\n\nYou are Aqua.\n")

    # A crew member's file is written with no body, whatever its map holds.
    written = AquaAgent.serialize(member(%{prompt: "You are the scribe."}))
    assert written == AquaAgent.serialize(member())
    assert String.ends_with?(written, "\n  thinking: true\n---\n")

    assert AquaAgent.prompt_refused("scribe") ==
             "scribe can't take a job: aqua/crew/scribe.md still holds instructions below " <>
               "its header, and a crew member has none now. Keep what you want of them as a " <>
               "new scroll under Scrolls on Aqua's page, which Aqua names in the jobs it hands " <>
               "out, then in Files delete everything after the header's closing `---`. " <>
               "Nothing else in the file needs to change."
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
             AquaAgent.parse("scribe", "---\nprogram: claude\ninstall: \"\"\n---\n")

    assert {:error, :catalyst_and_program} =
             AquaAgent.parse(
               "scribe",
               "---\ncatalyst_ref: catalyst:local.claude\nprogram: claude\n---\n"
             )

    # A blank one names none, as a blank catalyst does.
    assert {:ok, %{catalyst_ref: "catalyst:local.claude", program: nil}} =
             AquaAgent.parse(
               "scribe",
               "---\ncatalyst_ref: catalyst:local.claude\nprogram: \"\"\n---\n"
             )

    assert {:ok, %{catalyst_ref: nil, program: nil}} =
             AquaAgent.parse("scribe", "---\ntitle: X\n---\n")
  end

  test "a file without frontmatter is a typed refusal" do
    assert {:error, :frontmatter_missing} = AquaAgent.parse("x", "just a prompt")
    assert {:error, :frontmatter_unterminated} = AquaAgent.parse("x", "---\ntitle: X\n")
  end

  test "serialize writes the soul's tools as a list, one per line, in one form" do
    binary = AquaAgent.serialize(soul(%{tools: ["web.fetch", "files.read", "files.read"]}))

    # The soul's file names its member and no brain, model, options or mode.
    assert binary =~ "\nmember: scribe\ntools:\n  - files.read\n  - web.fetch\n---\n"
    refute binary =~ "mode:"
    refute binary =~ "options:"

    assert {:ok, %{tools: ["files.read", "web.fetch"]}} = AquaAgent.parse("aqua", binary)

    # An outside server's tool takes the scalar spelling YAML reads back.
    binary = AquaAgent.serialize(soul(%{tools: ["github:search"]}))
    assert binary =~ "tools:\n  - \"github:search\"\n"
    assert {:ok, %{tools: ["github:search"]}} = AquaAgent.parse("aqua", binary)
  end

  test "every crew member has a mode of its own: read-only or auto, a file without one auto" do
    for mode <- ["read-only", "auto"] do
      assert {:ok, %{mode: ^mode}} =
               AquaAgent.parse("scribe", "---\nmode: #{mode}\n---\n")
    end

    assert {:error, {:mode_invalid, "manual"}} =
             AquaAgent.parse("scribe", "---\nmode: manual\n---\n")

    # Aqua runs in its member's mode, and a soul file that names one is
    # refused, as one that names any brain of its own is.
    assert {:ok, %{mode: "auto"}} = AquaAgent.parse("aqua", "---\ntitle: Aqua\n---\n\nprompt\n")

    assert {:error, :seat_has_brain} =
             AquaAgent.parse("aqua", "---\nmode: true\n---\n\nprompt\n")

    assert AquaAgent.modes() == ["read-only", "auto"]
  end

  # The soul is a seat: it runs on the brain of the crew member it names,
  # and a file that still names a brain of its own is refused whole, with
  # the sentence that says what to delete (no old key is read).
  test "the soul names the member it runs on and no brain: a brain, model, options, install or mode refuses it" do
    for line <- [
          "catalyst_ref: catalyst:local.claude",
          "program: claude",
          "install: cyfr-claude-code claude",
          "model: claude-sonnet-5-5",
          "options:\n  effort: high",
          "mode: auto"
        ] do
      assert {:error, :seat_has_brain} =
               AquaAgent.parse("aqua", "---\ntitle: Aqua\n#{line}\n---\n\nprompt\n"),
             line
    end

    # A crew member's file names its brain, as before.
    assert {:ok, %{catalyst_ref: "catalyst:local.claude", mode: "auto"}} =
             AquaAgent.parse(
               "scribe",
               "---\ncatalyst_ref: catalyst:local.claude\nmode: auto\n---\n"
             )

    assert {:ok, %{member: "scribe", catalyst_ref: nil, model: nil, holder: nil}} =
             AquaAgent.parse("aqua", "---\ntitle: Aqua\nmember: scribe\n---\n\nprompt\n")

    assert {:ok, %{member: nil}} =
             AquaAgent.parse("aqua", "---\ntitle: Aqua\nmember: \"\"\n---\n\nprompt\n")

    for invalid <- ["aqua", "Not A Name", 7] do
      assert {:error, {:member_invalid, ^invalid}} =
               AquaAgent.parse("aqua", "---\nmember: #{Jason.encode!(invalid)}\n---\n\nprompt\n")
    end

    assert Prima.AgentRef.seat_has_brain() =~ "aqua/aqua.md"
    assert Prima.AgentRef.seat_has_brain() =~ "choose the crew member Aqua runs on"
  end

  # Seated, the soul takes its member's brain, model, options and mode and
  # keeps its own prompt, title and tools; a member that does not stand
  # leaves it with no brain, and says why.
  test "the soul seated on its member takes the member's brain and keeps its own prompt and tools" do
    scribe = member()

    assert AquaAgent.seated(soul(), {:ok, scribe}) == %{
             soul()
             | catalyst_ref: scribe.catalyst_ref,
               program: nil,
               model: scribe.model,
               options: scribe.options,
               mode: "read-only",
               holder: %{name: "scribe", title: "Scribe", state: :held}
           }

    unheld = %{soul() | mode: "auto"}

    assert AquaAgent.seated(soul(), {:ok, %{scribe | disabled: true}}) ==
             %{unheld | holder: %{name: "scribe", title: "Scribe", state: :disabled}}

    assert AquaAgent.seated(soul(%{member: nil}), :none) ==
             %{unheld | member: nil, holder: %{name: nil, title: nil, state: :none}}

    assert AquaAgent.seated(soul(), :missing) ==
             %{unheld | holder: %{name: "scribe", title: nil, state: :missing}}

    assert AquaAgent.seated(soul(), {:refused, :crew_has_no_prompt}) ==
             %{unheld | holder: %{name: "scribe", title: nil, state: :refused}}
  end

  # The soul's capability is its member's brain, options and mode and its
  # own tools: the member's prose, the soul's prompt and title, and whose
  # name it runs on move none of it.
  test "the soul's capability moves with its member's brain, options and mode, never with prose" do
    scribe = member()
    {:ok, digest} = AquaAgent.capability_digest(AquaAgent.seated(soul(), {:ok, scribe}))

    for moved <- [
          %{scribe | model: "claude-opus-5-5"},
          %{scribe | catalyst_ref: "catalyst:local.gemini"},
          %{scribe | options: %{}},
          %{scribe | mode: "auto"}
        ] do
      {:ok, other} = AquaAgent.capability_digest(AquaAgent.seated(soul(), {:ok, moved}))
      refute other == digest
    end

    for same <- [
          AquaAgent.seated(soul(), {:ok, %{scribe | title: "Renamed", description: "Else"}}),
          AquaAgent.seated(soul(%{prompt: "Another prompt.", title: "Mine"}), {:ok, scribe})
        ] do
      assert {:ok, ^digest} = AquaAgent.capability_digest(same)
    end

    refute Map.has_key?(AquaAgent.to_manifest(soul()), "member")
  end

  test "the soul's tools are explicit: an absent list offers nothing, a crew file names none" do
    assert {:ok, %{tools: []}} = AquaAgent.parse("aqua", "---\ntitle: Aqua\n---\n\nprompt\n")

    assert {:ok, %{tools: ["files.read", "native_search"]}} =
             AquaAgent.parse(
               "aqua",
               "---\ntools:\n  - native_search\n  - files.read\n---\n\nprompt\n"
             )

    assert {:error, :crew_has_no_tools} =
             AquaAgent.parse("scribe", "---\ntools:\n  - files.read\n---\n")

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
               AquaAgent.parse(name, "---\ntool_policy:\n  files.read: auto\n---\n")
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
             AquaAgent.parse("x", "---\noptions: high\n---\n")

    assert {:error, :options_invalid} =
             AquaAgent.parse("x", "---\noptions:\n  effort:\n    level: high\n---\n")

    assert {:ok, %{options: %{"effort" => "high", "budget" => 4}}} =
             AquaAgent.parse("x", "---\noptions:\n  effort: high\n  budget: 4\n---\n")
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
