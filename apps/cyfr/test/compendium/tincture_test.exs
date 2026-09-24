# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.TinctureTest do
  @moduledoc """
  The tincture rules: which entry a tincture serves, answered to callers
  outside the domain as a typed refusal and inside it as a sentence; the
  one immutable rule map the console and the HTTP adapter read; and the
  connect-domain grammar, which is the shared manifest contract's.
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

    test "the map is the rules the domain itself reads" do
      rules = Compendium.tincture_asset_rules()

      assert rules.default_icon == Tincture.default_icon()
      assert rules.default_preview == Tincture.default_preview()
      assert rules.preview_count == Tincture.preview_count()
      assert rules.allowed_extensions == Tincture.allowed_extensions()
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
