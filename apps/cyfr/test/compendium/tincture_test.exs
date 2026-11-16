# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.TinctureTest do
  @moduledoc """
  The tincture rules: which entry a tincture serves, answered to callers
  outside the domain as a typed refusal and inside it as a sentence; the
  one immutable rule map the console and the HTTP adapter read; the
  publish check, a canvas version's included (its page among its files,
  a react canvas's once its build is, and only streams a canvas reads),
  and a stream that declares
  a shape refused at the registry in any other tincture, which registers
  nothing; the connect-domain grammar, which is the shared manifest
  contract's; the head a plain page is given before the SDK and the
  `<base>`, and a tincture version's files as the endpoint reads them,
  its entry never given one.
  """

  # The registry's case points the storage root at a directory of its own
  # and restores it when the case ends.
  use ExUnit.Case, async: false

  alias Compendium.{ComponentPath, Registry, Tincture}

  describe "the entry, through the facade" do
    test "is the manifest's tincture.entry when valid, from a row or a manifest" do
      manifest = %{"tincture" => %{"entry" => "app.html"}}

      assert {:ok, "app.html"} = Compendium.tincture_entry(%{manifest: manifest})
      assert {:ok, "app.html"} = Compendium.tincture_entry(manifest)
    end

    test "defaults to index.html when the manifest names none" do
      assert {:ok, "index.html"} = Compendium.tincture_entry(%{manifest: %{}})
      assert {:ok, "index.html"} = Compendium.tincture_entry(%{"tincture" => %{"entry" => ""}})
    end

    test "refuses reserved files, dotfiles, traversal and absolute paths as invalid" do
      for entry <- ~w(cyfr-manifest.json .env ../escape.html /etc/passwd) do
        tincture = %{manifest: %{"tincture" => %{"entry" => entry}}}
        assert {:error, :invalid_entry} = Compendium.tincture_entry(tincture), entry
      end

      assert {:error, :invalid_entry} =
               Compendium.tincture_entry(%{"tincture" => %{"entry" => 7}})
    end

    test "a row with no manifest has no entry" do
      assert {:error, :no_entry} = Compendium.tincture_entry(%{manifest: nil})
      assert {:error, :no_entry} = Compendium.tincture_entry(nil)
    end
  end

  describe "the entry, inside the domain" do
    test "keeps its sentences for the validators" do
      entry = &Tincture.entry_of(%{"tincture" => %{"entry" => &1}})

      assert {:ok, "index.html"} = entry.(nil)
      assert {:ok, "index.html"} = Tincture.entry_of(%{})
      assert {:error, "entry must not be a dotfile"} = entry.(".env")
      assert {:error, "entry must be a relative path"} = entry.("/etc/passwd")
      assert {:error, "entry must be a string"} = entry.(7)

      assert {:error, "entry must not be a reserved file (cyfr-manifest.json)"} =
               entry.("cyfr-manifest.json")
    end
  end

  describe "the asset rules" do
    test "are one map of the nine rules" do
      rules = Compendium.tincture_asset_rules()

      assert rules |> Map.keys() |> Enum.sort() ==
               Enum.sort(~w(
                 default_entry media_dir default_icon default_preview preview_count
                 image_extensions blocked_raster_extensions allowed_extensions reserved_files
               )a)

      assert rules.default_entry == "index.html"
      assert rules.media_dir == ["public", "media"]
      assert rules.default_icon == ["public", "media", "icon.svg"]
      assert rules.default_preview == ["public", "media", "preview-1.svg"]
      assert rules.preview_count == 6
      assert rules.reserved_files == ["cyfr-manifest.json"]
      assert rules.blocked_raster_extensions == ~w(.png .jpg .jpeg .gif .webp)
    end

    test "a console image is one the serve gate would serve, vector or raster" do
      rules = Compendium.tincture_asset_rules()

      assert rules.image_extensions == ~w(.svg .png .jpg .jpeg .gif)
      assert Enum.all?(rules.image_extensions, &(&1 in rules.allowed_extensions))

      # `.webp` is blocked from discovery and absent from the serve gate.
      refute ".webp" in rules.allowed_extensions
      refute ".webp" in rules.image_extensions
    end

    test "an asset may have exactly the extensions of the frame's served types" do
      assert Compendium.tincture_asset_rules().allowed_extensions ==
               Compendium.tincture_served_types() |> Map.keys() |> Enum.sort()

      assert Compendium.tincture_served_types() == Compendium.Tincture.Rules.served_types()
    end

    test "the map is the rules the domain itself reads" do
      rules = Compendium.tincture_asset_rules()

      assert rules.default_icon == Tincture.default_icon()
      assert rules.default_preview == Tincture.default_preview()
      assert rules.preview_count == Tincture.preview_count()
    end
  end

  describe "a page's head" do
    @base "/t/@home/local/page/"
    @nonce "n0nce"

    # The tags as the endpoint's entry page carries them.
    defp injected,
      do:
        "\n<base href=\"#{@base}\">\n<script nonce=\"#{@nonce}\">#{Compendium.tincture_sdk()}</script>"

    test "a plain entry given a head gets the SDK and the <base>, with a head of its own, a body alone or no tag at all" do
      for document <- [
            "<html><head><title>Mine</title></head><body>x</body></html>",
            "<body>only a body</body>",
            "no tags at all"
          ] do
        handed = Compendium.tincture_head_tags(Compendium.plain_entry(document), @base, @nonce)

        # The tags follow the head put first, and the document is whole after it.
        assert handed == "<!doctype html><head>" <> injected() <> "</head>" <> document, document
        assert [_once] = :binary.matches(handed, Compendium.tincture_sdk())
      end
    end

    test "without a head given first, a body alone or no tag at all gets neither" do
      for document <- ["<body>only a body</body>", "no tags at all"],
          do: assert(Compendium.tincture_head_tags(document, @base, @nonce) == document)
    end
  end

  describe "a tincture version's files" do
    setup tags do
      Cyfr.Test.Sandbox.setup!(tags)

      base = Path.join(System.tmp_dir!(), "tincture_files_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(base) end)
      Prima.Test.Env.put_app_env(:arca, :base_path, base)

      {:ok, ctx: Sanctum.TestContext.local()}
    end

    @bound %{files: 10, bytes: 1_000}

    # A local tincture version of `files`, laid and registered as a
    # publish would: its unit.
    defp version!(ctx, name, files) do
      manifest = %{
        "name" => name,
        "type" => "tincture",
        "version" => "1.0.0",
        "publisher" => "local",
        "tincture" => %{}
      }

      unit =
        Arca.Test.UnitFixtures.tenant_component!(ctx, "tincture", "local", name, "1.0.0",
          manifest: manifest,
          files: files
        )

      {:ok, _registered} = Registry.register_from_arca(ctx, unit)
      unit
    end

    test "are read as the endpoint reads them, the entry as it was written, never given a head",
         %{ctx: ctx} do
      entry = "<p>no head of its own</p>"
      version!(ctx, "plain", [{"index.html", entry}, {"app.js", "1"}, {"src/notes.txt", "n"}])

      assert {:ok, %{name: "plain", entry: "index.html", files: files}} =
               Compendium.tincture_files(ctx, "tincture:local.plain:1.0.0", @bound)

      assert files == [
               %{path: "app.js", type: "text/javascript", bytes: "1"},
               %{path: "index.html", type: "text/html", bytes: entry}
             ]

      refute Enum.any?(files, &String.starts_with?(&1.bytes, Compendium.plain_entry("")))
    end

    test "past the bound in files or bytes are refused before one of them is read",
         %{ctx: ctx} do
      unit =
        version!(ctx, "sized", [{"index.html", "<p>12345</p>"}, {"a.js", "1234"}, {"b.js", "12"}])

      reads = fn bound ->
        {answer, calls} =
          traced([{Arca, :get, 2}], fn ->
            Compendium.tincture_files(ctx, "tincture:local.sized:1.0.0", bound)
          end)

        {answer,
         for(
           [_actor, path] <- args_of(calls, {Arca, :get, 2}),
           List.starts_with?(path, unit),
           do: Enum.drop(path, length(unit))
         )}
      end

      # The served files are 18 bytes in three files; the manifest is none of them.
      assert {{:error, :over_bound}, []} = reads.(%{files: 2, bytes: 1_000})
      assert {{:error, :over_bound}, []} = reads.(%{files: 3, bytes: 17})

      # At the bound every served file is read, once each.
      assert {{:ok, %{files: [_, _, _]}}, read} = reads.(%{files: 3, bytes: 18})
      assert Enum.sort(read) == [["a.js"], ["b.js"], ["index.html"]]
    end
  end

  # `fun`'s answer, and the calls this process made to `mfas` while it ran,
  # in order. A process's call trace is not delivered to itself, so a
  # collector takes it; every trace message is delivered before the
  # collector is asked for what it holds.
  defp traced(mfas, fun) do
    test = self()
    collector = spawn_link(fn -> collect(test, []) end)

    on_exit(fn -> for mfa <- mfas, do: :erlang.trace_pattern(mfa, false, [:global]) end)

    for {module, _function, _arity} = mfa <- mfas do
      Code.ensure_loaded!(module)
      assert :erlang.trace_pattern(mfa, true, [:global]) == 1
    end

    :erlang.trace(test, true, [:call, {:tracer, collector}])

    answer =
      try do
        fun.()
      after
        :erlang.trace(test, false, [:call])
      end

    delivered = :erlang.trace_delivered(test)
    assert_receive {:trace_delivered, ^test, ^delivered}, 5_000
    send(collector, {:done, delivered})
    assert_receive {:collected, ^delivered, calls}, 5_000
    {answer, calls}
  end

  defp collect(test, calls) do
    receive do
      {:trace, ^test, :call, call} -> collect(test, [call | calls])
      {:done, ref} -> send(test, {:collected, ref, Enum.reverse(calls)})
    end
  end

  defp args_of(calls, {module, function, _arity}),
    do: for({^module, ^function, args} <- calls, do: args)

  describe "the publish check" do
    test "states the version's size, and names the first file of another type" do
      assert {:ok, 30} = Tincture.check_version(%{}, [{"index.html", 10}, {"a.js", 20}])

      assert {:error, message} =
               Tincture.check_version(%{}, [
                 {"index.html", 1},
                 {"z.exe", 1},
                 {"b.php", 1}
               ])

      assert message =~ "b.php is not a type a tincture serves (and 1 more)"
    end

    test "holds the declaration to the frame's rules" do
      manifest = %{"tincture" => %{"frame" => %{"placement" => "canvas"}}}
      assert {:error, message} = Tincture.check_version(manifest, [{"index.html", 1}])
      assert message == "tincture.frame declares unknown key(s): placement"

      declared = %{"tincture" => %{"frame" => %{"capabilities" => ["fullscreen", "gamepad"]}}}
      assert {:ok, 1} = Tincture.check_version(declared, [{"index.html", 1}])
    end

    test "holds the declared streams to the providers' declarations" do
      streams = fn streams -> %{"tincture" => %{"streams" => streams}} end
      files = [{"index.html", 1}]

      assert {:ok, 1} =
               Tincture.check_version(
                 streams.([
                   %{"name" => "confirmation.changes"},
                   %{"name" => "mcp_servers.changes"}
                 ]),
                 files
               )

      # A stream no provider offers.
      assert {:error, message} =
               Tincture.check_version(streams.([%{"name" => "vault.entries"}]), files)

      assert message =~ "vault.entries, which no provider declares"

      # A subject the stream does not take: none for a stream bound to its
      # holder, none for a stream that takes no subject.
      for {name, subject} <- [
            {"confirmation.changes", "usr_someone"},
            {"mcp_servers.changes", "x"}
          ] do
        assert {:error, message} =
                 Tincture.check_version(
                   streams.([%{"name" => name, "subject" => subject}]),
                   files
                 )

        assert message =~ "#{name}: the stream does not take that subject"
      end
    end
  end

  describe "the publish check at the registry" do
    setup tags do
      Cyfr.Test.Sandbox.setup!(tags)

      base =
        Path.join(System.tmp_dir!(), "tincture_publish_#{System.unique_integer([:positive])}")

      prev_base = Application.fetch_env!(:arca, :base_path)
      Application.put_env(:arca, :base_path, base)

      on_exit(fn ->
        Application.put_env(:arca, :base_path, prev_base)
        File.rm_rf!(base)
      end)

      {:ok, ctx: Sanctum.TestContext.local()}
    end

    # An app's version laid in the athanor's tree, declaring `streams`;
    # answers the unit the registry registers.
    defp app!(ctx, name, streams) do
      manifest = %{
        "name" => name,
        "type" => "tincture",
        "version" => "1.0.0",
        "publisher" => "local",
        "tincture" => %{"frame" => %{"capabilities" => ["pointer_lock"]}, "streams" => streams}
      }

      Arca.Test.UnitFixtures.tenant_component!(ctx, "tincture", "local", name, "1.0.0",
        manifest: manifest,
        files: [{"index.html", "<!doctype html><title>#{name}</title>"}]
      )

      ComponentPath.version_dir("tincture", "local", name, "1.0.0")
    end

    test "refuses an app declaring feed.results, and registers nothing", %{
      ctx: ctx
    } do
      unit = app!(ctx, "app-feeds", [%{"name" => "feed.results", "subject" => "btc"}])

      assert {:error, reason} = Registry.register_from_arca(ctx, unit)
      assert inspect(reason) =~ "feed.results, which declares a shape"
      assert {:error, :not_found} = Registry.get(ctx, "app-feeds", "1.0.0", "local", "tincture")

      # The same tincture opening a stream that declares no shape registers.
      unit = app!(ctx, "app-servers", [%{"name" => "mcp_servers.changes"}])
      assert {:ok, %{name: "app-servers"}} = Registry.register_from_arca(ctx, unit)
    end
  end

  describe "a canvas version" do
    @react %{"entry" => "dist/index.html", "build" => %{"tool" => "vite"}}

    defp canvas(tincture \\ %{}) do
      %{
        "type" => "tincture",
        "name" => "home",
        "version" => "0.2.0",
        "tincture" => Map.merge(%{"desktop" => %{}, "entry" => "index.html"}, tincture)
      }
    end

    test "a canvas's entry is its tincture.entry, held to the rule every entry is" do
      assert {:ok, "index.html"} = Tincture.entry_of(canvas())
      assert {:ok, "index.html"} = Compendium.tincture_entry(%{manifest: canvas()})
      assert {:ok, "dist/index.html"} = Tincture.entry_of(canvas(@react))
      assert {:ok, "dist/index.html"} = Compendium.tincture_entry(canvas(@react))

      assert {:error, "entry must not contain '..'"} =
               Tincture.entry_of(canvas(%{"entry" => "../index.html"}))
    end

    test "holds a canvas to its page among its files, and no other page to anything" do
      assert {:ok, 30} =
               Tincture.check_version(canvas(), [{"index.html", 10}, {"app.js", 20}])

      # Another page of the version is no refusal: only the entry is ever a
      # page, and the rest are served as no page.
      assert {:ok, 3} =
               Tincture.check_version(canvas(), [
                 {"index.html", 1},
                 {"about.html", 1},
                 {"app.js", 1}
               ])

      for files <- [[{"app.js", 10}], [{"dist/index.html", 1}], []] do
        assert {:error,
                "tincture.desktop: its page index.html is not among the " <>
                  "version's files"} = Tincture.check_version(canvas(), files)
      end

      # A tincture that is no canvas serves its pages as before.
      assert {:ok, 2} = Tincture.check_version(%{}, [{"index.html", 1}, {"a.js", 1}])
    end

    test "holds a react canvas's page as every built tincture's entry: there once its build is" do
      sources = [
        {"index.html", 1},
        {"src/main.tsx", 1},
        {"package.json", 1},
        {"package-lock.json", 1}
      ]

      assert {:error,
              "tincture.desktop: its page dist/index.html is not among the " <>
                "version's files"} = Tincture.check_version(canvas(@react), sources)

      built = sources ++ [{"dist/index.html", 1}, {"dist/assets/index-abc.js", 1}]
      assert {:ok, 6} = Tincture.check_version(canvas(@react), built)

      # The validator publish runs holds the entry first, as it holds any
      # tincture's, and the lockfile beside its package manifest.
      pairs = fn files, manifest ->
        [
          {[ComponentPath.manifest_name()], Jason.encode!(manifest)}
          | Enum.map(files, fn {path, _bytes} -> {String.split(path, "/"), "x"} end)
        ]
      end

      assert {:error, "entry file 'dist/index.html' not found"} =
               Compendium.TinctureValidator.validate_from_pairs(pairs.(sources, canvas(@react)))

      assert {:ok, %{digest: _}} =
               Compendium.TinctureValidator.validate_from_pairs(pairs.(built, canvas(@react)))

      assert {:error, "package.json ships without package-lock.json" <> _} =
               Compendium.TinctureValidator.validate_from_pairs(
                 pairs.(List.keydelete(built, "package-lock.json", 0), canvas(@react))
               )
    end

    test "holds a canvas to its rules before its files, and to the streams a canvas may read" do
      # The rules come first: a canvas off its templates never reaches its files.
      assert {:error, message} =
               Tincture.check_version(canvas(%{"entry" => "canvas.js"}), [{"canvas.js", 1}])

      assert message =~ "tincture.desktop: a desktop declares tincture.entry"

      assert {:error, message} =
               Tincture.check_version(canvas(%{"actions" => ["execution.list"]}), [
                 {"index.html", 1}
               ])

      assert message == "tincture.desktop: a desktop declares no system action"

      # A stream every tincture may declare, but none whose declaration
      # carries a shape: a canvas cannot read it.
      shapeless = %{"name" => "mcp_servers.changes"}

      assert {:error, message} =
               Tincture.check_version(
                 canvas(%{"desktop" => %{"data" => ["mcp_servers.changes"]}}),
                 [{"index.html", 1}]
               )

      assert message ==
               "tincture.desktop.data names mcp_servers.changes, " <>
                 "which a desktop cannot read: the stream declares no shape"

      # A control the person approves first is admitted at publish; one
      # publish refuses still is, naming why.
      control = fn operation ->
        canvas(%{
          "desktop" => %{
            "controls" => [%{"id" => "go", "label" => "Go", "operation" => operation}]
          }
        })
      end

      assert {:ok, 1} = Tincture.check_version(control.("schedule.create"), [{"index.html", 1}])

      assert {:error, message} =
               Tincture.check_version(control.("profile.commit"), [{"index.html", 1}])

      assert message =~
               "tincture.desktop.controls go runs profile.commit, a step of a grant's consent walk"

      # The same stream on a tincture that is no canvas is admitted.
      assert {:ok, 1} =
               Tincture.check_version(%{"tincture" => %{"streams" => [shapeless]}}, [
                 {"index.html", 1}
               ])

      # Which streams exist is still the providers' to say.
      assert {:error, message} =
               Tincture.check_version(canvas(%{"desktop" => %{"data" => ["vault.entries"]}}), [
                 {"index.html", 1}
               ])

      assert message =~ "vault.entries, which no provider declares"

      assert {:ok, 1} = Tincture.check_version(canvas(), [{"index.html", 1}])

      # A desktop that also lists streams is refused.
      assert {:error, message} =
               Tincture.check_version(canvas(%{"streams" => []}), [{"index.html", 1}])

      assert message =~ "a tincture.desktop lists no tincture.streams"
    end

    test "holds a desktop's chrome at publish, through either entry point, and installs nothing it refuses" do
      chrome = fn css ->
        [
          {[ComponentPath.manifest_name()],
           Jason.encode!(canvas(%{"desktop" => %{"chrome" => "chrome.css"}}))},
          {["index.html"], "<html></html>"},
          {["chrome.css"], css}
        ]
      end

      assert {:ok, %{digest: _}} =
               Compendium.TinctureValidator.validate_from_pairs(
                 chrome.(":root { --chrome-edge: 8px; }")
               )

      assert {:error,
              "tincture.desktop.chrome chrome.css line 2: !important is not part of the chrome grammar"} =
               Compendium.TinctureValidator.validate_from_pairs(
                 chrome.(":root {\n  --chrome-edge: 8px !important;\n}")
               )

      assert {:error, "tincture.desktop.chrome chrome.css is not among the version's files"} =
               Compendium.TinctureValidator.validate_from_pairs(Enum.drop(chrome.(""), -1))

      # The directory entry point reads the version's files as the pairs do.
      dir = Path.join(System.tmp_dir!(), "chrome-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      for {[path], bytes} <- chrome.(":root { color: red; }"),
          do: File.write!(Path.join(dir, path), bytes)

      assert {:error,
              "tincture.desktop.chrome chrome.css line 1: \"color\" is not a property" <> _} =
               Compendium.TinctureValidator.validate(dir)

      File.write!(Path.join(dir, "chrome.css"), ":root { --chrome-edge: 8px; }")
      assert {:ok, %{digest: _}} = Compendium.TinctureValidator.validate(dir)
    end

    # Review of A1, finding 4: ruled that a font needs no licence file
    # beside it; the guide states the author's duty.
    test "a WOFF2 within its cap publishes without a licence file" do
      css = ~s|@font-face { font-family: "Inter"; src: url("fonts/inter.woff2"); }|

      pairs = [
        {[ComponentPath.manifest_name()],
         Jason.encode!(canvas(%{"desktop" => %{"chrome" => "chrome.css"}}))},
        {["index.html"], "<html></html>"},
        {["chrome.css"], css},
        {["fonts", "inter.woff2"], "wOF2" <> :binary.copy(<<0>>, 524_284)}
      ]

      assert {:ok, %{digest: _}} = Compendium.TinctureValidator.validate_from_pairs(pairs)
    end
  end
end
