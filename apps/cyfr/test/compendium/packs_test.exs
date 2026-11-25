# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.PacksTest do
  @moduledoc """
  The packs of scrolls at their public boundaries: an archive brought in
  through the sheet, the one door of `Arca.Files` into `aqua/scrolls/`,
  the switch, the bounds, Download, and the reading T5c consumes
  (`Compendium.pack_digest/2`, `Compendium.pack_view/3`).

  The taste skill's test copy keeps its layout and its names (its
  manifests' `name` and `version`, its scroll's front matter `name`) and
  none of its text, so no file of its author's is held here.
  """

  use ExUnit.Case, async: false

  alias Arca.Files
  alias Compendium.PackArchive
  alias Compendium.Packs

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    base = Path.join(System.tmp_dir!(), "packs_test_#{System.unique_integer([:positive])}")
    Prima.Test.Env.put_app_env(:arca, :base_path, Path.join(base, "data"))
    Prima.Test.Env.put_app_env(:arca, :seed_path, Path.join(base, "seed"))
    File.mkdir_p!(Path.join(base, "seed/aqua"))

    on_exit(fn ->
      File.rm_rf!(base)
    end)

    {ctx, other} = Sanctum.TestContext.two_contexts()
    {:ok, ctx: ctx, other: other, actor: Sanctum.Context.actor(ctx)}
  end

  # ---------------------------------------------------------------------------
  # Archives
  # ---------------------------------------------------------------------------

  # The taste skill's layout at 2.1.5: its Codex manifest and Claude Code
  # marketplace file (no `.claude-plugin/plugin.json`), one scroll in
  # folder `taste-skill` whose front matter names it `design-taste-frontend`,
  # with scripts, references and assets beside it.
  defp taste_skill do
    [
      {"taste-skill/LICENSE", "The test copy's stand-in for its notice.\n", false},
      {"taste-skill/.codex-plugin/plugin.json",
       ~s({"name": "taste-skill", "version": "2.1.5", "skills": "./skills/"}\n), false},
      {"taste-skill/.claude-plugin/marketplace.json",
       ~s({"name": "taste-skill", "plugins": [{"name": "taste-skill", "version": "2.1.5"}]}\n),
       false},
      {"taste-skill/skills/taste-skill/SKILL.md",
       "---\nname: design-taste-frontend\ndescription: art direction for a page\n---\n\nRead the library.\n",
       false},
      {"taste-skill/skills/taste-skill/scripts/draw.mjs",
       "#!/usr/bin/env node\nconsole.log('sectors')\n", true},
      {"taste-skill/skills/taste-skill/references/colour.md", "# Colour\n", false},
      {"taste-skill/skills/taste-skill/assets/mark.png", <<137, 80, 78, 71, 0, 1, 2, 3>>, false}
    ]
  end

  defp tgz(files), do: PackArchive.tar_gz(files)

  # An archive made by another writer than CYFR's own, so the reader is
  # checked against what the world writes.
  defp erl_tgz(entries) do
    path = Path.join(System.tmp_dir!(), "pack_#{System.unique_integer([:positive])}.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(path),
        for({name, bytes} <- entries, do: {String.to_charlist(name), bytes}),
        [:compressed]
      )

    bytes = File.read!(path)
    File.rm!(path)
    bytes
  end

  defp zip(entries) do
    {:ok, {_name, bytes}} =
      :zip.create(
        ~c"pack.zip",
        for({name, bytes} <- entries, do: {String.to_charlist(name), bytes}),
        [:memory]
      )

    bytes
  end

  defp bring_in!(ctx, archive, filename, opts \\ %{}) do
    {:ok, sheet} = Packs.sheet(ctx, archive, filename, opts)
    params = Map.merge(%{"folder" => sheet.folder, "name" => sheet.name}, opts)
    {:ok, name} = Packs.bring_in(ctx, archive, filename, Map.put(params, "agreed", sheet.agreed))
    {name, sheet}
  end

  defp record!(actor, pack) do
    {:ok, raw} = Arca.get(actor, ["aqua", "scrolls", pack, ".cyfr-pack.json"])
    {:ok, record} = Packs.decode_record(raw)
    record
  end

  defp revision(ctx, pack) do
    {:ok, digest} = Packs.pack_digest(ctx, ctx.athanor_id)
    {:ok, view} = Packs.pack_view(ctx, ctx.athanor_id, digest)
    Enum.find(view.packs, &(&1.name == pack))
  end

  # ---------------------------------------------------------------------------
  # Bringing a pack in
  # ---------------------------------------------------------------------------

  describe "bringing a pack in" do
    test "the taste skill comes in byte for byte, named by its folder, its scroll by its front matter",
         %{ctx: ctx, actor: actor} do
      archive = tgz(taste_skill())
      {name, sheet} = bring_in!(ctx, archive, "taste-skill-2.1.5.tar.gz")

      assert name == "taste-skill"
      assert sheet.version == "2.1.5"
      assert sheet.scripts == 1
      assert [%{scroll: "design-taste-frontend", folder: "taste-skill"}] = sheet.scrolls

      for {path, bytes, _x} <- taste_skill() do
        rel = String.replace_prefix(path, "taste-skill/", "")
        assert {:ok, ^bytes} = Arca.get(actor, ["aqua", "scrolls", name | String.split(rel, "/")])
      end

      record = record!(actor, name)

      assert %{
               origin: "brought",
               source: "taste-skill-2.1.5.tar.gz",
               folder: "taste-skill",
               version: "2.1.5",
               on: true,
               executable: ["skills/taste-skill/scripts/draw.mjs"]
             } = record

      assert record.agreed == sheet.agreed

      assert {:ok, %{name: "taste-skill:design-taste-frontend", folder: "taste-skill"}} =
               Packs.skill(ctx, "taste-skill:design-taste-frontend")

      assert {:error, :not_found} = Packs.skill(ctx, "taste-skill:taste-skill")
    end

    test "an archive another writer made reads the same, a .zip as a .tar.gz", %{ctx: ctx} do
      entries = for {path, bytes, _x} <- taste_skill(), do: {path, bytes}

      for archive <- [erl_tgz(entries), zip(entries)] do
        assert {:ok, %{name: "taste-skill", files: 7}} =
                 Packs.sheet(ctx, archive, "a.tar.gz")
      end
    end

    test "a pack named by its .claude-plugin/plugin.json takes that name and refuses another",
         %{ctx: ctx} do
      archive =
        tgz([
          {"repo-main/.claude-plugin/plugin.json", ~s({"name": "pstack", "version": "1.0.0"}),
           false},
          {"repo-main/skills/how/SKILL.md", "---\nname: how\ndescription: d\n---\n\nb\n", false}
        ])

      assert {:ok, %{name: "pstack", named_by_manifest: true}} =
               Packs.sheet(ctx, archive, "repo.tar.gz", %{"name" => "other"})
    end

    test "while it is read, an archive with a duplicate, a file where a folder is, a link, a `..` or an expansion past its bound is refused",
         %{ctx: ctx} do
      link_dir = Path.join(System.tmp_dir!(), "pack_link_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(link_dir, "p/skills/x"))
      File.write!(Path.join(link_dir, "p/skills/x/SKILL.md"), "---\nname: x\n---\n\nb\n")
      File.ln_s!("/etc/passwd", Path.join(link_dir, "p/skills/x/escape"))
      link_tgz = Path.join(link_dir, "link.tar.gz")

      File.cd!(link_dir, fn ->
        :ok = :erl_tar.create(String.to_charlist(link_tgz), [~c"p"], [:compressed])
      end)

      cases = [
        {erl_tgz([{"p/skills/x/SKILL.md", "a"}, {"p/skills/x/SKILL.md", "b"}]), "twice"},
        {erl_tgz([{"p/skills", "a file"}, {"p/skills/x/SKILL.md", "b"}]),
         "both a file and a folder"},
        {File.read!(link_tgz), "a link"},
        {tgz([{"p/../escape/SKILL.md", "b", false}]), "'..'"},
        {:zlib.gzip(:binary.copy(<<0>>, PackArchive.max_expanded() + 32 * 1024 * 1024)),
         "expands past"}
      ]

      for {archive, says} <- cases do
        assert {:error, {:invalid_argument, sentence}} = Packs.sheet(ctx, archive, "a.tar.gz")
        assert sentence =~ says
      end

      File.rm_rf!(link_dir)
    end

    test "a pack past a pack's bounds, or carrying CYFR's record at its root, is refused, naming which",
         %{ctx: ctx} do
      scroll = {"p/skills/x/SKILL.md", "---\nname: x\n---\n\nb\n", false}
      many = for i <- 1..2_048, do: {"p/skills/x/f#{i}", "", false}

      cases = [
        {[scroll | many], "2049 files"},
        {[scroll, {"p/skills/x/big", :binary.copy(<<0>>, 32 * 1024 * 1024 + 1), false}],
         "past a pack's 33554432"},
        {[scroll, {"p/skills/x/huge", :binary.copy(<<0>>, Files.max_write() + 1), false}],
         "past a file's"},
        {[scroll, {"p/.cyfr-pack.json", "{}", false}], ".cyfr-pack.json"},
        {[scroll, {"p/skills/x/a b.md", "", false}], "not a path a pack may hold"}
      ]

      for {files, says} <- cases do
        archive = tgz(files)
        assert {:ok, %{refusal: refusal} = sheet} = Packs.sheet(ctx, archive, "p.tar.gz")
        assert refusal =~ says

        assert {:error, {:invalid_argument, ^refusal}} =
                 Packs.bring_in(ctx, archive, "p.tar.gz", %{"agreed" => sheet.agreed})
      end

      assert {:ok, []} = Packs.list(ctx)
    end

    test "an update whose archive changed between the sheet and the press is refused and shown again",
         %{ctx: ctx, actor: actor} do
      {name, _sheet} = bring_in!(ctx, tgz(taste_skill()), "taste.tar.gz")
      before = revision(ctx, name)

      shown = tgz(taste_skill() ++ [{"taste-skill/NEW.md", "one", false}])
      pressed = tgz(taste_skill() ++ [{"taste-skill/NEW.md", "two", false}])
      {:ok, sheet} = Packs.sheet(ctx, shown, "taste.tar.gz")

      assert {:error, {:changed, again}} =
               Packs.bring_in(ctx, pressed, "taste.tar.gz", %{
                 "folder" => sheet.folder,
                 "name" => name,
                 "agreed" => sheet.agreed
               })

      assert again.agreed != sheet.agreed
      assert [%{path: "NEW.md", change: :added}] = again.update
      assert revision(ctx, name) == before
      assert {:error, :not_found} = Arca.get(actor, ["aqua", "scrolls", name, "NEW.md"])
    end

    test "an update shows a changed script before a changed SKILL.md, and leaves the pack as it was until taken",
         %{ctx: ctx, actor: actor} do
      {name, _sheet} = bring_in!(ctx, tgz(taste_skill()), "taste.tar.gz")
      before = revision(ctx, name)

      updated =
        Enum.map(taste_skill(), fn
          {"taste-skill/skills/taste-skill/SKILL.md" = p, bytes, x} ->
            {p, bytes <> "more\n", x}

          {"taste-skill/skills/taste-skill/scripts/draw.mjs" = p, bytes, x} ->
            {p, bytes <> "//\n", x}

          other ->
            other
        end)

      {:ok, sheet} = Packs.sheet(ctx, tgz(updated), "taste.tar.gz")

      assert [
               %{path: "skills/taste-skill/scripts/draw.mjs", change: :changed},
               %{path: "skills/taste-skill/SKILL.md", change: :changed}
             ] = sheet.update

      assert revision(ctx, name) == before
      {_name, _} = bring_in!(ctx, tgz(updated), "taste.tar.gz")

      assert {:ok, "#!/usr/bin/env node\nconsole.log('sectors')\n//\n"} =
               Arca.get(
                 actor,
                 ~w(aqua scrolls taste-skill skills taste-skill scripts draw.mjs)
               )
    end

    test "the sheet names every MCP server of the three ways a plugin declares them", %{ctx: ctx} do
      archive =
        tgz([
          {"p/.claude-plugin/plugin.json",
           ~s({"name": "srv", "mcpServers": {"inline-one": {"command": "a"}}}), false},
          {"p/.codex-plugin/plugin.json", ~s({"name": "srv", "mcpServers": "./servers.json"}),
           false},
          {"p/servers.json", ~s({"mcpServers": {"from-file": {"command": "b"}}}), false},
          {"p/.mcp.json", ~s({"mcpServers": {"dot-mcp": {"command": "c"}}}), false},
          {"p/skills/x/SKILL.md", "---\nname: x\n---\n\nb\n", false}
        ])

      assert {:ok, %{parts: %{servers: servers}}} = Packs.sheet(ctx, archive, "srv.tar.gz")
      assert Enum.sort(servers) == ["dot-mcp", "from-file", "inline-one"]
    end
  end

  # ---------------------------------------------------------------------------
  # One door
  # ---------------------------------------------------------------------------

  describe "one door: Arca.Files into aqua/scrolls/" do
    test "a write under a new folder makes a pack of the person's own, a delete of the folder removes it",
         %{ctx: ctx, actor: actor} do
      assert {:ok, _} =
               Files.write(
                 actor,
                 "aqua/scrolls/notes/skills/keep/SKILL.md",
                 "---\nname: keep\n---\n\nb\n"
               )

      assert %{origin: "own", on: true} = record!(actor, "notes")
      assert {:ok, %{name: "notes:keep"}} = Packs.skill(ctx, "notes:keep")

      assert {:ok, _} = Files.delete(actor, "aqua/scrolls/notes")
      assert {:error, :not_found} = Packs.pack(ctx, "notes")
    end

    test "a write making a pack named cyfr, or one outside the grammar, is refused saying why",
         %{actor: actor} do
      assert {:error, {:invalid_argument, cyfr}} =
               Files.write(actor, "aqua/scrolls/cyfr/skills/x/SKILL.md", "b")

      assert cyfr =~ "CYFR's own pack"

      assert {:error, {:invalid_argument, grammar}} =
               Files.write(actor, "aqua/scrolls/-bad/skills/x/SKILL.md", "b")

      assert grammar =~ "letters, digits"
    end

    test "an ordinary write, delete or move inside a brought pack, and any write of a record, is refused",
         %{ctx: ctx, actor: actor} do
      {name, _} = bring_in!(ctx, tgz(taste_skill()), "taste.tar.gz")
      before = revision(ctx, name)
      inside = "aqua/scrolls/#{name}/skills/taste-skill/SKILL.md"

      assert {:error, {:invalid_argument, written}} = Files.write(actor, inside, "changed")
      assert written =~ "brought in"
      assert {:error, {:invalid_argument, deleted}} = Files.delete(actor, inside)
      assert deleted =~ "brought in"
      assert {:error, {:invalid_argument, _}} = Files.move(actor, inside, "data/stolen.md")

      {:ok, _} =
        Files.write(actor, "aqua/scrolls/mine/skills/a/SKILL.md", "---\nname: a\n---\n\nb\n")

      for pack <- [name, "mine"] do
        assert {:error, {:invalid_argument, _}} =
                 Files.write(
                   actor,
                   "aqua/scrolls/#{pack}/.cyfr-pack.json",
                   ~s({"origin": "own", "on": true})
                 )
      end

      assert revision(ctx, name) == before
      assert %{origin: "brought"} = record!(actor, name)
    end

    test "each Files write and delete inside mine is one new revision with its digest, and nothing else is",
         %{ctx: ctx, actor: actor} do
      {:ok, _} =
        Files.write(actor, "aqua/scrolls/mine/skills/a/SKILL.md", "---\nname: a\n---\n\nb\n")

      first = revision(ctx, "mine")

      {:ok, _} = Files.write(actor, "aqua/scrolls/mine/skills/a/notes.md", "n")
      second = revision(ctx, "mine")
      assert second.revision != first.revision
      assert Enum.map(second.files, & &1.path) == ["skills/a/SKILL.md", "skills/a/notes.md"]

      assert {:error, _} = Files.move(actor, "aqua/scrolls/mine/skills/a/notes.md", "data/n.md")
      assert revision(ctx, "mine") == second

      {:ok, _} = Files.delete(actor, "aqua/scrolls/mine/skills/a/notes.md")
      third = revision(ctx, "mine")
      assert third.revision == first.revision
      assert third.files == first.files

      {:ok, digest} = Packs.pack_digest(ctx, ctx.athanor_id)
      assert {:ok, %{digest: ^digest}} = Packs.pack_view(ctx, ctx.athanor_id, digest)
    end
  end

  # ---------------------------------------------------------------------------
  # The switch, the agreement and the set's bound
  # ---------------------------------------------------------------------------

  describe "the switch" do
    test "a brought pack switched off and on again asks for no agreement, its agreed digest still the files'",
         %{ctx: ctx, actor: actor} do
      {name, sheet} = bring_in!(ctx, tgz(taste_skill()), "taste.tar.gz")
      on = revision(ctx, name)

      assert :ok = Packs.switch(ctx, name, false)
      assert %{on: false, files: []} = revision(ctx, name)
      assert {:error, :not_found} = Packs.skill(ctx, "#{name}:design-taste-frontend")
      assert {:ok, []} = Packs.index(ctx)

      assert :ok = Packs.switch(ctx, name, true)
      again = revision(ctx, name)
      assert again.files == on.files
      assert again.revision == on.revision
      assert record!(actor, name).agreed == sheet.agreed
      assert {:ok, [%{name: "taste-skill:design-taste-frontend"}]} = Packs.index(ctx)
    end

    @tag timeout: 600_000
    test "switching on, an update or an edit past the set's 8,192 files or 128 MiB is refused, naming the sum",
         %{ctx: ctx, actor: actor} do
      sixteen = :binary.copy(<<1>>, 16 * 1024)
      manifest = "---\nname: s\ndescription: d\n---\n\nb\n"

      body = [
        {"skills/s/SKILL.md", manifest} | for(j <- 1..1_599, do: {"skills/s/f#{j}", sixteen})
      ]

      pack_bytes = 1_599 * 16 * 1024 + byte_size(manifest)
      bound = 128 * 1024 * 1024
      # Five packs of 1,600 files switched on: 8,000 files and 125 MiB, each
      # pack within its own bounds; what takes the set one byte past 128 MiB.
      past = :binary.copy("x", bound - 5 * pack_bytes + 1)
      brought = %{Packs.own_record() | origin: "brought"}
      extra = for j <- 1..193, do: {"skills/e/f#{j}", "e"}

      for {pack, record, files} <- [
            {"big1", brought, body},
            {"big2", Packs.own_record(), body},
            {"big3", Packs.own_record(), body},
            {"big4", Packs.own_record(), body},
            {"big5", Packs.own_record(), body},
            {"extra", %{Packs.own_record() | on: false}, extra}
          ] do
        :ok =
          Arca.Overlay.edit_unit(actor, ["aqua", "scrolls", pack], fn nil ->
            {:ok,
             Enum.map(files, fn {path, bytes} -> {String.split(path, "/"), bytes} end) ++
               [{[".cyfr-pack.json"], Packs.encode_record(record)}]}
          end)
      end

      assert {:error, {:invalid_argument, switched}} = Packs.switch(ctx, "extra", true)
      assert switched =~ "8193 files together"

      assert {:error, {:invalid_argument, made}} =
               Files.write(actor, "aqua/scrolls/small/skills/a/SKILL.md", past)

      assert made =~ "#{bound + 1} bytes together"

      assert {:error, {:invalid_argument, edited}} =
               Files.write(actor, "aqua/scrolls/big2/skills/s/more", past)

      assert edited =~ "#{bound + 1} bytes together"

      update =
        tgz(
          for({path, bytes} <- body, do: {"big1/" <> path, bytes, false}) ++
            [{"big1/skills/s/more", past, false}]
        )

      {:ok, sheet} = Packs.sheet(ctx, update, "big1.tar.gz")
      assert [%{path: "skills/s/more", change: :added}] = sheet.update

      assert {:error, {:invalid_argument, updated}} =
               Packs.bring_in(ctx, update, "big1.tar.gz", %{
                 "folder" => sheet.folder,
                 "name" => "big1",
                 "agreed" => sheet.agreed
               })

      assert updated =~ "#{bound + 1} bytes together"
      assert %{on: false} = record!(actor, "extra")
      assert {:error, :not_found} = Packs.pack(ctx, "small")
    end
  end

  # ---------------------------------------------------------------------------
  # Executable bits, Download and tenancy
  # ---------------------------------------------------------------------------

  describe "executable bits and Download" do
    test "in mine a file beginning #! runs, in the view and in Download, and the round trip keeps it",
         %{ctx: ctx, other: other, actor: actor} do
      {:ok, _} =
        Files.write(actor, "aqua/scrolls/mine/skills/a/SKILL.md", "---\nname: a\n---\n\nb\n")

      {:ok, _} = Files.write(actor, "aqua/scrolls/mine/skills/a/run.sh", "#!/bin/sh\necho ok\n")
      {:ok, _} = Files.write(actor, "aqua/scrolls/mine/skills/a/data.txt", "plain\n")

      view = revision(ctx, "mine")

      assert [
               %{path: "skills/a/SKILL.md", executable: false},
               %{path: "skills/a/data.txt", executable: false},
               %{path: "skills/a/run.sh", executable: true}
             ] = view.files

      assert {:ok, %{filename: "mine.tar.gz", bytes: archive}} = Packs.download(ctx, "mine")
      {:ok, entries} = PackArchive.read(archive)

      assert Enum.map(entries, &{&1.path, &1.executable}) == [
               {"mine/skills/a/SKILL.md", false},
               {"mine/skills/a/data.txt", false},
               {"mine/skills/a/run.sh", true}
             ]

      refute Enum.any?(entries, &String.ends_with?(&1.path, ".cyfr-pack.json"))

      # Brought in again on another athanor: the same scrolls and files,
      # byte for byte, bits included.
      {name, _} = bring_in!(other, archive, "mine.tar.gz")
      assert name == "mine"
      theirs = revision(other, "mine")

      assert Enum.map(theirs.files, &Map.take(&1, [:path, :sha256, :executable])) ==
               Enum.map(view.files, &Map.take(&1, [:path, :sha256, :executable]))

      assert {:ok, %{name: "mine:a"}} = Packs.skill(other, "mine:a")
    end

    test "another athanor's pack is never found, read, viewed or downloaded", %{
      ctx: ctx,
      other: other,
      actor: actor
    } do
      {:ok, _} =
        Files.write(actor, "aqua/scrolls/mine/skills/a/SKILL.md", "---\nname: a\n---\n\nb\n")

      {:ok, digest} = Packs.pack_digest(ctx, ctx.athanor_id)

      assert {:error, :not_found} = Packs.skill(other, "mine:a")
      assert {:error, :not_found} = Packs.pack(other, "mine")
      assert {:error, :not_found} = Packs.download(other, "mine")
      assert {:error, :not_found} = Packs.pack_digest(other, ctx.athanor_id)
      assert {:error, :not_found} = Packs.pack_view(other, ctx.athanor_id, digest)

      assert {:error, :not_found} =
               Packs.pack_file(other, ctx.athanor_id, "mine", "skills/a/SKILL.md")

      assert {:ok, []} = Packs.list(other)
    end
  end

  # ---------------------------------------------------------------------------
  # Names
  # ---------------------------------------------------------------------------

  describe "naming a scroll" do
    test "two scrolls of one pack under one name: the second is not handed and its card says why",
         %{ctx: ctx, actor: actor} do
      {:ok, _} =
        Files.write(
          actor,
          "aqua/scrolls/mine/skills/a/SKILL.md",
          "---\nname: same\n---\n\nfirst\n"
        )

      {:ok, _} =
        Files.write(
          actor,
          "aqua/scrolls/mine/skills/b/SKILL.md",
          "---\nname: same\n---\n\nsecond\n"
        )

      assert {:ok, %{body: "first"}} = Packs.skill(ctx, "mine:same")
      {:ok, %{scrolls: scrolls}} = Packs.pack(ctx, "mine")

      assert [%{folder: "a", shadowed: false}, %{folder: "b", shadowed: true, carried: false}] =
               scrolls
    end

    test "a front matter with no name, or one outside the grammar, names its scroll by its folder",
         %{ctx: ctx, actor: actor} do
      {:ok, _} =
        Files.write(
          actor,
          "aqua/scrolls/mine/skills/plain/SKILL.md",
          "---\ndescription: d\n---\n\nb\n"
        )

      {:ok, _} =
        Files.write(
          actor,
          "aqua/scrolls/mine/skills/odd/SKILL.md",
          "---\nname: \"a b\"\n---\n\nb\n"
        )

      assert {:ok, %{scroll: "plain"}} = Packs.skill(ctx, "mine:plain")
      assert {:ok, %{scroll: "odd", title: "a b"}} = Packs.skill(ctx, "mine:odd")
    end

    test "a bare name is refused with a sentence naming the full names that match it",
         %{ctx: ctx, actor: actor} do
      {:ok, _} =
        Files.write(
          actor,
          "aqua/scrolls/mine/skills/builder/SKILL.md",
          "---\nname: builder\n---\n\nb\n"
        )

      assert {:error,
              {:invalid_argument, "No scroll is named `builder` alone: `mine:builder` is."}} =
               Packs.skill(ctx, "builder")
    end
  end
end
