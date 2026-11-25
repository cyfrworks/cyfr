# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Providers.AquaTest do
  @moduledoc """
  The `aqua` tool's scroll actions over packs: `skill_get` reads a scroll
  by its full name, or one file of its pack by its path; a bare name is
  refused with the full names that match it; a write into a brought pack
  is refused, naming it; and a pack switched off is neither listed nor
  read.
  """

  use ExUnit.Case, async: false

  alias Arca.Files
  alias Compendium.PackArchive
  alias Compendium.Packs
  alias Compendium.Providers.Aqua, as: Tool

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    base = Path.join(System.tmp_dir!(), "aqua_tool_#{System.unique_integer([:positive])}")
    Prima.Test.Env.put_app_env(:arca, :base_path, Path.join(base, "data"))
    Prima.Test.Env.put_app_env(:arca, :seed_path, Path.join(base, "seed"))
    File.mkdir_p!(Path.join(base, "seed/aqua"))

    on_exit(fn ->
      File.rm_rf!(base)
    end)

    ctx = Sanctum.TestContext.local()
    actor = Sanctum.Context.actor(ctx)

    {:ok, _} =
      Files.write(
        actor,
        "aqua/scrolls/mine/skills/fern/SKILL.md",
        "---\nname: fern\ndescription: how the fern is kept\n---\n\nWater it weekly.\n"
      )

    {:ok, _} =
      Files.write(actor, "aqua/scrolls/mine/skills/fern/notes.md", "Keep it out of the sun.\n")

    {:ok, _} =
      Files.write(
        actor,
        "aqua/scrolls/mine/skills/fern/leaf.png",
        Base.encode64(<<137, 80, 78, 71, 0, 9>>),
        "base64"
      )

    {:ok, _} =
      Files.write(
        actor,
        "aqua/scrolls/mine/skills/how/SKILL.md",
        "---\nname: how\ndescription: kept from the model\ndisable-model-invocation: true\n---\n\nAsk first.\n"
      )

    {:ok, ctx: ctx, actor: actor}
  end

  defp bring_in!(ctx, files) do
    archive = PackArchive.tar_gz(files)
    {:ok, sheet} = Packs.sheet(ctx, archive, "p.tar.gz")

    {:ok, name} =
      Packs.bring_in(ctx, archive, "p.tar.gz", %{
        "folder" => sheet.folder,
        "name" => sheet.name,
        "agreed" => sheet.agreed
      })

    name
  end

  test "skill_get reads a scroll's SKILL.md by its full name, another file of its pack as outside material, and a binary by its type and size",
       %{ctx: ctx} do
    assert {:ok,
            %{name: "mine:fern", content: "Water it weekly.", resources: ["leaf.png", "notes.md"]}} =
             Tool.handle(ctx, %{"action" => "skill_get", "name" => "mine:fern"})

    assert {:ok,
            %{path: "skills/fern/notes.md", format: "text", content: "Keep it out of the sun.\n"}} =
             Tool.handle(ctx, %{
               "action" => "skill_get",
               "name" => "mine:fern",
               "path" => "skills/fern/notes.md"
             })

    assert {:ok, %{format: "binary", type: "image/png", size: 6} = binary} =
             Tool.handle(ctx, %{
               "action" => "skill_get",
               "name" => "mine:fern",
               "path" => "skills/fern/leaf.png"
             })

    refute Map.has_key?(binary, :content)

    assert {:error, {:not_found, "File", _}} =
             Tool.handle(ctx, %{
               "action" => "skill_get",
               "name" => "mine:fern",
               "path" => ".cyfr-pack.json"
             })
  end

  test "a text file past a scroll's bound is cut, with a note saying so", %{
    ctx: ctx,
    actor: actor
  } do
    long = :binary.copy("a", Packs.max_bytes() + 10)
    {:ok, _} = Files.write(actor, "aqua/scrolls/mine/skills/fern/long.md", long)

    assert {:ok, %{content: content, note: note}} =
             Tool.handle(ctx, %{
               "action" => "skill_get",
               "name" => "mine:fern",
               "path" => "skills/fern/long.md"
             })

    assert byte_size(content) == Packs.max_bytes()
    assert note =~ "cut at a scroll's bound"
  end

  test "a bare name is refused with a sentence listing the full names matching it", %{ctx: ctx} do
    assert {:error, {:invalid_argument, "No scroll is named `fern` alone: `mine:fern` is."}} =
             Tool.handle(ctx, %{"action" => "skill_get", "name" => "fern"})

    assert {:error, {:invalid_argument, "No scroll is named `fern` alone: `mine:fern` is."}} =
             Tool.handle(ctx, %{
               "action" => "skill_create",
               "name" => "fern",
               "description" => "d",
               "content" => "c"
             })
  end

  test "skill_create into a brought pack is refused, naming the pack, from a chain and from the person",
       %{ctx: ctx} do
    name = bring_in!(ctx, [{"tools/skills/x/SKILL.md", "---\nname: x\n---\n\nb\n", false}])

    args = %{
      "action" => "skill_create",
      "name" => "#{name}:y",
      "description" => "d",
      "content" => "c"
    }

    for ctx <- [Sanctum.Context.enter_guest(ctx), ctx] do
      assert {:error, {:invalid_argument, sentence}} = Tool.handle(ctx, args)
      assert sentence =~ "`tools` was brought in"
      assert sentence =~ "copy the scroll into a pack of your own"
    end

    assert {:error, {:invalid_argument, _}} =
             Tool.handle(ctx, %{
               "action" => "skill_update",
               "name" => "#{name}:x",
               "content" => "c"
             })

    assert {:error, {:invalid_argument, _}} =
             Tool.handle(ctx, %{"action" => "skill_delete", "name" => "#{name}:x"})

    assert {:ok, %{content: "b"}} =
             Tool.handle(ctx, %{"action" => "skill_get", "name" => "tools:x"})
  end

  test "a pack switched off is neither listed nor readable", %{ctx: ctx} do
    assert {:ok, %{skills: listed}} = Tool.handle(ctx, %{"action" => "skill_list"})
    assert Enum.map(listed, & &1.name) == ["mine:fern", "mine:how"]

    :ok = Packs.switch(ctx, "mine", false)

    assert {:ok, %{skills: [], count: 0}} = Tool.handle(ctx, %{"action" => "skill_list"})

    assert {:error, {:not_found, "Scroll", "mine:fern"}} =
             Tool.handle(ctx, %{"action" => "skill_get", "name" => "mine:fern"})
  end

  test "a scroll kept from the model is read by its full name and listed with its flag", %{
    ctx: ctx
  } do
    assert {:ok, %{name: "mine:how", content: "Ask first.", kept: true}} =
             Tool.handle(ctx, %{"action" => "skill_get", "name" => "mine:how"})

    assert {:ok, %{skills: listed}} = Tool.handle(ctx, %{"action" => "skill_list"})
    assert %{kept: true} = Enum.find(listed, &(&1.name == "mine:how"))
  end

  test "skill_create makes a pack of the person's own the name names, and a second of one name is refused",
       %{ctx: ctx, actor: actor} do
    args = %{
      "action" => "skill_create",
      "name" => "garden:roses",
      "description" => "d",
      "content" => "c"
    }

    assert {:ok, %{created: "garden:roses"}} = Tool.handle(ctx, args)
    assert {:ok, raw} = Arca.get(actor, ~w(aqua scrolls garden .cyfr-pack.json))
    assert {:ok, %{origin: "own", on: true}} = Packs.decode_record(raw)

    assert {:error, {:invalid_argument, "Scroll 'garden:roses' already exists"}} =
             Tool.handle(ctx, args)

    assert {:error, {:invalid_argument, cyfr}} =
             Tool.handle(ctx, %{args | "name" => "cyfr:roses"})

    assert cyfr =~ "CYFR's own pack"
  end
end
