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

  test "each API model catalyst's newest version has CYFR attach its key, to its egress hosts" do
    for unit <- SeedBundle.model_chat_units() do
      assert [need] = Prima.Manifest.Needs.from_manifest(unit.manifest), unit.rel
      assert %{name: "api_key", kind: "api_key", disclose: false} = need
      assert %{in: "header", template: template} = need.attach
      assert template =~ "{value}"
      assert need.hosts == Enum.sort(unit.manifest["caps"]["egress"]["domains"]), unit.rel
    end
  end

  test "no shipped manifest declares flows, and each passes the manifest validator" do
    components = Path.expand("../../../../seed/components", __DIR__)
    manifests = Path.join(components, "*/local/*/*/cyfr-manifest.json")

    for path <- Prima.Test.SourceTree.files!(manifests) do
      rel = Path.relative_to(Path.dirname(path), components)
      manifest = path |> File.read!() |> Jason.decode!()
      refute Map.has_key?(manifest["caps"] || %{}, "flows"), rel
      assert {rel, Prima.Manifest.validate(manifest, fn _ -> true end)} == {rel, :ok}
    end
  end

  test "local_unit! takes the newest shipped version of a named hand" do
    files = SeedBundle.local_unit!("catalysts", "files")
    refute Prima.Model.speaks_chat?(files.manifest)
    assert files.ref == "catalyst:local.files"
    assert files.rel == "catalysts/local/files/#{files.version}"
  end

  test "the shipped canvas is 0.6.5 on the react template, the default layout's, and the publish check accepts it" do
    canvas = SeedBundle.local_unit!("tinctures", "canvas")
    assert canvas.type == "tincture"
    assert canvas.ref == "tincture:local.canvas"
    assert canvas.version == "0.6.5"

    # The seed ships it beside the versions before it, which stay as they
    # shipped.
    dir = Path.join(Path.expand("../../../../seed/components", __DIR__), canvas.rel)

    assert dir |> Path.dirname() |> File.ls!() |> Enum.sort() == [
             "0.4.0",
             "0.5.0",
             "0.6.0",
             canvas.version
           ]

    # The default layout's one canvas, with nothing placed over it.
    assert [%{id: "main", tincture: ref, postures: postures}] = Prima.Layout.default().canvases
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

    # It reads the athanor's runs, schedules and schedule runs and how the
    # CYFR stands, names no feed, and declares nothing else: no action and
    # no connect origin.
    assert declaration.actions == []

    assert Enum.map(declaration.streams, &{&1.name, &1.subject}) == [
             {"runs.changes", nil},
             {"schedules.changes", nil},
             {"schedule_runs.changes", nil},
             {"system.changes", nil}
           ]

    assert Compendium.tincture_check_streams(declaration, Sanctum.Catalog.streams()) == :ok
    assert Compendium.tincture_check_desktop(declaration, Sanctum.Catalog.streams()) == :ok

    # It pauses and resumes a schedule, picked from the schedules it reads,
    # runs a failed run again, picked from the runs, keeps each section's on
    # and off in its preferences, and declares the current look in its
    # chrome, read as publish reads it.
    pick = %Prima.Manifest.Tincture.Pick{
      stream: "schedules.changes",
      field: "/schedule_id",
      arg: "schedule_id"
    }

    assert [
             %{id: "pause-schedule", operation: "schedule.pause", args: %{}, pick: ^pick},
             %{id: "resume-schedule", operation: "schedule.resume", args: %{}, pick: ^pick},
             %{id: "retry-run"}
           ] = declaration.desktop.controls

    assert retries?(declaration)

    assert declaration.desktop.prefs == %{
             widgets: Map.new(~w(attention runs apps schedules), &{&1, %{}}),
             desktop: %{
               "hide_aqua_setup" => %{"type" => "boolean"},
               "hide_desktops" => %{"type" => "boolean"}
             }
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

    # Its sources with the lockfile beside its package manifest and its
    # preview picture, and the build's page, its assets, the notices of the
    # packages it bundles and the copy of public/ Vite makes: no build
    # debris.
    files =
      for path <- Prima.Test.SourceTree.files!(Path.join(dir, "**/*")),
          File.regular?(path),
          do: Path.relative_to(path, dir)

    {built, sources} = Enum.split_with(files, &String.starts_with?(&1, "dist/"))

    assert Enum.sort(sources) ==
             ~w(chrome.css cyfr-manifest.json index.html package-lock.json package.json
                public/media/preview-1.svg src/App.tsx src/cyfr.d.ts src/index.css src/main.tsx
                src/model.ts tsconfig.json vite.config.ts)

    assert {[_js], [_css]} =
             built
             |> Enum.filter(&(&1 =~ ~r{\Adist/assets/index-[A-Za-z0-9_-]+\.(js|css)\z}))
             |> Enum.split_with(&String.ends_with?(&1, ".js"))

    assert length(built) == 5
    assert "dist/index.html" in built
    assert "dist/third-party-notices.json" in built
    assert "dist/media/preview-1.svg" in built
  end

  # A desktop's Retry: `execution.retry`, picked from the runs it reads at
  # the run's id, as the guide spells it.
  defp retries?(declaration) do
    pick = %Prima.Manifest.Tincture.Pick{
      stream: "runs.changes",
      field: "/execution_id",
      arg: "execution_id"
    }

    match?(
      [%{id: "retry-run", label: "Retry", operation: "execution.retry", args: %{}, pick: ^pick}],
      Enum.filter(declaration.desktop.controls, &(&1.operation == "execution.retry"))
    )
  end

  # Each shipped desktop: the versions it shipped before, oldest first,
  # and its newest.
  @desktops [
    {"canvas", ~w(0.4.0 0.5.0 0.6.0), "0.6.5"},
    {"line", ~w(0.1.0 0.2.0), "0.3.6"},
    {"night", ~w(0.1.0 0.2.0), "0.3.4"},
    {"road", ~w(0.1.0 0.2.0), "0.3.4"},
    {"street", ~w(0.1.0 0.2.0), "0.3.4"},
    {"switchboard", ~w(0.1.0 0.2.0), "0.3.4"}
  ]
  # The earlier versions that shipped before Retry did.
  @before_retry ~w(0.1.0 0.4.0 0.5.0)

  # A shipped version is immutable: each desktop's earlier versions ship
  # beside its newest as they shipped, each still a desktop the publish
  # check accepts, with Retry only where it shipped with one.
  test "each shipped desktop's earlier versions still ship beside the newest and pass the publish check" do
    components = Path.expand("../../../../seed/components", __DIR__)

    for {name, earlier, now} <- @desktops do
      unit = SeedBundle.local_unit!("tinctures", name)
      assert unit.version == now, name
      versions = Path.join(components, "tinctures/local/#{name}")
      assert versions |> File.ls!() |> Enum.sort() == earlier ++ [now], name

      for before <- earlier do
        dir = Path.join(versions, before)
        manifest = dir |> Path.join("cyfr-manifest.json") |> File.read!() |> Jason.decode!()
        assert manifest["version"] == before, "#{name} #{before}"
        assert Prima.Manifest.validate(manifest, fn _ -> true end) == :ok, "#{name} #{before}"
        assert {:ok, declaration} = Compendium.tincture_declaration(manifest)
        assert Prima.Manifest.Tincture.canvas?(declaration), "#{name} #{before}"
        assert Compendium.tincture_check_desktop(declaration, Sanctum.Catalog.streams()) == :ok

        assert Enum.any?(declaration.desktop.controls, &(&1.operation == "execution.retry")) ==
                 before not in @before_retry,
               "#{name} #{before}"

        assert {:ok, %{size: _}} = Compendium.TinctureValidator.validate(dir)
      end
    end
  end

  # The picker shows a version's previews from public/media/
  # (Compendium.Tincture.media/2): each desktop's newest version carries
  # one, a vector picture that draws itself, with no script, no embedded
  # document and nothing it loads.
  test "each shipped desktop's newest version carries its preview picture" do
    components = Path.expand("../../../../seed/components", __DIR__)

    for {name, _earlier, now} <- @desktops do
      path = Path.join(components, "tinctures/local/#{name}/#{now}/public/media/preview-1.svg")
      assert File.regular?(path), path
      svg = File.read!(path)
      assert byte_size(svg) < 100_000, path
      assert svg =~ ~r/\A<svg [^>]*viewBox="0 0 1600 900"/, path
      refute svg =~ ~r/<script|<foreignObject|<image|\son[a-z]+=|href="(?!#)|url\((?!#)/i, path
    end
  end

  test "the line desktop is 0.3.6 on the vanilla template, and the publish check accepts it" do
    line = SeedBundle.local_unit!("tinctures", "line")
    assert line.ref == "tincture:local.line"
    assert line.version == "0.3.6"
    dir = Path.join(Path.expand("../../../../seed/components", __DIR__), line.rel)

    assert Prima.Manifest.validate(line.manifest, fn _ -> true end) == :ok
    assert {:ok, declaration} = Compendium.tincture_declaration(line.manifest)
    assert Prima.Manifest.Tincture.canvas?(declaration)
    assert Compendium.tincture_entry(line.manifest) == {:ok, "index.html"}
    refute Compendium.tincture_lockfile_required?(line.manifest)

    # What its widgets read, the feeds it names among them, all open at
    # once on the frame's one stream connection.
    assert Enum.map(declaration.streams, &{&1.name, &1.subject}) == [
             {"attention.changes", nil},
             {"runs.changes", nil},
             {"schedules.changes", nil},
             {"schedule_runs.changes", nil},
             {"activity.changes", nil},
             {"threads.changes", nil},
             {"components.changes", nil},
             {"vault.changes", nil},
             {"files.changes", nil},
             {"system.changes", nil},
             {"feed.results", "weather"},
             {"feed.results", "vpn"}
           ]

    assert Compendium.tincture_check_streams(declaration, Sanctum.Catalog.streams()) == :ok
    assert Compendium.tincture_check_desktop(declaration, Sanctum.Catalog.streams()) == :ok

    assert Enum.map(declaration.desktop.controls, & &1.operation) ==
             ~w(schedule.pause schedule.resume execution.retry)

    assert retries?(declaration)

    # Every widget but the queue keeps where it stands and, per screen
    # size, whether it is on.
    assert Map.keys(declaration.desktop.prefs.widgets) |> Enum.sort() ==
             ~w(apps day queue schedules system threads today vault vpn weather)

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
             ~w(app.js chrome.css cyfr-manifest.json fonts/geist-latin.woff2 index.html
                public/media/preview-1.svg style.css)
  end

  test "the shipped night desktop is a vanilla page that reads what it declares and passes the publish check" do
    night = SeedBundle.local_unit!("tinctures", "night")
    assert night.ref == "tincture:local.night"
    dir = Path.join(Path.expand("../../../../seed/components", __DIR__), night.rel)

    assert Prima.Manifest.validate(night.manifest, fn _ -> true end) == :ok
    assert {:ok, declaration} = Compendium.tincture_declaration(night.manifest)
    assert Prima.Manifest.Tincture.canvas?(declaration)

    # The vanilla template's page: index.html, no build and no lockfile.
    assert Compendium.tincture_entry(night.manifest) == {:ok, "index.html"}
    refute Compendium.tincture_lockfile_required?(night.manifest)

    # It reads what waits, the threads, runs, schedules, crew, components,
    # vault, files and how CYFR stands, and two feeds by name; it pauses and
    # resumes the schedules it reads and runs a failed run again.
    assert night.version == "0.3.4"
    assert Compendium.tincture_check_streams(declaration, Sanctum.Catalog.streams()) == :ok
    assert Compendium.tincture_check_desktop(declaration, Sanctum.Catalog.streams()) == :ok
    assert declaration.desktop.feeds == ["weather", "vpn"]

    assert declaration.desktop.data ==
             ~w(attention.changes threads.changes runs.changes schedules.changes activity.changes
                components.changes vault.changes files.changes system.changes)

    assert Enum.map(declaration.desktop.controls, &{&1.id, &1.operation}) == [
             {"pause-schedule", "schedule.pause"},
             {"resume-schedule", "schedule.resume"},
             {"retry-run", "execution.retry"}
           ]

    assert retries?(declaration)

    # Each part of the street is a widget the person turns off or moves.
    assert declaration.desktop.prefs.widgets |> Map.keys() |> Enum.sort() ==
             Enum.sort(~w(threads board weather crew vpn vault cyfr apps files))

    assert {:ok, tokens} =
             Compendium.tincture_check_chrome(declaration, &File.read(Path.join(dir, &1)))

    assert tokens["font"] == "Tilt Neon"
    assert tokens["glyphs"] == "round"

    assert {:ok, %{size: _}} = Compendium.TinctureValidator.validate(dir)

    files =
      for path <- Prima.Test.SourceTree.files!(Path.join(dir, "**/*")),
          File.regular?(path),
          do: {Path.relative_to(path, dir), File.stat!(path).size}

    assert {:ok, _size} = Compendium.Tincture.check_version(night.manifest, files)

    assert files |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
             ~w(chrome.css cyfr-manifest.json fonts/doto-latin.woff2 fonts/tilt-neon-latin.woff2
                index.html model.js public/media/preview-1.svg scene.js shelf.svg street.js
                styles.css)

    # Its page loads its own files alone and reads nothing but its streams.
    for name <- ~w(index.html model.js scene.js street.js styles.css) do
      source = File.read!(Path.join(dir, name))
      refute source =~ ~r{https?://(?!www\.w3\.org/2000/svg)}, name
      refute source =~ ~r/\b(fetch|XMLHttpRequest|WebSocket|localStorage)\b/, name
    end

    for key <- ~w(actions connect streams),
        do: refute(Map.has_key?(night.manifest["tincture"], key), key)

    refute Map.has_key?(night.manifest, "caps")
    refute Map.has_key?(night.manifest, "dependencies")
  end

  test "the road desktop is 0.3.4 on the vanilla template, and the publish check accepts it" do
    road = SeedBundle.local_unit!("tinctures", "road")
    assert road.ref == "tincture:local.road"
    assert road.version == "0.3.4"
    dir = Path.join(Path.expand("../../../../seed/components", __DIR__), road.rel)

    assert Prima.Manifest.validate(road.manifest, fn _ -> true end) == :ok
    assert {:ok, declaration} = Compendium.tincture_declaration(road.manifest)
    assert Prima.Manifest.Tincture.canvas?(declaration)
    assert Compendium.tincture_entry(road.manifest) == {:ok, "index.html"}
    refute Compendium.tincture_lockfile_required?(road.manifest)

    # What its parts read, the two feeds among them, all open at once on the
    # frame's one stream connection.
    assert Enum.map(declaration.streams, &{&1.name, &1.subject}) == [
             {"attention.changes", nil},
             {"schedules.changes", nil},
             {"schedule_runs.changes", nil},
             {"runs.changes", nil},
             {"threads.changes", nil},
             {"activity.changes", nil},
             {"components.changes", nil},
             {"vault.changes", nil},
             {"files.changes", nil},
             {"system.changes", nil},
             {"feed.results", "weather"},
             {"feed.results", "vpn"}
           ]

    assert Compendium.tincture_check_streams(declaration, Sanctum.Catalog.streams()) == :ok
    assert Compendium.tincture_check_desktop(declaration, Sanctum.Catalog.streams()) == :ok

    # It pauses and resumes a schedule, picked from the schedules it reads,
    # and runs a failed firing's run again, picked from the runs.
    pick = %Prima.Manifest.Tincture.Pick{
      stream: "schedules.changes",
      field: "/schedule_id",
      arg: "schedule_id"
    }

    assert [
             %{id: "pause-schedule", operation: "schedule.pause", args: %{}, pick: ^pick},
             %{id: "resume-schedule", operation: "schedule.resume", args: %{}, pick: ^pick},
             %{id: "retry-run"}
           ] = declaration.desktop.controls

    assert retries?(declaration)

    # Every part keeps whether it is on; the street's parts keep their
    # order, and the windmill its unit.
    assert Map.keys(declaration.desktop.prefs.widgets) |> Enum.sort() ==
             ~w(activity attention components files schedules system threads vault vpn weather)

    # Its chrome: both modes' colours, the village's pixel face shipped as
    # WOFF2, its paving and tiles as textures.
    assert {:ok, tokens} =
             Compendium.tincture_check_chrome(declaration, &File.read(Path.join(dir, &1)))

    assert %{
             "radius" => 0,
             "glyphs" => "pixel",
             "font" => "Road Pixel",
             "texture-title" => "azulejo.svg",
             "texture-shelf" => "calcada.svg",
             "light" => %{},
             "dark" => %{}
           } = tokens

    assert [%{"src" => "road-pixel.woff2"}] = tokens["fonts"]
    assert {:ok, %{size: _}} = Compendium.TinctureValidator.validate(dir)

    files =
      for path <- Prima.Test.SourceTree.files!(Path.join(dir, "**/*")),
          File.regular?(path),
          do: Path.relative_to(path, dir)

    assert Enum.sort(files) ==
             ~w(art.js azulejo.svg boot.js calcada.svg chrome.css cyfr-manifest.json font.js
                index.html list.js model.js public/media/preview-1.svg road-pixel.woff2 scene.js)
  end

  test "the switchboard desktop is 0.3.4 on the vanilla template, reads what it declares and passes the publish check" do
    board = SeedBundle.local_unit!("tinctures", "switchboard")
    assert board.ref == "tincture:local.switchboard"
    assert board.version == "0.3.4"
    dir = Path.join(Path.expand("../../../../seed/components", __DIR__), board.rel)

    assert Prima.Manifest.validate(board.manifest, fn _ -> true end) == :ok
    assert {:ok, declaration} = Compendium.tincture_declaration(board.manifest)
    assert Prima.Manifest.Tincture.canvas?(declaration)

    # The vanilla template's page: index.html, no build and no lockfile.
    assert Compendium.tincture_entry(board.manifest) == {:ok, "index.html"}
    refute Compendium.tincture_lockfile_required?(board.manifest)

    # What its parts read, the weather and VPN feeds by name among them,
    # all open at once on the frame's one stream connection.
    assert Enum.map(declaration.streams, &{&1.name, &1.subject}) == [
             {"attention.changes", nil},
             {"threads.changes", nil},
             {"components.changes", nil},
             {"runs.changes", nil},
             {"schedules.changes", nil},
             {"vault.changes", nil},
             {"activity.changes", nil},
             {"files.changes", nil},
             {"system.changes", nil},
             {"feed.results", "weather"},
             {"feed.results", "vpn"}
           ]

    assert Compendium.tincture_check_streams(declaration, Sanctum.Catalog.streams()) == :ok
    assert Compendium.tincture_check_desktop(declaration, Sanctum.Catalog.streams()) == :ok

    # Its levers pause and resume a schedule, picked from the schedules it
    # reads, and its ticket printer runs a failed run again.
    assert Enum.map(declaration.desktop.controls, &{&1.id, &1.operation}) == [
             {"pause-schedule", "schedule.pause"},
             {"resume-schedule", "schedule.resume"},
             {"retry-run", "execution.retry"}
           ]

    assert retries?(declaration)

    # Each part is a widget the person pulls, fits or moves.
    assert declaration.desktop.prefs.widgets |> Map.keys() |> Enum.sort() ==
             ~w(apps calls components crew files runs schedules threads vault vpn weather)

    assert {:ok, tokens} =
             Compendium.tincture_check_chrome(declaration, &File.read(Path.join(dir, &1)))

    assert %{"font" => "Saira Semi Condensed", "glyphs" => "square", "radius" => 4} = tokens
    assert [_font] = tokens["fonts"]
    assert {:ok, %{size: _}} = Compendium.TinctureValidator.validate(dir)

    files =
      for path <- Prima.Test.SourceTree.files!(Path.join(dir, "**/*")),
          File.regular?(path),
          do: Path.relative_to(path, dir)

    assert Enum.sort(files) ==
             ~w(board.js chrome.css cords.js cyfr-manifest.json fonts/doto-800.woff2
                fonts/michroma-400.woff2 fonts/saira-semi-condensed-500.woff2
                fonts/saira-semi-condensed-600.woff2 fonts/saira-semi-condensed-700.woff2
                index.html main.js model.js plain.js public/media/preview-1.svg style.css)

    # Its page loads its own files alone and reads nothing but its streams.
    for name <- ~w(index.html board.js cords.js main.js model.js plain.js style.css) do
      source = File.read!(Path.join(dir, name))
      refute source =~ ~r{https?://(?!www\.w3\.org/2000/svg)}, name
      refute source =~ ~r/\b(fetch|XMLHttpRequest|WebSocket|localStorage)\b/, name
    end

    for key <- ~w(actions connect streams),
        do: refute(Map.has_key?(board.manifest["tincture"], key), key)

    refute Map.has_key?(board.manifest, "caps")
    refute Map.has_key?(board.manifest, "dependencies")
  end

  test "the street desktop is 0.3.4 on the vanilla template, and the publish check accepts it" do
    street = SeedBundle.local_unit!("tinctures", "street")
    assert street.ref == "tincture:local.street"
    assert street.version == "0.3.4"
    dir = Path.join(Path.expand("../../../../seed/components", __DIR__), street.rel)

    assert Prima.Manifest.validate(street.manifest, fn _ -> true end) == :ok
    assert {:ok, declaration} = Compendium.tincture_declaration(street.manifest)
    assert Prima.Manifest.Tincture.canvas?(declaration)
    assert Compendium.tincture_entry(street.manifest) == {:ok, "index.html"}
    refute Compendium.tincture_lockfile_required?(street.manifest)

    # What the street's parts read, the two feeds among them, all open at
    # once on the frame's one stream connection.
    assert Enum.map(declaration.streams, &{&1.name, &1.subject}) == [
             {"attention.changes", nil},
             {"threads.changes", nil},
             {"runs.changes", nil},
             {"schedules.changes", nil},
             {"activity.changes", nil},
             {"files.changes", nil},
             {"components.changes", nil},
             {"vault.changes", nil},
             {"system.changes", nil},
             {"feed.results", "weather"},
             {"feed.results", "vpn"}
           ]

    assert Compendium.tincture_check_streams(declaration, Sanctum.Catalog.streams()) == :ok
    assert Compendium.tincture_check_desktop(declaration, Sanctum.Catalog.streams()) == :ok

    assert Enum.map(declaration.desktop.controls, & &1.operation) ==
             ~w(schedule.pause schedule.resume execution.retry)

    assert retries?(declaration)

    # The parts a person turns off, and the hill's order.
    assert Map.keys(declaration.desktop.prefs.widgets) |> Enum.sort() ==
             ~w(apps castle crew ferry files houses lamps sky stops vault waiting)

    # Its chrome: both modes' colours, the pixel face it ships as WOFF2.
    assert {:ok, tokens} =
             Compendium.tincture_check_chrome(declaration, &File.read(Path.join(dir, &1)))

    assert %{"radius" => 0, "title-height" => 34, "controls" => "right", "glyphs" => "pixel"} =
             tokens

    assert [_font] = tokens["fonts"]

    # The fonts it ships carry their licence in the manifest, since a
    # licence file is no served type.
    assert street.manifest["description"] =~
             "Pixelify Sans and Silkscreen, ship under the SIL Open Font License 1.1"

    assert {:ok, %{size: _}} = Compendium.TinctureValidator.validate(dir)

    files =
      for path <- Prima.Test.SourceTree.files!(Path.join(dir, "**/*")),
          File.regular?(path),
          do: Path.relative_to(path, dir)

    assert Enum.sort(files) ==
             ~w(app.js assets/pixelify.woff2 assets/silkscreen.woff2 chrome.css chrome/shelf.svg
                chrome/title.svg cyfr-manifest.json index.html public/media/icon.svg
                public/media/preview-1.svg style.css)
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

  test "the artisan scroll names an app as a person does, and tells Aqua never to name a tool, an operation or a tincture to them" do
    scroll =
      File.read!(
        Path.expand("../../../../seed/aqua/scrolls/cyfr/skills/artisan/SKILL.md", __DIR__)
      )

    [_, description] = Regex.run(~r/^description: "([^"]*)"$/m, scroll)

    assert description =~ ~r/\bapp\b/
    refute description =~ ~r/tincture/i

    assert scroll =~
             "To the person it is an app: never name a tool, an operation or a tincture to them."

    assert scroll =~
             "**If scaffold fails**, tell the person why in plain words, such as a version " <>
               "that already exists or a name already taken, never as a tool's or an " <>
               "operation's name, and stop"
  end

  test "local_unit! finds a shipped formula by name" do
    formula = SeedBundle.local_unit!("formulas", "list-models")
    assert formula.type == "formula"
    assert formula.ref == "formula:local.list-models"
    assert formula.rel == "formulas/local/list-models/#{formula.version}"
  end
end
