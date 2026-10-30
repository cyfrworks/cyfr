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
  nothing; and the connect-domain grammar, which is the shared manifest
  contract's.
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
      manifest = %{"tincture" => %{"frame" => %{"placement" => "sideways"}}}
      assert {:error, message} = Tincture.check_version(manifest, [{"index.html", 1}])
      assert message =~ "placement"

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
               Tincture.check_version(streams.([%{"name" => "vault.changes"}]), files)

      assert message =~ "vault.changes, which no provider declares"

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
        "tincture" =>
          Map.merge(%{"frame" => %{"placement" => "canvas"}, "entry" => "index.html"}, tincture)
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
                "tincture.frame.placement canvas: its page index.html is not among the " <>
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
              "tincture.frame.placement canvas: its page dist/index.html is not among the " <>
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

      assert message =~ "tincture.frame.placement canvas: a canvas declares tincture.entry"

      assert {:error, message} =
               Tincture.check_version(canvas(%{"actions" => ["execution.list"]}), [
                 {"index.html", 1}
               ])

      assert message == "tincture.frame.placement canvas: a canvas declares no system action"

      # A stream every tincture may declare, but none whose declaration
      # carries a shape: a canvas cannot read it.
      shapeless = %{"name" => "mcp_servers.changes"}

      assert {:error, message} =
               Tincture.check_version(canvas(%{"streams" => [shapeless]}), [{"index.html", 1}])

      assert message ==
               "tincture.frame.placement canvas: tincture.streams names mcp_servers.changes, " <>
                 "which a canvas cannot read: the stream declares no shape"

      # The same stream on a tincture that is no canvas is admitted.
      assert {:ok, 1} =
               Tincture.check_version(%{"tincture" => %{"streams" => [shapeless]}}, [
                 {"index.html", 1}
               ])

      # Which streams exist is still the providers' to say.
      assert {:error, message} =
               Tincture.check_version(canvas(%{"streams" => [%{"name" => "vault.changes"}]}), [
                 {"index.html", 1}
               ])

      assert message =~ "vault.changes, which no provider declares"

      assert {:ok, 1} = Tincture.check_version(canvas(%{"streams" => []}), [{"index.html", 1}])
    end
  end
end
