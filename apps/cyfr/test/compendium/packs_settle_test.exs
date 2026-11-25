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
    prev_base = Application.fetch_env!(:arca, :base_path)
    prev_seed = Application.fetch_env!(:arca, :seed_path)
    Application.put_env(:arca, :base_path, Path.join(base, "data"))
    Application.put_env(:arca, :seed_path, seed)

    on_exit(fn ->
      Arca.Storage.UnitLocator.install!(@locators)
      Application.put_env(:arca, :base_path, prev_base)
      Application.put_env(:arca, :seed_path, prev_seed)
      File.rm_rf!(base)
    end)

    cyfr = Path.join(seed, "aqua/scrolls/cyfr")
    File.mkdir_p!(Path.join(cyfr, "skills/research"))
    File.write!(Path.join(cyfr, ".cyfr-pack.json"), Packs.encode_record(%{Packs.own_record() | origin: "cyfr"}))
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
    do: File.read!(Path.expand("../../../../seed/aqua/scrolls/cyfr/skills/planner/SKILL.md", __DIR__))

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

    assert {:ok, "the reference"} = Arca.get(actor, ~w(aqua scrolls mine skills made references how.md))
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
