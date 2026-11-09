# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.SeedBundleTest do
  @moduledoc """
  The seed tree is the model-catalyst roster and ships the canvas. Tests
  read it; they do not keep a vendor list of their own.
  """

  use ExUnit.Case, async: true

  alias Cyfr.Test.SeedBundle

  test "model_chat_units lists shipped contract catalysts and omits the hands" do
    units = SeedBundle.model_chat_units()
    assert [_ | _] = units

    for unit <- units do
      assert Prima.Model.speaks_chat?(unit.manifest)
      assert unit.type == "catalyst"
      assert unit.ref == "catalyst:local.#{unit.name}"
      assert unit.rel == "catalysts/local/#{unit.name}/#{unit.version}"
    end

    names = Enum.map(units, & &1.name)
    refute "files" in names
    refute "http" in names
  end

  # A model catalyst is an API catalyst, which CYFR attaches a key for, or
  # a harness adapter, which runs a program on the person's own sign-in.
  defp adapter?(unit),
    do:
      Enum.any?(
        Prima.Manifest.Needs.from_manifest(unit.manifest) || [],
        &Prima.Manifest.Needs.mount_only?/1
      )

  test "each API model catalyst's newest version has CYFR attach its key, to its egress hosts" do
    for unit <- SeedBundle.model_chat_units(), not adapter?(unit) do
      assert [need] = Prima.Manifest.Needs.from_manifest(unit.manifest), unit.rel
      assert %{name: "api_key", kind: "api_key", disclose: false} = need
      assert %{in: "header", template: template} = need.attach
      assert template =~ "{value}"
      assert need.hosts == Enum.sort(unit.manifest["caps"]["egress"]["domains"]), unit.rel
    end
  end

  # Every assistant turn's sources hold `pinned`, and its model calls and
  # hands run as children seeded with them, so a stock catalyst that left
  # any class without a flow to its own egress would have every send of
  # every turn refused.
  test "each harness adapter's newest version runs one program on a login need and reaches no host" do
    adapters = Enum.filter(SeedBundle.model_chat_units(), &adapter?/1)
    assert [_ | _] = adapters

    for unit <- adapters do
      assert [%{kind: "login", program: program}] =
               Prima.Manifest.Needs.from_manifest(unit.manifest),
             unit.rel

      assert is_binary(program), unit.rel
      refute get_in(unit.manifest, ["caps", "egress"]), unit.rel
      refute get_in(unit.manifest, ["caps", "flows"]), unit.rel
    end
  end

  test "each stock catalyst's newest version lets every source class reach its egress, and only that" do
    units =
      Enum.reject(SeedBundle.model_chat_units(), &adapter?/1) ++
        [SeedBundle.local_unit!("catalysts", "http")]

    ledger = Enum.map(Prima.Source.classes(), &Prima.Source.new/1)

    for unit <- units do
      caps = unit.manifest["caps"]
      domains = caps["egress"]["domains"]
      declared = %{domains: domains, needs: Map.keys(unit.manifest["needs"] || %{})}

      assert {:ok, flows} = Prima.Flow.parse(caps["flows"], declared), unit.rel

      expected =
        for class <- Prima.Source.classes(), domain <- domains, do: %{from: class, to: domain}

      assert {unit.rel, flows} == {unit.rel, Prima.Flow.set(expected)}

      for domain <- domains do
        host = String.replace_prefix(domain, "*", "any.example")

        assert {unit.rel, Prima.Flow.uncovered(ledger, {:domain, host}, flows: flows)} ==
                 {unit.rel, []}
      end
    end
  end

  test "local_unit! takes the newest shipped version of a named hand" do
    files = SeedBundle.local_unit!("catalysts", "files")
    refute Prima.Model.speaks_chat?(files.manifest)
    assert files.ref == "catalyst:local.files"
    assert files.rel == "catalysts/local/files/#{files.version}"
  end

  test "the shipped canvas is 0.5.0 on the react template, the default layout's, and the publish check accepts it" do
    canvas = SeedBundle.local_unit!("tinctures", "canvas")
    assert canvas.type == "tincture"
    assert canvas.ref == "tincture:local.canvas"
    assert canvas.version == "0.5.0"

    # The seed ships it beside the version before it, which stays as it
    # shipped.
    dir = Path.join(Path.expand("../../../../seed/components", __DIR__), canvas.rel)
    assert dir |> Path.dirname() |> File.ls!() |> Enum.sort() == ["0.4.0", canvas.version]

    # The default layout's one canvas, with nothing placed over it.
    assert [%{id: "home", tincture: ref, postures: postures}] = Prima.Layout.default().canvases
    assert ref == canvas.ref
    assert postures == %{}

    assert Prima.Manifest.validate(canvas.manifest, fn _ -> true end) == :ok
    assert {:ok, declaration} = Compendium.tincture_declaration(canvas.manifest)
    assert Prima.Manifest.Tincture.canvas?(declaration)
    assert declaration.frame.background == false
    assert declaration.frame.capabilities == []

    # The react template's page: the build's entry, built by Vite from the
    # lockfile it ships.
    react = Enum.find(Compendium.tincture_templates(), &(&1.name == "react"))
    assert canvas.manifest["tincture"]["entry"] == react.entry
    assert canvas.manifest["tincture"]["build"] == %{"tool" => react.build}
    assert Compendium.tincture_entry(canvas.manifest) == {:ok, "dist/index.html"}
    assert Compendium.tincture_lockfile_required?(canvas.manifest)

    # It reads the athanor's runs, schedules and schedule runs, names no
    # feed, and declares nothing else: no action and no connect origin.
    assert declaration.actions == []

    assert Enum.map(declaration.streams, &{&1.name, &1.subject}) == [
             {"runs.changes", nil},
             {"schedules.changes", nil},
             {"schedule_runs.changes", nil}
           ]

    assert Compendium.tincture_check_streams(declaration, Sanctum.Catalog.streams()) == :ok
    assert Compendium.tincture_check_desktop(declaration, Sanctum.Catalog.streams()) == :ok

    # It pauses and resumes a schedule, picked from the schedules it reads,
    # keeps each section's on and off in its preferences, and declares the
    # current look in its chrome, read as publish reads it.
    pick = %Prima.Manifest.Tincture.Pick{
      stream: "schedules.changes",
      field: "/schedule_id",
      arg: "schedule_id"
    }

    assert [
             %{id: "pause-schedule", operation: "schedule.pause", args: %{}, pick: ^pick},
             %{id: "resume-schedule", operation: "schedule.resume", args: %{}, pick: ^pick}
           ] = declaration.desktop.controls

    assert declaration.desktop.prefs == %{
             widgets: Map.new(~w(attention runs apps schedules), &{&1, %{}}),
             desktop: %{}
           }

    assert declaration.desktop.chrome == "chrome.css"

    assert {:ok, tokens} =
             Compendium.tincture_check_chrome(declaration, &File.read(Path.join(dir, &1)))

    assert tokens == %{
             "fonts" => [],
             "radius" => 12,
             "border" => 1,
             "edge" => 8,
             "title-height" => 34,
             "controls" => "right",
             "title-align" => "left",
             "glyphs" => "plain",
             "font" => "system"
           }

    for key <- ~w(actions connect),
        do: refute(Map.has_key?(canvas.manifest["tincture"], key), key)

    refute Map.has_key?(canvas.manifest, "caps")
    refute Map.has_key?(canvas.manifest, "dependencies")

    # The check a registry runs before it installs a tincture: the entry,
    # the declaration and its streams, the served types and the lockfile.
    assert {:ok, %{size: _}} = Compendium.TinctureValidator.validate(dir)

    # Its sources with the lockfile beside its package manifest, and the
    # build's page, its assets and the notices of the packages it bundles:
    # no build debris.
    files =
      for path <- Prima.Test.SourceTree.files!(Path.join(dir, "**/*")),
          File.regular?(path),
          do: Path.relative_to(path, dir)

    {built, sources} = Enum.split_with(files, &String.starts_with?(&1, "dist/"))

    assert Enum.sort(sources) ==
             ~w(chrome.css cyfr-manifest.json index.html package-lock.json package.json src/App.tsx
                src/cyfr.d.ts src/index.css src/main.tsx src/model.ts tsconfig.json vite.config.ts)

    assert {[_js], [_css]} =
             built
             |> Enum.filter(&(&1 =~ ~r{\Adist/assets/index-[A-Za-z0-9_-]+\.(js|css)\z}))
             |> Enum.split_with(&String.ends_with?(&1, ".js"))

    assert length(built) == 4
    assert "dist/index.html" in built
    assert "dist/third-party-notices.json" in built
  end

  test "the line desktop is 0.1.0 on the vanilla template, and the publish check accepts it" do
    line = SeedBundle.local_unit!("tinctures", "line")
    assert line.ref == "tincture:local.line"
    assert line.version == "0.1.0"
    dir = Path.join(Path.expand("../../../../seed/components", __DIR__), line.rel)

    assert Prima.Manifest.validate(line.manifest, fn _ -> true end) == :ok
    assert {:ok, declaration} = Compendium.tincture_declaration(line.manifest)
    assert Prima.Manifest.Tincture.canvas?(declaration)
    assert Compendium.tincture_entry(line.manifest) == {:ok, "index.html"}
    refute Compendium.tincture_lockfile_required?(line.manifest)

    # What its widgets read, the feeds it names among them; the page opens
    # at most five of these at once.
    assert Enum.map(declaration.streams, &{&1.name, &1.subject}) == [
             {"attention.changes", nil},
             {"runs.changes", nil},
             {"schedules.changes", nil},
             {"activity.changes", nil},
             {"threads.changes", nil},
             {"vault.changes", nil},
             {"feed.results", "weather"},
             {"feed.results", "vpn"}
           ]

    assert Compendium.tincture_check_streams(declaration, Sanctum.Catalog.streams()) == :ok
    assert Compendium.tincture_check_desktop(declaration, Sanctum.Catalog.streams()) == :ok
    assert Enum.map(declaration.desktop.controls, & &1.operation) == ~w(schedule.pause schedule.resume)

    # Every widget but the queue keeps where it stands and, per screen
    # size, whether it is on.
    assert Map.keys(declaration.desktop.prefs.widgets) |> Enum.sort() ==
             ~w(apps day queue schedules threads today vault vpn weather)

    # Its chrome: both modes' colours, its own font shipped as WOFF2.
    assert {:ok, tokens} =
             Compendium.tincture_check_chrome(declaration, &File.read(Path.join(dir, &1)))

    assert %{"radius" => 10, "title-height" => 40, "controls" => "right", "glyphs" => "plain"} =
             tokens

    assert [_font] = tokens["fonts"]
    assert {:ok, %{size: _}} = Compendium.TinctureValidator.validate(dir)

    files =
      for path <- Prima.Test.SourceTree.files!(Path.join(dir, "**/*")),
          File.regular?(path),
          do: Path.relative_to(path, dir)

    assert Enum.sort(files) ==
             ~w(app.js chrome.css cyfr-manifest.json fonts/geist-latin.woff2 index.html style.css)
  end

  test "the shipped vault declares only what a frame can complete, and passes the publish check" do
    vault = SeedBundle.local_unit!("tinctures", "vault")
    assert vault.ref == "tincture:local.vault"

    assert Prima.Manifest.validate(vault.manifest, fn _ -> true end) == :ok
    assert {:ok, declaration} = Compendium.tincture_declaration(vault.manifest)

    # vault.status is its read; vault.create is the credential prompt's
    # write, which the shell honours only for a tincture that declares it.
    # Every other vault act needs an interactive session, which a frame
    # never is: those are the console's vault page's.
    assert Enum.sort(declaration.actions) == ~w(vault.create vault.status)
    assert declaration.streams == []
    assert declaration.frame.capabilities == []
    refute Map.has_key?(vault.manifest["tincture"], "connect")
    refute Map.has_key?(vault.manifest, "caps")
    refute Map.has_key?(vault.manifest, "dependencies")

    for operation <- declaration.actions do
      [tool, action] = String.split(operation, ".")
      assert {:ok, {_provider, definition}} = Sanctum.Catalog.lookup(tool)
      assert Map.has_key?(Sanctum.Annotations.actions_of(definition), action), operation
    end

    dir = Path.join(Path.expand("../../../../seed/components", __DIR__), vault.rel)

    files =
      for path <- Prima.Test.SourceTree.files!(Path.join(dir, "**/*")),
          File.regular?(path),
          do: {Path.relative_to(path, dir), File.stat!(path).size}

    assert {:ok, _size} = Compendium.Tincture.check_version(vault.manifest, files)

    # The page reads names and standing, adds through the shell's prompt,
    # changes and removes nothing, and sets every text as text.
    script = File.read!(Path.join(dir, "vault.js"))
    refute script =~ "innerHTML"
    assert script =~ "cyfr.credential("

    for act <- ~w(vault.list vault.delete vault.rotate vault.revoke vault.rename vault.rebind),
        do: refute(script =~ act, "the page calls #{act}")

    page = File.read!(Path.join(dir, "index.html"))
    refute page =~ ~r/https?:\/\//
    assert page =~ "Entries are changed and removed on the console's vault page."
  end

  test "local_unit! finds a shipped formula by name" do
    formula = SeedBundle.local_unit!("formulas", "list-models")
    assert formula.type == "formula"
    assert formula.ref == "formula:local.list-models"
    assert formula.rel == "formulas/local/list-models/#{formula.version}"
  end
end
