# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.TinctureTest do
  @moduledoc """
  The tincture rules: which entry a tincture serves, answered to callers
  outside the domain as a typed refusal and inside it as a sentence; the
  one immutable rule map the console and the HTTP adapter read; the
  publish check, a canvas version's included (its module present, no page
  of its own, and only streams a canvas reads); and the connect-domain
  grammar, which is the shared manifest contract's.
  """

  use ExUnit.Case, async: true

  alias Compendium.Tincture

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
      for entry <- ~w(data.db cyfr-manifest.json schema.sql .env ../escape.html /etc/passwd) do
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
      assert {:ok, "index.html"} = Tincture.validate_entry(nil)
      assert {:ok, "index.html"} = Tincture.entry_of(%{})
      assert {:error, "entry must not be a dotfile"} = Tincture.validate_entry(".env")
      assert {:error, "entry must be a relative path"} = Tincture.validate_entry("/etc/passwd")
      assert {:error, "entry must be a string"} = Tincture.validate_entry(7)

      assert {:error,
              "entry must not be a reserved file (data.db, cyfr-manifest.json, schema.sql)"} =
               Tincture.validate_entry("data.db")
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
      assert rules.reserved_files == ["data.db", "cyfr-manifest.json", "schema.sql"]
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
      assert rules.allowed_extensions == Tincture.allowed_extensions()
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

  describe "a canvas version" do
    defp canvas(tincture \\ %{}) do
      %{
        "type" => "tincture",
        "tincture" =>
          Map.merge(
            %{
              "frame" => %{"placement" => "canvas"},
              "canvas" => %{"module" => "canvas.js", "toolkit" => 1}
            },
            tincture
          )
      }
    end

    test "a canvas's entry is the module its canvas block names, held to the same rule" do
      assert {:ok, "canvas.js"} = Tincture.entry_of(canvas())
      assert {:ok, "canvas.js"} = Compendium.tincture_entry(%{manifest: canvas()})

      nested = canvas(%{"canvas" => %{"module" => "lib/canvas.mjs", "toolkit" => 1}})
      assert {:ok, "lib/canvas.mjs"} = Tincture.entry_of(nested)
      assert {:ok, "lib/canvas.mjs"} = Compendium.tincture_entry(nested)

      # The block, not tincture.entry, names a canvas's entry.
      assert {:ok, "canvas.js"} = Tincture.entry_of(canvas(%{"entry" => "index.html"}))

      # A canvas that names no module has no entry, never the default page.
      for block <- [nil, %{"toolkit" => 1}, %{"module" => "", "toolkit" => 1}] do
        manifest = put_in(canvas(), ["tincture", "canvas"], block)

        assert {:error, "a canvas's entry is its module, and it names none"} =
                 Tincture.entry_of(manifest)

        assert {:error, :invalid_entry} = Compendium.tincture_entry(manifest)
      end

      for {module, sentence} <- [
            {"../canvas.js", "entry must not contain '..'"},
            {".canvas.js", "entry must not be a dotfile"}
          ] do
        assert {:error, ^sentence} =
                 Tincture.entry_of(canvas(%{"canvas" => %{"module" => module, "toolkit" => 1}}))
      end

      # Only a canvas reads its block: another placement keeps its entry.
      assert {:ok, "index.html"} =
               Tincture.entry_of(%{
                 "tincture" => %{
                   "frame" => %{"placement" => "float"},
                   "canvas" => %{"module" => "canvas.js", "toolkit" => 1}
                 }
               })
    end

    test "holds a canvas to its module and to no page of its own" do
      assert {:ok, 30} = Tincture.check_version(canvas(), [{"canvas.js", 10}, {"data.json", 20}])

      # The module it names, and no other script, is its module.
      for files <- [[{"other.js", 10}], []] do
        assert {:error, "the canvas's module canvas.js is not among the version's files"} =
                 Tincture.check_version(canvas(), files)
      end

      # A page anywhere in the version, served or not, in any case.
      for page <- ["index.html", "nested/page.htm", "src/preview.HTML", "README.html"] do
        assert {:error, message} = Tincture.check_version(canvas(), [{"canvas.js", 1}, {page, 1}])
        assert message == "#{page} is a page, and a canvas holds none: its host page is CYFR's"
      end

      # A tincture that is no canvas serves its pages as before.
      assert {:ok, 2} = Tincture.check_version(%{}, [{"index.html", 1}, {"a.js", 1}])
    end

    test "holds a canvas to its rules before its files, and to the streams a canvas may read" do
      # The rules come first: a canvas declaring an entry never reaches its files.
      assert {:error, message} =
               Tincture.check_version(canvas(%{"entry" => "index.html"}), [{"index.html", 1}])

      assert message ==
               "tincture.frame.placement canvas: " <>
                 "a canvas's entry is its module, so it declares no tincture.entry"

      assert {:error, message} =
               Tincture.check_version(canvas(%{"actions" => ["execution.list"]}), [
                 {"canvas.js", 1}
               ])

      assert message == "tincture.frame.placement canvas: a canvas declares no system action"

      # A stream every tincture may declare, but none whose declaration
      # carries a shape: a canvas cannot read it.
      shapeless = %{"name" => "mcp_servers.changes"}

      assert {:error, message} =
               Tincture.check_version(canvas(%{"streams" => [shapeless]}), [{"canvas.js", 1}])

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
                 {"canvas.js", 1}
               ])

      assert message =~ "vault.changes, which no provider declares"

      assert {:ok, 1} = Tincture.check_version(canvas(%{"streams" => []}), [{"canvas.js", 1}])
    end
  end

  describe "the connect-domain grammar" do
    test "is the manifest contract's rule, read through the facade" do
      assert Compendium.valid_tincture_connect_domain?("*.supabase.co")
      assert Compendium.valid_tincture_connect_domain?("api.example.com")
      refute Compendium.valid_tincture_connect_domain?("evil.com\n")
      refute Compendium.valid_tincture_connect_domain?("https://x.com")
      refute Compendium.valid_tincture_connect_domain?(nil)
    end
  end
end
