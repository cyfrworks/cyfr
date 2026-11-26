# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# A store that cannot say how much one pack, `sib`, holds; every other read
# is the local adapter's.
defmodule Compendium.PacksTest.UnmeasurableSibling do
  @moduledoc false
  use Arca.Storage.TestDouble

  def usage(actor, path) do
    if "sib" in path,
      do: {:error, :eacces},
      else: Arca.Adapters.Local.usage(actor, path)
  end
end

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

  # A .zip whose central directory claims another expanded size for the
  # named entries than they hold.
  defp declare(zip, claimed) do
    Enum.reduce(claimed, zip, fn {name, size}, bytes ->
      [at] =
        for {at, _} <- :binary.matches(bytes, <<"PK", 1, 2>>),
            central_named?(bytes, at, name),
            do: at

      cut = at + 24
      <<head::binary-size(^cut), _usize::little-32, rest::binary>> = bytes
      head <> <<size::little-32>> <> rest
    end)
  end

  defp central_named?(bytes, at, name) do
    skip = at + 28
    <<_::binary-size(^skip), nlen::little-16, _::binary>> = bytes
    binary_part(bytes, at + 46, nlen) == name
  end

  defp bring_in!(ctx, archive, filename, opts \\ %{}) do
    {:ok, sheet} = Packs.sheet(ctx, archive, filename, opts)

    params =
      Map.merge(
        %{"folder" => sheet.folder, "name" => sheet.name, "against" => sheet.against},
        opts
      )

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
    test "the sheet names the manifest's hook file and server list", %{ctx: ctx} do
      archive =
        tgz([
          {"sample/.claude-plugin/plugin.json",
           Jason.encode!(%{
             "name" => "sample",
             "hooks" => "./config/hooks.json",
             "mcpServers" => ["./config/servers.json"]
           }), false},
          {"sample/config/hooks.json",
           Jason.encode!(%{
             "hooks" => %{"Stop" => [%{"hooks" => [%{"type" => "command", "command" => "true"}]}]}
           }), false},
          {"sample/config/servers.json",
           Jason.encode!(%{"mcpServers" => %{"library" => %{"command" => "true"}}}), false}
        ])

      {:ok, sheet} = Packs.sheet(ctx, archive, "sample.tgz")
      assert sheet.refusal == nil
      assert {sheet.parts.hooks, sheet.parts.servers} == {["Stop"], ["library"]}
    end

    test "a new import keeps the name conflict visible if another tab used the name", %{
      ctx: ctx,
      actor: actor
    } do
      shown = tgz([{"same/skills/one/SKILL.md", "---\nname: one\n---\nfirst", false}])
      other = tgz([{"same/skills/two/SKILL.md", "---\nname: two\n---\nsecond", false}])
      {:ok, sheet} = Packs.sheet(ctx, shown, "same.tar.gz")
      assert sheet.update == nil
      {"same", _} = bring_in!(ctx, other, "same.tar.gz")

      result =
        Packs.bring_in(ctx, shown, "same.tar.gz", %{
          "name" => sheet.name,
          "folder" => sheet.folder,
          "agreed" => sheet.agreed
        })

      assert {result, Arca.get(actor, ~w(aqua scrolls same skills two SKILL.md))}
             |> then(fn {r, old} -> {elem(r, 0), elem(old, 0)} end) == {:error, :ok}
    end

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

    # A .zip entry says what it expands to; that is held to what is left
    # before a byte of it is inflated, so an entry that lies is refused by
    # its claim, not read as damage after the work.
    test "a .zip entry's declared size is held to the file's and the archive's allowance before it inflates",
         %{ctx: ctx} do
      claims = fn entries, claimed ->
        {:ok, {_name, bytes}} =
          :zip.create(
            ~c"p.zip",
            for({name, data} <- entries, do: {String.to_charlist(name), data}),
            [:memory]
          )

        declare(bytes, claimed)
      end

      past_file =
        claims.([{"p/skills/x/SKILL.md", "b"}], %{
          "p/skills/x/SKILL.md" => Arca.Files.max_write() + 1
        })

      assert {:error, {:invalid_argument, file}} = Packs.sheet(ctx, past_file, "p.zip")
      assert file =~ "past a file's #{Arca.Files.max_write()} bytes"

      nineteen = :binary.copy(<<0>>, 19_000_000)
      real = for i <- 1..7, do: {"p/f#{i}", nineteen}

      past_archive =
        claims.(real ++ [{"p/skills/x/SKILL.md", "b"}], %{"p/skills/x/SKILL.md" => 19_000_000})

      assert {:error, {:invalid_argument, archive}} = Packs.sheet(ctx, past_archive, "p.zip")
      assert archive =~ "expands past #{PackArchive.max_expanded()} bytes"
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

    # Every form Claude Code's plugin manifest reference allows for the
    # parts a program would load: a path, a list of paths, an inline
    # object, a file the manifest names; and the defaults beside them.
    test "the sheet reads every form the manifest allows for hooks, servers, agents, commands and skills",
         %{ctx: ctx} do
      hook = fn event ->
        %{event => [%{"hooks" => [%{"type" => "command", "command" => "true"}]}]}
      end

      lists =
        tgz([
          {"p/.claude-plugin/plugin.json",
           Jason.encode!(%{
             "name" => "lists",
             "hooks" => ["./config/hooks.json", hook.("PostToolUse")],
             "mcpServers" => [%{"inline-one" => %{"command" => "a"}}, "./servers.json"],
             "agents" => ["./custom/reviewer.md", "./custom/tester.md"],
             "commands" => %{
               "status" => %{"source" => "./cmds/status.md"},
               "about" => %{"content" => "Explain."}
             },
             "skills" => ["./extra/", "."]
           }), false},
          {"p/hooks/hooks.json", Jason.encode!(%{"hooks" => hook.("SessionStart")}), false},
          {"p/config/hooks.json", Jason.encode!(%{"hooks" => hook.("Stop")}), false},
          {"p/.mcp.json", ~s({"mcpServers": {"dot-mcp": {"command": "c"}}}), false},
          {"p/servers.json", ~s({"mcpServers": {"from-file": {"command": "b"}}}), false},
          {"p/custom/reviewer.md", "r", false},
          {"p/custom/tester.md", "t", false},
          {"p/agents/replaced.md", "a", false},
          {"p/cmds/status.md", "s", false},
          {"p/commands/replaced.md", "c", false},
          {"p/extra/one/SKILL.md", "---\nname: one\n---\n\no\n", false},
          {"p/SKILL.md", "---\nname: root\n---\n\nr\n", false},
          {"p/skills/x/SKILL.md", "---\nname: x\n---\n\nb\n", false}
        ])

      assert {:ok, %{parts: parts}} = Packs.sheet(ctx, lists, "lists.tar.gz")

      assert parts == %{
               hooks: ["PostToolUse", "SessionStart", "Stop"],
               servers: ["dot-mcp", "from-file", "inline-one"],
               agents: ["reviewer", "tester"],
               commands: ["about", "status"],
               skills: ["SKILL.md", "extra/one/SKILL.md"],
               paths: [
                 "custom/reviewer.md",
                 "custom/tester.md",
                 "cmds/status.md",
                 "config/hooks.json",
                 "servers.json",
                 "extra"
               ],
               unread: []
             }

      singles =
        tgz([
          {"p/.claude-plugin/plugin.json",
           Jason.encode!(%{
             "name" => "singles",
             "hooks" => "./config/hooks.json",
             "mcpServers" => %{"inline-one" => %{"command" => "a"}},
             "agents" => "./custom/reviewer.md",
             "commands" => ["./cmds/", "./more/extra.md"],
             "skills" => "./extra/"
           }), false},
          {"p/config/hooks.json", Jason.encode!(%{"hooks" => hook.("Stop")}), false},
          {"p/custom/reviewer.md", "r", false},
          {"p/cmds/status.md", "s", false},
          {"p/cmds/deep/not-flat.md", "n", false},
          {"p/more/extra.md", "e", false},
          {"p/extra/one/SKILL.md", "---\nname: one\n---\n\no\n", false},
          {"p/skills/x/SKILL.md", "---\nname: x\n---\n\nb\n", false}
        ])

      assert {:ok, %{parts: parts}} = Packs.sheet(ctx, singles, "singles.tar.gz")

      assert parts == %{
               hooks: ["Stop"],
               servers: ["inline-one"],
               agents: ["reviewer"],
               commands: ["extra", "status"],
               skills: ["extra/one/SKILL.md"],
               paths: [
                 "custom/reviewer.md",
                 "cmds",
                 "more/extra.md",
                 "config/hooks.json",
                 "extra"
               ],
               unread: []
             }

      # What the reader does not read is named by its key, never left out.
      odd =
        tgz([
          {"p/.claude-plugin/plugin.json",
           Jason.encode!(%{
             "name" => "odd",
             "hooks" => 5,
             "mcpServers" => ["./bundle.mcpb", "https://example.com/s.mcpb"],
             "agents" => "./custom/",
             "commands" => "commands/no-dot.md",
             "skills" => "./missing/",
             "lspServers" => %{"go" => %{"command" => "gopls"}}
           }), false},
          {"p/bundle.mcpb", "zip", false},
          {"p/custom/a.md", "a", false},
          {"p/commands/no-dot.md", "c", false},
          {"p/skills/x/SKILL.md", "---\nname: x\n---\n\nb\n", false}
        ])

      assert {:ok, %{parts: %{unread: unread}}} = Packs.sheet(ctx, odd, "odd.tar.gz")
      assert Enum.sort(unread) == ~w(agents commands hooks lspServers mcpServers skills)
    end

    test "the agreement is bound to each file's executable bit", %{ctx: ctx} do
      plain =
        tgz([
          {"p/skills/x/SKILL.md", "---\nname: x\n---\n\nb\n", false},
          {"p/run.sh", "echo\n", false}
        ])

      runs =
        tgz([
          {"p/skills/x/SKILL.md", "---\nname: x\n---\n\nb\n", false},
          {"p/run.sh", "echo\n", true}
        ])

      {:ok, shown} = Packs.sheet(ctx, plain, "p.tar.gz")
      {:ok, pressed} = Packs.sheet(ctx, runs, "p.tar.gz")
      assert shown.agreed != pressed.agreed

      assert {:error, {:changed, _}} =
               Packs.bring_in(ctx, runs, "p.tar.gz", %{
                 "folder" => shown.folder,
                 "name" => shown.name,
                 "agreed" => shown.agreed
               })
    end

    test "a press agrees to the place too: a pack changed since the sheet is refused, a switch alone is not",
         %{ctx: ctx, actor: actor} do
      {name, _} = bring_in!(ctx, tgz(taste_skill()), "taste.tar.gz")
      updated = tgz(taste_skill() ++ [{"taste-skill/NEW.md", "one", false}])
      {:ok, sheet} = Packs.sheet(ctx, updated, "taste.tar.gz")
      assert sheet.against != nil

      press = %{
        "folder" => sheet.folder,
        "name" => name,
        "agreed" => sheet.agreed,
        "against" => sheet.against
      }

      # A switch alone between the sheet and the press: the files are the
      # ones the sheet showed, and the update lands.
      assert :ok = Packs.switch(ctx, name, false)
      assert :ok = Packs.switch(ctx, name, true)
      assert {:ok, ^name} = Packs.bring_in(ctx, updated, "taste.tar.gz", press)
      assert {:ok, "one"} = Arca.get(actor, ["aqua", "scrolls", name, "NEW.md"])

      # Another update lands between this sheet and its press: refused,
      # shown again, and the pack keeps what the other press brought.
      again = tgz(taste_skill() ++ [{"taste-skill/NEW.md", "three", false}])
      {:ok, stale} = Packs.sheet(ctx, again, "taste.tar.gz")

      {_name, _} =
        bring_in!(
          ctx,
          tgz(taste_skill() ++ [{"taste-skill/NEW.md", "two", false}]),
          "taste.tar.gz"
        )

      assert {:error, {:changed, shown}} =
               Packs.bring_in(ctx, again, "taste.tar.gz", %{
                 "folder" => stale.folder,
                 "name" => name,
                 "agreed" => stale.agreed,
                 "against" => stale.against
               })

      assert shown.against != stale.against
      assert {:ok, "two"} = Arca.get(actor, ["aqua", "scrolls", name, "NEW.md"])
    end

    test "the sheet reads the destination once: a pack brought in while the sheet is made is shown or refused at the press",
         %{ctx: ctx, actor: actor} do
      shown = tgz([{"same/skills/one/SKILL.md", "---\nname: one\n---\nfirst", false}])
      other = tgz([{"same/skills/two/SKILL.md", "---\nname: two\n---\nsecond", false}])
      test = self()
      handler = "packs-sheet-hold-#{System.unique_integer([:positive])}"

      # The sheet is held right after it read whether a pack is there: the
      # other pack is brought in then, before the sheet goes on.
      :ok =
        :telemetry.attach(
          handler,
          [:cyfr, :packs, :sheet, :destination],
          fn _event, _measures, _meta, _config ->
            if Process.delete(:hold_sheet) do
              send(test, {:sheet_holds, self()})

              receive do
                :go -> :ok
              end
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      making =
        Task.async(fn ->
          Process.put(:hold_sheet, true)
          Packs.sheet(ctx, shown, "same.tar.gz")
        end)

      assert_receive {:sheet_holds, holder}, 60_000
      {"same", _} = bring_in!(ctx, other, "same.tar.gz")
      send(holder, :go)
      {:ok, sheet} = Task.await(making, 60_000)

      press =
        Packs.bring_in(ctx, shown, "same.tar.gz", %{
          "name" => sheet.name,
          "folder" => sheet.folder,
          "agreed" => sheet.agreed,
          "against" => sheet.against
        })

      # Either the sheet showed the replacement, or its press is refused
      # and the pack brought in meanwhile is kept.
      case sheet.update do
        nil ->
          assert {:error, {:changed, _again}} = press
          assert {:ok, _} = Arca.get(actor, ~w(aqua scrolls same skills two SKILL.md))

        [_ | _] ->
          assert {:ok, "same"} = press
      end
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

    test "only a scroll's SKILL.md makes a pack; any other first write there makes nothing",
         %{ctx: ctx, actor: actor} do
      assert {:error, {:invalid_argument, sentence}} =
               Files.write(actor, "aqua/scrolls/stray/notes.md", "n")

      assert sentence =~ "No pack named `stray` is here"

      assert {:error, {:invalid_argument, _}} =
               Files.write(actor, "aqua/scrolls/stray/skills/x/run.sh", "n")

      assert {:error, :not_found} = Packs.pack(ctx, "stray")

      # New pack is a write that makes a pack or fails: refused when the pack
      # is here, whatever the asker believed.
      {:ok, _} =
        Files.write(actor, "aqua/scrolls/garden/skills/a/SKILL.md", "---\nname: a\n---\n\nb\n")

      assert {:error, {:invalid_argument, taken}} =
               Packs.put_scroll(ctx, "garden:roses", "---\nname: roses\n---\n\nr\n", :new_pack)

      assert taken =~ "already here"
      assert {:error, :not_found} = Packs.skill(ctx, "garden:roses")
      assert :ok = Packs.put_scroll(ctx, "fresh:roses", "---\nname: roses\n---\n\nr\n", :new_pack)
      assert {:ok, %{name: "fresh:roses"}} = Packs.skill(ctx, "fresh:roses")
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
                 "agreed" => sheet.agreed,
                 "against" => sheet.against
               })

      assert updated =~ "#{bound + 1} bytes together"
      assert %{on: false} = record!(actor, "extra")
      assert {:error, :not_found} = Packs.pack(ctx, "small")
    end
  end

  # ---------------------------------------------------------------------------
  # Executable bits, Download and tenancy
  # ---------------------------------------------------------------------------

  describe "what a program is handed" do
    test "a pack whose size cannot be read refuses a write into another, never counting as nothing",
         %{ctx: ctx, actor: actor} do
      {:ok, _} =
        Files.write(actor, "aqua/scrolls/sib/skills/a/SKILL.md", "---\nname: a\n---\nb")

      Prima.Test.Env.put_app_env(
        :arca,
        :storage_adapter,
        Compendium.PacksTest.UnmeasurableSibling
      )

      assert {:error, {:invalid_argument, refused}} =
               Files.write(actor, "aqua/scrolls/other/skills/b/SKILL.md", "---\nname: b\n---\nc")

      assert refused =~ "The size of the pack `sib` cannot be read"
      assert {:error, :not_found} = Packs.pack(ctx, "other")
    end

    @tag timeout: 600_000
    test "packs committed past the set's bound together are not all handed: the later in name order is withheld",
         %{ctx: ctx, actor: actor} do
      # Four packs of 2,048 files, each within its own bounds, hold the
      # set's 8,192 between them; a fifth of one file takes the set past it.
      # Each is committed around the early check, as two writers out of each
      # other's sight could, so only the reading stands between them.
      manifest = "---\nname: s\ndescription: d\n---\n\nb\n"
      full = [{"skills/s/SKILL.md", manifest} | for(j <- 1..2_047, do: {"skills/s/f#{j}", "x"})]

      for {pack, files} <- [
            {"a1", full},
            {"a2", full},
            {"a3", full},
            {"a4", full},
            {"a5", [{"skills/s/SKILL.md", manifest}]}
          ] do
        :ok =
          Arca.Overlay.edit_unit(actor, ["aqua", "scrolls", pack], fn nil ->
            {:ok,
             Enum.map(files, fn {path, bytes} -> {String.split(path, "/"), bytes} end) ++
               [{[".cyfr-pack.json"], Packs.encode_record(Packs.own_record())}]}
          end)
      end

      {:ok, digest} = Packs.pack_digest(ctx, ctx.athanor_id)
      {:ok, view} = Packs.pack_view(ctx, ctx.athanor_id, digest)
      by_name = Map.new(view.packs, &{&1.name, &1})

      for pack <- ~w(a1 a2 a3 a4) do
        assert %{on: true, withheld: nil, files: files} = by_name[pack]
        assert length(files) == 2_048
      end

      assert %{on: true, files: [], withheld: withheld} = by_name["a5"]

      assert withheld ==
               "Your packs together are past the 8192 files they may hold, at 8193 with this " <>
                 "one; switch one off"

      assert {:error, :not_found} =
               Packs.pack_file(ctx, ctx.athanor_id, "a5", "skills/s/SKILL.md")

      assert {:ok, ^manifest} = Packs.pack_file(ctx, ctx.athanor_id, "a4", "skills/s/SKILL.md")

      {:ok, cards} = Packs.list(ctx)
      assert %{past: past} = Enum.find(cards, &(&1.name == "a5"))
      assert past =~ "your packs together are past the 8192 files"
      assert %{past: nil} = Enum.find(cards, &(&1.name == "a4"))
    end

    test "the view's archive is the manifest of the files handed, then each of them under its pack",
         %{ctx: ctx, other: other, actor: actor} do
      skill = "---\nname: a\n---\n\nb\n"
      script = "#!/bin/sh\necho ok\n"
      {:ok, _} = Files.write(actor, "aqua/scrolls/mine/skills/a/SKILL.md", skill)
      {:ok, _} = Files.write(actor, "aqua/scrolls/mine/skills/a/run.sh", script)

      {:ok, _} =
        Files.write(
          actor,
          "aqua/scrolls/garden/skills/roses/SKILL.md",
          "---\nname: roses\n---\nred"
        )

      assert :ok = Packs.switch(ctx, "garden", false)

      {:ok, digest} = Packs.pack_digest(ctx, ctx.athanor_id)
      {:ok, view} = Packs.pack_view(ctx, ctx.athanor_id, digest)

      # Read by another reader than CYFR's own writer, as the keeper's is.
      {:ok, table} = :erl_tar.table({:binary, view.archive}, [:verbose])

      {:ok, [{~c".cyfr-packs.json", manifest} | files]} =
        :erl_tar.extract({:binary, view.archive}, [:memory])

      assert %{
               entries: for({name, type, _, _, mode, _, _} <- table, do: {"#{name}", type, mode}),
               manifest: Jason.decode!(manifest, keys: :atoms!),
               files: for({name, bytes} <- files, do: {"#{name}", bytes})
             } == %{
               entries: [
                 {".cyfr-packs.json", :regular, 0o644},
                 {"mine/skills/a/SKILL.md", :regular, 0o644},
                 {"mine/skills/a/run.sh", :regular, 0o755}
               ],
               manifest: %{
                 files:
                   for(
                     %{name: "mine", files: lines} <- view.packs,
                     line <- lines,
                     do: %{line | path: "mine/" <> line.path}
                   )
               },
               files: [{"mine/skills/a/SKILL.md", skill}, {"mine/skills/a/run.sh", script}]
             }

      # A set that hands no file is its manifest alone.
      {:ok, none} = Packs.pack_digest(other, other.athanor_id)
      {:ok, empty} = Packs.pack_view(other, other.athanor_id, none)
      assert empty.archive == PackArchive.tar([{".cyfr-packs.json", ~s({"files":[]}), false}])
    end

    test "the bounds and the stream's first entry are the keeper's, as the shared vectors pin them",
         %{ctx: ctx} do
      shared =
        Path.expand("../../../../tests/fixtures/keeper_protocol.json", __DIR__)
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("pack_bounds")

      {manifest, bounds} = Map.pop!(shared, "manifest")
      assert bounds == Map.new(Packs.bounds(), fn {name, n} -> {Atom.to_string(name), n} end)

      {:ok, digest} = Packs.pack_digest(ctx, ctx.athanor_id)
      {:ok, view} = Packs.pack_view(ctx, ctx.athanor_id, digest)
      {:ok, [{first, _bytes} | _rest]} = :erl_tar.extract({:binary, view.archive}, [:memory])
      assert "#{first}" == manifest
    end

    test "the archive of a pack at the longest name and path is the shared vectors' pack_archive, which the keeper extracts",
         %{ctx: ctx, actor: actor} do
      %{"pack" => pack, "path" => path, "data" => data, "archive" => archive} =
        Path.expand("../../../../tests/fixtures/keeper_protocol.json", __DIR__)
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("pack_archive")

      bounds = Packs.bounds()
      assert {byte_size(pack), byte_size(path)} == {bounds.name_bytes, bounds.path_bytes}

      :ok =
        Arca.Overlay.edit_unit(actor, ["aqua", "scrolls", pack], fn nil ->
          {:ok,
           [
             {[".cyfr-pack.json"], Packs.encode_record(Packs.own_record())},
             {String.split(path, "/"), data}
           ]}
        end)

      {:ok, digest} = Packs.pack_digest(ctx, ctx.athanor_id)
      {:ok, view} = Packs.pack_view(ctx, ctx.athanor_id, digest)
      assert view.archive == Base.decode64!(archive)
    end

    test "a path's bound is on the path inside its pack, the keeper's too, at the shared vectors' edge" do
      %{"held" => held, "refused" => refused} =
        Path.expand("../../../../tests/fixtures/keeper_protocol.json", __DIR__)
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("pack_paths")

      for path <- held, do: assert(:ok = Packs.pack_path(path), "#{byte_size(path)} bytes")

      for path <- refused,
          do:
            assert(
              {:error, {:invalid_argument, _}} = Packs.pack_path(path),
              "#{byte_size(path)} bytes"
            )
    end

    test "pack_file/4 answers for no file of a pack switched off, by any path", %{
      ctx: ctx,
      actor: actor
    } do
      {:ok, _} =
        Files.write(
          actor,
          "aqua/scrolls/garden/skills/roses/SKILL.md",
          "---\nname: roses\n---\nred"
        )

      {:ok, _} = Files.write(actor, "aqua/scrolls/garden/skills/roses/notes.md", "thorns")

      assert {:ok, "thorns"} =
               Packs.pack_file(ctx, ctx.athanor_id, "garden", "skills/roses/notes.md")

      assert :ok = Packs.switch(ctx, "garden", false)

      for path <- ["skills/roses/SKILL.md", "skills/roses/notes.md"] do
        assert {:error, :not_found} = Packs.pack_file(ctx, ctx.athanor_id, "garden", path)
      end

      {:ok, digest} = Packs.pack_digest(ctx, ctx.athanor_id)
      {:ok, view} = Packs.pack_view(ctx, ctx.athanor_id, digest)
      assert %{on: false, files: []} = Enum.find(view.packs, &(&1.name == "garden"))
    end
  end

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

      assert {:ok, %{filename: "mine.tar.gz", stream: stream}} = Packs.download(ctx, "mine")
      # Made as it is read: one compressed chunk a file, then the end.
      assert is_function(stream, 2)
      chunks = Enum.to_list(stream)
      assert length(chunks) == length(view.files) + 1
      archive = Enum.join(chunks)
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

  # ---------------------------------------------------------------------------
  # A file a turn proposes beside a scroll
  # ---------------------------------------------------------------------------

  # A turn proposes one file beside a scroll of a pack of the person's own,
  # made against the file as it read it; the person's Save writes it as one
  # revision of the pack, only while the scroll is stored and the file is
  # as the proposal read it, and every rule of what may be proposed holds
  # again at the Save.
  describe "a file a turn proposes beside a scroll" do
    setup %{actor: actor} do
      {:ok, _} =
        Files.write(
          actor,
          "aqua/scrolls/mine/skills/fern/SKILL.md",
          "---\nname: fern\n---\n\nb\n"
        )

      :ok
    end

    test "a proposal is made against the file as it is, and Save writes one revision over exactly that",
         %{ctx: ctx, actor: actor} do
      path = "skills/fern/scripts/water.sh"
      first = "#!/bin/sh\necho water\n"
      second = "#!/bin/sh\necho more water\n"
      before = revision(ctx, "mine")

      assert {:ok, %{against: "none", against_size: nil, runs: true, script: true}} =
               Packs.file_proposal(ctx, "mine:fern", path, first)

      assert {:ok, %{against: "none"}} = Packs.file_proposal(ctx, "mine:fern", path, second)

      # A proposal writes nothing.
      assert {:error, :not_found} =
               Arca.get(actor, ~w(aqua scrolls mine skills fern scripts water.sh))

      assert revision(ctx, "mine").revision == before.revision

      assert :ok = Packs.put_file(ctx, "mine:fern", path, first, "none")
      saved = revision(ctx, "mine")
      refute saved.revision == before.revision
      assert %{executable: true} = Enum.find(saved.files, &(&1.path == path))

      # The second proposal read the same absence: saved after the first, it
      # is refused and the first stays.
      assert {:error, {:conflict, refusal}} =
               Packs.put_file(ctx, "mine:fern", path, second, "none")

      assert refusal ==
               "The file `skills/fern/scripts/water.sh` changed since Aqua proposed this, so " <>
                 "nothing was saved: open it in Files to see it as it is now"

      assert {:ok, ^first} = Arca.get(actor, ~w(aqua scrolls mine skills fern scripts water.sh))

      # Proposed again over the file as it is now, the Save replaces it.
      against = Prima.Digest.sha256(first)

      size = byte_size(first)

      assert {:ok, %{against: ^against, against_size: ^size}} =
               Packs.file_proposal(ctx, "mine:fern", path, second)

      # The file's digest is what a replacement was read against: changed
      # and changed back through Files, it is the file the person saw.
      full = "aqua/scrolls/mine/" <> path
      {:ok, _} = Files.write(actor, full, "#!/bin/sh\necho meanwhile\n")
      {:ok, _} = Files.write(actor, full, first)

      assert :ok = Packs.put_file(ctx, "mine:fern", path, second, against)
      assert {:ok, ^second} = Arca.get(actor, ~w(aqua scrolls mine skills fern scripts water.sh))

      # A reference is no script; a file under scripts/ is one as the sheet
      # counts it, and will be executable only with `#!`.
      assert {:ok, %{runs: false, script: false}} =
               Packs.file_proposal(ctx, "mine:fern", "skills/fern/notes.md", "Keep it shaded.\n")

      assert {:ok, %{runs: false, script: true}} =
               Packs.file_proposal(ctx, "mine:fern", "skills/fern/scripts/README.txt", "Notes.\n")
    end

    test "only a path beside a stored scroll of a pack of the person's own is proposed and saved",
         %{ctx: ctx, actor: actor} do
      {:ok, _} =
        Files.write(
          actor,
          "aqua/scrolls/mine/.claude-plugin/plugin.json",
          Jason.encode!(%{
            "name" => "mine",
            "description" => "See ./skills/fern/notes.md for background.",
            "skills" => ["./skills/", "./skills/fern/extra"],
            "hooks" => "./skills/fern/hooks.json",
            "agents" => ["./skills/fern/agent.md"],
            "commands" => %{"water" => %{"source" => "./skills/fern/water.md"}},
            "mcpServers" => "./skills/fern/servers.json"
          })
        )

      {:ok, _} =
        Files.write(
          actor,
          "aqua/scrolls/garden/skills/roses/SKILL.md",
          "---\nname: roses\n---\n\nb\n"
        )

      {:ok, _} = Files.write(actor, "aqua/scrolls/garden/.claude-plugin/plugin.json", "{not json")

      {:ok, _} =
        Files.write(
          actor,
          "aqua/scrolls/mine/hooks/hooks.json",
          ~s({"hooks": {"PreToolUse": [{"hooks": [{"type": "command", ) <>
            ~s("command": "${CLAUDE_PLUGIN_ROOT}/skills/fern/scripts/guard.sh"}]}]}})
        )

      {brought, _sheet} =
        bring_in!(
          ctx,
          tgz([{"tools/skills/x/SKILL.md", "---\nname: x\n---\n\nb\n", false}]),
          "p.tar.gz"
        )

      outside = fn path ->
        "`#{path}` is outside the folder of the scroll `mine:fern`, `skills/fern/`: a file " <>
          "Aqua proposes stays beside its scroll"
      end

      declared = fn path ->
        "`#{path}` is declared by the pack's `.claude-plugin/plugin.json` as part of what its " <>
          "programs load: change it through Files"
      end

      manifest =
        "A scroll's SKILL.md is written with `aqua.skill_create` or `aqua.skill_update`, never as a file"

      long = "skills/fern/" <> String.duplicate("a", 245)

      refused = [
        {"mine:fern", "skills/other/x.sh", "x", outside.("skills/other/x.sh")},
        {"mine:fern", "hooks/hooks.json", "{}", outside.("hooks/hooks.json")},
        {"mine:fern", ".claude-plugin/plugin.json", "{}", outside.(".claude-plugin/plugin.json")},
        {"mine:fern", "skills/fern", "x", outside.("skills/fern")},
        {"mine:fern", "skills/fern/SKILL.md", "x", manifest},
        {"mine:fern", "skills/fern/sub/SKILL.md", "x", manifest},
        {"mine:fern", "skills/fern/hooks.json", "{}", declared.("skills/fern/hooks.json")},
        {"mine:fern", "skills/fern/agent.md", "a", declared.("skills/fern/agent.md")},
        {"mine:fern", "skills/fern/water.md", "w", declared.("skills/fern/water.md")},
        {"mine:fern", "skills/fern/servers.json", "{}", declared.("skills/fern/servers.json")},
        {"mine:fern", "skills/fern/extra/tool/run.sh", "#!/bin/sh\n",
         declared.("skills/fern/extra/tool/run.sh")},
        {"garden:roses", "skills/roses/a.txt", "a",
         "The pack `garden`'s `.claude-plugin/plugin.json` cannot be read, so what it " <>
           "declares is not known: mend it through Files"},
        {"mine:fern", "skills/fern/leaf.png", <<137, 80, 0, 1>>,
         "A file Aqua proposes is text, which its card shows whole, and " <>
           "`skills/fern/leaf.png` is not: put it in through Files"},
        {"mine:fern", "skills/fern/../x", "x",
         "`skills/fern/../x` is not a path a pack may hold: letters, digits, `_`, `-`, `.` " <>
           "and `/`, with no `..`"},
        {"mine:fern", long, "x", "`#{long}` is a path past a pack's 255 bytes"},
        {"mine:fern", "skills/fern/big.txt", String.duplicate("a", Packs.max_bytes() + 1),
         "A file Aqua proposes holds at most 131072 bytes and `skills/fern/big.txt` holds " <>
           "131073: put it in through Files"},
        {"#{brought}:x", "skills/x/run.sh", "x",
         "`tools` was brought in and is kept as its author published it: copy the scroll " <>
           "into a pack of your own"},
        {"cyfr:research", "skills/research/run.sh", "x",
         "`cyfr` is CYFR's own pack and changes only with CYFR's update: copy the scroll " <>
           "into a pack of your own"}
      ]

      for {name, path, bytes, sentence} <- refused do
        assert {:error, {:invalid_argument, ^sentence}} =
                 Packs.file_proposal(ctx, name, path, bytes),
               path

        assert {:error, {:invalid_argument, ^sentence}} =
                 Packs.put_file(ctx, name, path, bytes, "none"),
               path
      end

      # The default `skills/` declares nothing beyond the scrolls' folder, a
      # path the manifest's prose mentions is an ordinary file, and a hook
      # that names a file as a program's argument declares no path (a
      # stated limit): each is proposed and saved.
      for path <- ["skills/fern/notes.md", "skills/fern/scripts/guard.sh"] do
        assert {:ok, %{against: "none"}} = Packs.file_proposal(ctx, "mine:fern", path, "n\n"),
               path

        assert :ok = Packs.put_file(ctx, "mine:fern", path, "n\n", "none"), path
      end

      assert length(revision(ctx, "mine").files) == 5
    end

    # The Save would refuse a file the pack or the packs switched on have
    # no room for; the proposal says so first, as its early notice.
    test "a proposal the pack or the set has no room for is refused at the proposal",
         %{ctx: ctx, actor: actor} do
      fill = fn pack, count ->
        :ok =
          Arca.Overlay.edit_unit(actor, ["aqua", "scrolls", pack], fn current ->
            base = current || [{[".cyfr-pack.json"], Packs.encode_record(Packs.own_record())}]
            {:ok, base ++ for(i <- 1..count, do: {["skills", "fern", "file#{i}"], "a"})}
          end)
      end

      fill.("mine", 2_047)
      path = "skills/fern/extra.txt"
      full = "The pack `mine` would hold 2049 files, past a pack's 2048"

      assert {:error, {:invalid_argument, ^full}} =
               Packs.file_proposal(ctx, "mine:fern", path, "x")

      assert {:error, {:invalid_argument, ^full}} =
               Packs.put_file(ctx, "mine:fern", path, "x", "none")

      # A pack with room, while the packs switched on together have none:
      # with `zz`'s scroll they hold 8,192 files, the most they may.
      fill.("a1", 2_048)
      fill.("a2", 2_048)
      fill.("a3", 2_047)

      {:ok, _} =
        Files.write(actor, "aqua/scrolls/zz/skills/fern/SKILL.md", "---\nname: fern\n---\n\nb\n")

      set =
        "The packs switched on would hold 8193 files together, past the 8192 they may " <>
          "hold: switch one off first"

      assert {:error, {:invalid_argument, ^set}} = Packs.file_proposal(ctx, "zz:fern", path, "x")
    end

    # A file and a folder never share a name, as Files refuses: a file
    # under a file, or a file where a folder is, is refused at the proposal
    # and at the Save, in Files' own words, never as storage unavailable.
    test "a file and a folder that would share a name are refused, in Files' words",
         %{ctx: ctx, actor: actor} do
      {:ok, _} = Files.write(actor, "aqua/scrolls/mine/skills/fern/notes.md", "n\n")

      {:ok, _} =
        Files.write(actor, "aqua/scrolls/mine/skills/fern/scripts/water.sh", "#!/bin/sh\n")

      for path <- ["skills/fern/notes.md/x.txt", "skills/fern/scripts"] do
        sentence = "'#{path}' cannot go there: a file and a folder would share a name"

        assert {:error, {:conflict, ^sentence}} =
                 Packs.file_proposal(ctx, "mine:fern", path, "x\n"),
               path

        assert {:error, {:conflict, ^sentence}} =
                 Packs.put_file(ctx, "mine:fern", path, "x\n", "none"),
               path

        # Files refuses the same place in the same words.
        files = "aqua/scrolls/mine/" <> path
        files_sentence = "'#{files}' cannot go there: a file and a folder would share a name"
        assert {:error, {:conflict, ^files_sentence}} = Files.write(actor, files, "x\n"), path
      end
    end

    test "a file for a scroll not stored yet is proposed, and its Save waits for the scroll",
         %{ctx: ctx, actor: actor} do
      first = "Save the scroll `mine:tulip` first: this file belongs to it"
      in_new_pack = "Save the scroll `garden:roses` first: this file belongs to it"

      assert {:ok, %{against: "none"}} =
               Packs.file_proposal(ctx, "mine:tulip", "skills/tulip/run.sh", "#!/bin/sh\n")

      assert {:error, {:invalid_argument, ^first}} =
               Packs.put_file(ctx, "mine:tulip", "skills/tulip/run.sh", "#!/bin/sh\n", "none")

      assert {:ok, %{against: "none"}} =
               Packs.file_proposal(ctx, "garden:roses", "skills/roses/a.txt", "a\n")

      assert {:error, {:invalid_argument, ^in_new_pack}} =
               Packs.put_file(ctx, "garden:roses", "skills/roses/a.txt", "a\n", "none")

      assert {:error, :not_found} = Packs.pack(ctx, "garden")

      # Once the scroll is stored, its file is saved beside it.
      {:ok, _} =
        Files.write(
          actor,
          "aqua/scrolls/mine/skills/tulip/SKILL.md",
          "---\nname: tulip\n---\n\nb\n"
        )

      assert :ok = Packs.put_file(ctx, "mine:tulip", "skills/tulip/run.sh", "#!/bin/sh\n", "none")
    end
  end
end
