# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AquaTemplateTest do
  @moduledoc """
  The shipped AQUA tree as the athanor's own: a fill copies it in, a
  release that changes the seed changes nothing until a reset asks for it,
  an edited copy is restored by `reset/2` while member work is kept
  (`all: true` for the exact shipped set), a shipped skill is copied whole
  and refuses deletion, and `seed_check/0` fails loud on a v2 or empty
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
    roles = Path.join(template, "roles")
    File.mkdir_p!(roles)

    File.write!(Path.join(template, "aqua.md"), """
    ---
    title: A.Q.U.A.
    model: model-#{marker}
    ---

    soul prompt #{marker}
    """)

    File.write!(Path.join(roles, "scribe.md"), """
    ---
    title: Scribe
    description: writes things
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

  # What a fill does for the tree: every shipped unit copied in.
  defp fill!(ctx), do: {:ok, _} = Arca.Overlay.materialize_shipped(ctx, "aqua")

  test "a fill copies the shipped tree in; until then the athanor has no soul", %{ctx: ctx} do
    assert :ok = AquaTemplate.seed_check()
    assert {:error, :not_found} = AquaAgent.get(ctx, "aqua")

    fill!(ctx)

    assert {:ok, agents, []} = AquaAgent.list(ctx)
    assert Enum.map(agents, & &1.name) == ["aqua", "scribe"]
    assert {:ok, %{prompt: "soul prompt v1"}} = AquaAgent.get(ctx, "aqua")

    # Real bytes of the athanor's own.
    assert {:ok, %{files: 2}} = Arca.usage(ctx, ["aqua"])
  end

  test "a release's change to the seed is not pushed; a reset brings it in", %{
    ctx: ctx,
    template: template
  } do
    fill!(ctx)
    {:ok, scribe} = AquaAgent.get(ctx, "scribe")

    :ok =
      Arca.put(
        ctx,
        AquaPath.agent_file("scribe"),
        AquaAgent.serialize(%{scribe | prompt: "ours"})
      )

    # The operator's mount moves (a new release, a live edit): nothing in
    # the athanor changes, edited or not.
    write_seed!(template, "v2")

    assert {:ok, %{prompt: "soul prompt v1"}} = AquaAgent.get(ctx, "aqua")
    assert {:ok, %{prompt: "ours"}} = AquaAgent.get(ctx, "scribe")

    # A reset restores the edited copy to what NOW ships and leaves the
    # unedited copy as it is — the seed is the default, not a live feed.
    assert {:ok, %{reverted: ["aqua/roles/scribe.md"], kept: []}} = AquaTemplate.reset(ctx)
    assert {:ok, %{prompt: "scribe prompt v2"}} = AquaAgent.get(ctx, "scribe")
    assert {:ok, %{prompt: "soul prompt v1"}} = AquaAgent.get(ctx, "aqua")
  end

  test "a shipped skill is copied whole and refuses deletion; a write inside it is an edit", %{
    ctx: ctx,
    template: template
  } do
    write_skill!(template, "pdf", "v1")
    fill!(ctx)

    assert {:ok, binary} = Arca.get(ctx, AquaPath.skill_manifest("pdf"))
    assert binary =~ "skill instructions v1"
    assert {:ok, "extra v1"} = Arca.get(ctx, AquaPath.skill_dir("pdf") ++ ["reference.md"])

    assert {:error, :bundled} = Arca.delete_tree(ctx, AquaPath.skill_dir("pdf"))

    :ok = Arca.put(ctx, AquaPath.skill_dir("pdf") ++ ["notes.md"], "mine")
    assert Arca.Overlay.unit_status(ctx, AquaPath.skill_dir("pdf")) == {:ok, :modified}
  end

  test "status/1 tells shipped, modified, and own apart", %{ctx: ctx, template: template} do
    write_skill!(template, "pdf", "v1")
    fill!(ctx)

    {:ok, scribe} = AquaAgent.get(ctx, "scribe")
    :ok = Arca.put(ctx, AquaPath.agent_file("scribe"), AquaAgent.serialize(scribe))

    :ok =
      Arca.put(ctx, AquaPath.agent_file("mine"), AquaAgent.serialize(%{scribe | name: "mine"}))

    # A role the seed ships later is not the athanor's until pulled.
    File.write!(Path.join([template, "roles", "later.md"]), "---\ntitle: Later\n---\n\nlater\n")

    assert {:ok,
            [
              %{path: "aqua/aqua.md", state: :bundled},
              %{path: "aqua/roles/mine.md", state: :user},
              %{path: "aqua/roles/scribe.md", state: :bundled_modified},
              %{path: "aqua/skills/pdf", state: :bundled}
            ]} = AquaTemplate.status(ctx)
  end

  test "reset restores edited copies, pulls what ships, and KEEPS member-created agents", %{
    ctx: ctx,
    template: template
  } do
    fill!(ctx)
    {:ok, scribe} = AquaAgent.get(ctx, "scribe")

    :ok =
      Arca.put(
        ctx,
        AquaPath.agent_file("scribe"),
        AquaAgent.serialize(%{scribe | prompt: "ours"})
      )

    :ok =
      Arca.put(ctx, AquaPath.agent_file("mine"), AquaAgent.serialize(%{scribe | name: "mine"}))

    File.write!(Path.join([template, "roles", "later.md"]), "---\ntitle: Later\n---\n\nlater\n")

    assert {:ok,
            %{
              reverted: ["aqua/roles/later.md", "aqua/roles/scribe.md"],
              kept: ["aqua/roles/mine.md"]
            }} = AquaTemplate.reset(ctx)

    assert {:ok, %{prompt: "scribe prompt v1"}} = AquaAgent.get(ctx, "scribe")
    assert {:ok, %{prompt: "later"}} = AquaAgent.get(ctx, "later")
    assert {:ok, _} = AquaAgent.get(ctx, "mine")
  end

  test "reset all: true produces exactly the shipped set — member-created agents go too", %{
    ctx: ctx
  } do
    fill!(ctx)
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
    assert Enum.sort(reverted) == ["aqua/roles/mine.md", "aqua/roles/scribe.md"]

    assert {:ok, %{prompt: "scribe prompt v1"}} = AquaAgent.get(ctx, "scribe")
    assert {:error, :not_found} = AquaAgent.get(ctx, "mine")
    assert {:ok, %{files: 2}} = Arca.usage(ctx, ["aqua"])
  end

  test "reset refuses before changing anything when the install ships no template", %{
    ctx: ctx,
    template: template
  } do
    fill!(ctx)
    :ok = Arca.put(ctx, AquaPath.agent_file("mine"), "---\ntitle: Mine\n---\n\nmine\n")

    # The install loses its template: reset must refuse and leave the
    # athanor's own work intact — deleting first would destroy the only
    # agents left in existence.
    File.rm_rf!(template)
    File.mkdir_p!(template)

    assert {:error, :template_missing} = AquaTemplate.reset(ctx)
    assert {:error, :template_missing} = AquaTemplate.reset(ctx, all: true)
    assert {:ok, _} = Arca.get(ctx, AquaPath.agent_file("mine"))
    assert {:ok, _} = Arca.get(ctx, AquaPath.agent_file("scribe"))
  end

  test "seed_check/0 fails loud on broken install media", %{template: template} do
    assert :ok = AquaTemplate.seed_check()

    # A v2-shaped mount (agent.json at the root) gets a pointed message.
    File.write!(Path.join(template, "agent.json"), "{}")
    assert {:error, :seed_is_v2_shaped} = AquaTemplate.seed_check()
    File.rm!(Path.join(template, "agent.json"))

    # A tree without a soul is no template at all.
    File.rm!(Path.join([template, "aqua.md"]))
    assert {:error, :template_missing} = AquaTemplate.seed_check()

    # The shape before the soul had a file of its own — agents under
    # `agents/`, nothing beside them — gets its own pointed message rather
    # than the generic "no soul", so the operator learns which tree they
    # mounted.
    legacy = Path.join(template, AquaPath.legacy_agents_dirname())
    File.mkdir_p!(legacy)
    File.write!(Path.join(legacy, "aqua.md"), "---\ntitle: Old\n---\n\nold soul\n")
    assert {:error, :seed_is_agents_shaped} = AquaTemplate.seed_check()

    # A current tree that still carries a stale `agents/` beside its soul
    # is the current shape with a leftover — it reads, and the leftover is
    # not among what the seed ships.
    write_seed!(template, "v3")
    assert :ok = AquaTemplate.seed_check()
    refute Enum.any?(AquaTemplate.files(), &(hd(&1) == AquaPath.legacy_agents_dirname()))
    assert ["aqua.md"] in AquaTemplate.files()
  end
end
