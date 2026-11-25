# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.PacksSettleTest do
  @moduledoc """
  The one data migration and `cyfr`'s refresh (`Compendium.Packs.settle/2`,
  which the fill and the boot's seed sync run), on whichever database
  adapter the suite runs on: the scrolls of the layout before packs,
  committed as that layout's grammar committed them, move into `mine`
  with their files when the athanor made or edited them, and an unedited
  shipped one is dropped; `aqua/skills/` is gone; `cyfr` is copied in
  and made the seed's again with its switch kept.
  """

  use ExUnit.Case, async: false

  alias Compendium.AquaPath
  alias Compendium.Packs

  # The grammar of the layout before packs: a scroll a directory unit of
  # `aqua/skills/<name>/` sentinel'd by `SKILL.md`, the rest as now.
  defmodule BeforePacks do
    @moduledoc false
    @behaviour Arca.Storage.UnitLocator

    @impl true
    def locate(["aqua", "skills", name | _rest]), do: {:dir, ["aqua", "skills", name], "SKILL.md"}
    def locate(path), do: AquaPath.locate(path)

    @impl true
    def creates_by_write?(_unit), do: true
  end

  @locators %{"aqua" => AquaPath, "components" => Compendium.ComponentPath}

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    base = Path.join(System.tmp_dir!(), "packs_settle_#{System.unique_integer([:positive])}")
    seed = Path.join(base, "seed")
    Prima.Test.Env.put_app_env(:arca, :base_path, Path.join(base, "data"))
    Prima.Test.Env.put_app_env(:arca, :seed_path, seed)

    on_exit(fn ->
      Arca.Storage.UnitLocator.install!(@locators)
      File.rm_rf!(base)
    end)

    cyfr = Path.join(seed, "aqua/scrolls/cyfr")
    File.mkdir_p!(Path.join(cyfr, "skills/research"))

    File.write!(
      Path.join(cyfr, ".cyfr-pack.json"),
      Packs.encode_record(%{Packs.own_record() | origin: "cyfr"})
    )

    File.write!(Path.join(cyfr, "skills/research/SKILL.md"), "---\nname: research\n---\n\nv1\n")

    ctx = Sanctum.TestContext.local()
    {:ok, ctx: ctx, actor: Sanctum.Context.actor(ctx), cyfr: cyfr}
  end

  # A scroll as the layout before packs committed it.
  defp before_packs!(actor, name, files) do
    Arca.Storage.UnitLocator.install!(%{@locators | "aqua" => BeforePacks})

    try do
      {:ok, _} =
        Arca.Overlay.commit_unit(actor, ["aqua", "skills", name], {:files, files}, cap: :exempt)
    after
      Arca.Storage.UnitLocator.install!(@locators)
    end
  end

  # A shipped scroll's bytes as an earlier release's seed shipped them:
  # `planner`'s, which this release did not change.
  defp shipped_planner,
    do:
      File.read!(
        Path.expand("../../../../seed/aqua/scrolls/cyfr/skills/planner/SKILL.md", __DIR__)
      )

  test "the program view withholds a pack retained past the pack size bound", %{
    actor: actor,
    ctx: ctx
  } do
    chunk = :binary.copy("q", 16 * 1024 * 1024)

    before_packs!(actor, "large", [
      {["SKILL.md"], "---\nname: large\n---\nbody"},
      {["a"], chunk},
      {["b"], chunk}
    ])

    assert :ok = Packs.settle(ctx)
    {:ok, index} = Packs.index(ctx)
    assert %{carried: false} = Enum.find(index, &(&1.name == "mine:large"))
    {:ok, digest} = Packs.pack_digest(ctx, ctx.athanor_id)
    {:ok, view} = Packs.pack_view(ctx, ctx.athanor_id, digest)
    mine = Enum.find(view.packs, &(&1.name == "mine"))
    assert Enum.map(mine.files, & &1.path) == []
    assert is_binary(mine.withheld)

    # The same rule answers a file by its path: a withheld pack hands none.
    for path <- ["skills/large/SKILL.md", "skills/large/a"] do
      assert {:error, :not_found} = Packs.pack_file(ctx, ctx.athanor_id, "mine", path)
    end
  end

  test "a personal copy of the shipped planner keeps its own folder", %{actor: actor, ctx: ctx} do
    before_packs!(actor, "my-planner", [{["SKILL.md"], shipped_planner()}])
    assert :ok = Packs.settle(ctx)

    assert {:ok, _} =
             Arca.get(actor, ["aqua", "scrolls", "mine", "skills", "my-planner", "SKILL.md"])
  end

  test "a made scroll and an edited shipped one move into mine with their files; an unedited shipped one is dropped; aqua/skills/ is gone",
       %{ctx: ctx, actor: actor} do
    before_packs!(actor, "made", [
      {["SKILL.md"], "---\nname: made\ndescription: mine\n---\n\nMade here.\n"},
      {["references", "how.md"], "the reference"}
    ])

    before_packs!(actor, "canvas", [{["SKILL.md"], "---\nname: canvas\n---\n\nedited here\n"}])
    before_packs!(actor, "planner", [{["SKILL.md"], shipped_planner()}])

    assert {:ok, [_, _, _]} = Arca.Overlay.orphan_units(actor, "aqua")
    assert :ok = Packs.settle(ctx)

    assert {:ok, %{origin: "own", on: true}} =
             Packs.pack(ctx, "mine") |> then(fn {:ok, p} -> {:ok, p.record} end)

    assert {:ok, "the reference"} =
             Arca.get(actor, ~w(aqua scrolls mine skills made references how.md))

    assert {:ok, %{name: "mine:made", body: "Made here."}} = Packs.skill(ctx, "mine:made")
    assert {:ok, %{body: "edited here"}} = Packs.skill(ctx, "mine:canvas")
    assert {:error, :not_found} = Packs.skill(ctx, "mine:planner")

    assert {:ok, []} = Arca.Overlay.orphan_units(actor, "aqua")
    {:ok, entries} = Arca.list_typed(actor, ["aqua"])
    refute Enum.any?(entries, fn {name, _kind} -> name == "skills" end)

    # A second settle finds nothing left to move.
    assert :ok = Packs.settle(ctx)
    {:ok, %{scrolls: scrolls}} = Packs.pack(ctx, "mine")
    assert Enum.map(scrolls, & &1.name) == ["mine:canvas", "mine:made"]
  end

  test "mine holds a scroll only at skills/<name>/SKILL.md: a folder of that name elsewhere holds no edited scroll back",
       %{ctx: ctx, actor: actor} do
    {:ok, _} =
      Arca.Files.write(
        actor,
        "aqua/scrolls/mine/skills/kept/SKILL.md",
        "---\nname: kept\n---\nkept"
      )

    {:ok, _} = Arca.Files.write(actor, "aqua/scrolls/mine/docs/planner/readme.md", "how I plan")
    before_packs!(actor, "planner", [{["SKILL.md"], "---\nname: planner\n---\n\nedited here\n"}])

    assert :ok = Packs.settle(ctx)

    # The edited planner arrived, and only then was its old unit retired.
    assert {:ok, %{body: "edited here"}} = Packs.skill(ctx, "mine:planner")
    assert {:ok, "how I plan"} = Arca.get(actor, ~w(aqua scrolls mine docs planner readme.md))
    assert {:ok, []} = Arca.Overlay.orphan_units(actor, "aqua")
  end

  test "cyfr is copied in, made the seed's again with its switch kept, and a fill makes an empty mine",
       %{ctx: ctx, actor: actor, cyfr: cyfr} do
    assert :ok = Packs.settle(ctx, fill: true)
    assert {:ok, %{body: "v1"}} = Packs.skill(ctx, "cyfr:research")
    assert {:ok, %{origin: "own", scrolls: []}} = Packs.pack(ctx, "mine")

    :ok = Packs.switch(ctx, "cyfr", false)
    File.write!(Path.join(cyfr, "skills/research/SKILL.md"), "---\nname: research\n---\n\nv2\n")
    assert :ok = Packs.settle(ctx)

    assert {:ok, "---\nname: research\n---\n\nv2\n"} =
             Arca.get(actor, ~w(aqua scrolls cyfr skills research SKILL.md))

    assert {:ok, %{on: false, origin: "cyfr"}} = Packs.pack(ctx, "cyfr")

    # The person removed `mine`: a boot's settle does not make it again.
    {:ok, _} = Arca.Files.delete(actor, "aqua/scrolls/mine")
    assert :ok = Packs.settle(ctx)
    assert {:error, :not_found} = Packs.pack(ctx, "mine")
  end
end
