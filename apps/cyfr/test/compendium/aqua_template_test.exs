# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AquaTemplateTest do
  @moduledoc """
  The shipped AQUA tree through the seed overlay: no copies at provision,
  per-file shadowing (an edited agent shadows only itself, an unedited one
  tracks the operator's mount live), whole-skill copy-on-write, `reset/2`
  reverting edited copies while keeping member work (`all: true` for the
  exact shipped set), and `seed_check/0` failing loud on a v2 or empty
  mount.
  """

  use ExUnit.Case, async: false

  alias Compendium.AquaAgent
  alias Compendium.AquaPath
  alias Compendium.AquaTemplate

  setup do
    base = Path.join(System.tmp_dir!(), "aqua_template_#{System.unique_integer([:positive])}")
    seed = Path.join(base, "seed")
    template = Path.join(seed, "aqua")

    prev_base = Application.fetch_env!(:cyfr, :base_path)
    prev_seed = Application.fetch_env!(:cyfr, :seed_path)
    Application.put_env(:cyfr, :base_path, Path.join(base, "data"))
    Application.put_env(:cyfr, :seed_path, seed)

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, prev_base)
      Application.put_env(:cyfr, :seed_path, prev_seed)
      File.rm_rf!(base)
    end)

    write_seed!(template, "v1")

    {:ok, template: template, ctx: Sanctum.TestContext.local()}
  end

  defp write_seed!(template, marker) do
    agents = Path.join(template, "agents")
    File.mkdir_p!(agents)

    File.write!(Path.join(agents, "aqua.md"), """
    ---
    title: A.Q.U.A.
    role: orchestrator
    model: model-#{marker}
    ---

    orchestrator prompt #{marker}
    """)

    File.write!(Path.join(agents, "scribe.md"), """
    ---
    title: Scribe
    description: writes things
    parent: aqua
    ---

    scribe prompt #{marker}
    """)
  end

  defp write_skill!(template, name, marker) do
    dir = Path.join([template, "skills", name])
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "SKILL.md"), """
    ---
    name: #{name}
    description: does #{name} things
    ---

    skill instructions #{marker}
    """)

    File.write!(Path.join(dir, "reference.md"), "extra #{marker}")
  end

  test "the shipped tree reads through with zero copies", %{ctx: ctx} do
    assert :ok = AquaTemplate.seed_check()

    assert {:ok, %{default: %{name: "aqua"}, agents: agents}} = AquaAgent.roster(ctx)
    assert Enum.map(agents, & &1.name) == ["aqua", "scribe"]

    assert {:ok, %{prompt: "orchestrator prompt v1"}} = AquaAgent.get(ctx, "aqua")

    # Complete through the facade, empty on disk.
    assert {:ok, %{files: 0, bytes: 0}} = Arca.usage(ctx, ["aqua"])
  end

  test "an edited agent shadows only itself; its neighbor tracks a live seed change", %{
    ctx: ctx,
    template: template
  } do
    {:ok, scribe} = AquaAgent.get(ctx, "scribe")

    :ok =
      Arca.put(
        ctx,
        AquaPath.agent_file("scribe"),
        AquaAgent.serialize(%{scribe | prompt: "ours"})
      )

    # The operator's mount moves (a new release, a live edit): the unedited
    # agent follows it, the edited one keeps the members' work.
    write_seed!(template, "v2")

    assert {:ok, %{prompt: "orchestrator prompt v2"}} = AquaAgent.get(ctx, "aqua")
    assert {:ok, %{prompt: "ours"}} = AquaAgent.get(ctx, "scribe")

    # Deleting the edited copy reverts it to shipped.
    assert :ok = Arca.delete(ctx, AquaPath.agent_file("scribe"))
    assert {:ok, %{prompt: "scribe prompt v2"}} = AquaAgent.get(ctx, "scribe")
  end

  test "a shipped skill copy-on-writes whole, and refuses member deletes while unowned", %{
    ctx: ctx,
    template: template
  } do
    write_skill!(template, "pdf", "v1")

    assert {:ok, binary} = Arca.get(ctx, AquaPath.skill_manifest("pdf"))
    assert binary =~ "skill instructions v1"

    assert {:error, :bundled} = Arca.delete(ctx, AquaPath.skill_manifest("pdf"))

    # A write inside the skill materializes the whole unit, sentinel last.
    :ok = Arca.put(ctx, AquaPath.skill_dir("pdf") ++ ["notes.md"], "mine")
    assert Arca.Adapters.Local.exists?(ctx, AquaPath.skill_manifest("pdf"))
    assert {:ok, "extra v1"} = Arca.get(ctx, AquaPath.skill_dir("pdf") ++ ["reference.md"])
  end

  test "status/1 tells shipped, modified, and own apart", %{ctx: ctx, template: template} do
    write_skill!(template, "pdf", "v1")

    {:ok, scribe} = AquaAgent.get(ctx, "scribe")
    :ok = Arca.put(ctx, AquaPath.agent_file("scribe"), AquaAgent.serialize(scribe))

    :ok =
      Arca.put(ctx, AquaPath.agent_file("mine"), AquaAgent.serialize(%{scribe | name: "mine"}))

    assert {:ok,
            [
              %{path: "aqua/agents/aqua.md", state: :bundled},
              %{path: "aqua/agents/mine.md", state: :user},
              %{path: "aqua/agents/scribe.md", state: :bundled_modified},
              %{path: "aqua/skills/pdf", state: :bundled}
            ]} = AquaTemplate.status(ctx)
  end

  test "reset reverts edited copies and KEEPS member-created agents", %{ctx: ctx} do
    {:ok, scribe} = AquaAgent.get(ctx, "scribe")

    :ok =
      Arca.put(
        ctx,
        AquaPath.agent_file("scribe"),
        AquaAgent.serialize(%{scribe | prompt: "ours"})
      )

    :ok =
      Arca.put(ctx, AquaPath.agent_file("mine"), AquaAgent.serialize(%{scribe | name: "mine"}))

    assert {:ok, %{reverted: ["aqua/agents/scribe.md"], kept: ["aqua/agents/mine.md"]}} =
             AquaTemplate.reset(ctx)

    assert {:ok, %{prompt: "scribe prompt v1"}} = AquaAgent.get(ctx, "scribe")
    assert {:ok, _} = AquaAgent.get(ctx, "mine")
  end

  test "reset all: true produces exactly the shipped set — member-created agents go too", %{
    ctx: ctx
  } do
    {:ok, scribe} = AquaAgent.get(ctx, "scribe")

    :ok =
      Arca.put(
        ctx,
        AquaPath.agent_file("scribe"),
        AquaAgent.serialize(%{scribe | prompt: "ours"})
      )

    :ok =
      Arca.put(ctx, AquaPath.agent_file("mine"), AquaAgent.serialize(%{scribe | name: "mine"}))

    assert {:ok, %{reverted: reverted, kept: []}} = AquaTemplate.reset(ctx, all: true)
    assert Enum.sort(reverted) == ["aqua/agents/mine.md", "aqua/agents/scribe.md"]

    assert {:ok, %{prompt: "scribe prompt v1"}} = AquaAgent.get(ctx, "scribe")
    assert {:error, :not_found} = AquaAgent.get(ctx, "mine")
    assert {:ok, %{files: 0, bytes: 0}} = Arca.usage(ctx, ["aqua"])
  end

  test "reset refuses before deleting anything when the install ships no template", %{
    ctx: ctx,
    template: template
  } do
    :ok = Arca.put(ctx, AquaPath.agent_file("mine"), "---\ntitle: Mine\n---\n\nmine\n")

    # The install loses its template: reset must refuse and leave the
    # athanor's own work intact — deleting first would destroy the only
    # agents left in existence.
    File.rm_rf!(template)
    File.mkdir_p!(template)

    assert {:error, :template_missing} = AquaTemplate.reset(ctx)
    assert {:error, :template_missing} = AquaTemplate.reset(ctx, all: true)
    assert {:ok, _} = Arca.get(ctx, AquaPath.agent_file("mine"))
  end

  test "seed_check/0 fails loud on broken install media", %{template: template} do
    assert :ok = AquaTemplate.seed_check()

    # A v2-shaped mount (agent.json at the root) gets a pointed message.
    File.write!(Path.join(template, "agent.json"), "{}")
    assert {:error, :seed_is_v2_shaped} = AquaTemplate.seed_check()
    File.rm!(Path.join(template, "agent.json"))

    # A roster without an orchestrator refuses too.
    File.rm!(Path.join([template, "agents", "aqua.md"]))
    assert {:error, :no_orchestrator} = AquaTemplate.seed_check()
  end
end
