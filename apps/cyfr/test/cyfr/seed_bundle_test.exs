# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.SeedBundleTest do
  @moduledoc """
  The seed tree is the model-catalyst roster and ships the desktop. Tests
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

  test "local_unit! takes the newest shipped version of a named hand" do
    files = SeedBundle.local_unit!("catalysts", "files")
    refute Prima.Model.speaks_chat?(files.manifest)
    assert files.ref == "catalyst:local.files"
    assert files.rel == "catalysts/local/files/#{files.version}"
  end

  test "the shipped desktop is the default layout's, and the rules and the publish check accept it" do
    desktop = SeedBundle.local_unit!("tinctures", "desktop")
    assert desktop.type == "tincture"
    assert desktop.ref == "tincture:local.desktop"

    for {_posture, arrangement} <- Prima.Layout.default().postures,
        do: assert(arrangement.desktop == desktop.ref)

    assert Prima.Manifest.validate(desktop.manifest, fn _ -> true end) == :ok
    assert {:ok, declaration} = Compendium.tincture_declaration(desktop.manifest)
    assert declaration.frame.placement == "desktop"

    # Arranging, cards and discovery, and nothing that reaches out.
    assert Enum.sort(declaration.actions) ==
             ~w(card.press card.refresh component.list layout.edit layout.get)

    assert [%{name: "cards.refreshed", subject: nil}] = declaration.streams
    assert Compendium.tincture_check_streams(declaration, Grimoire.streams()) == :ok
    refute Map.has_key?(desktop.manifest["tincture"], "connect")
    refute Map.has_key?(desktop.manifest, "caps")

    for operation <- declaration.actions do
      [tool, action] = String.split(operation, ".")
      assert {:ok, {_provider, definition}} = Grimoire.lookup(tool)
      assert Map.has_key?(Grimoire.declared_actions(definition), action), operation
    end

    dir = Path.join(Path.expand("../../../../seed/components", __DIR__), desktop.rel)

    files =
      for path <- Prima.Test.SourceTree.files!(Path.join(dir, "**/*")),
          File.regular?(path),
          do: {Path.relative_to(path, dir), File.stat!(path).size}

    assert {"index.html", _} = List.keyfind(files, "index.html", 0)
    assert {:ok, _size} = Compendium.Tincture.check_version(desktop.manifest, files)
  end

  test "local_unit! finds a shipped formula by name" do
    formula = SeedBundle.local_unit!("formulas", "list-models")
    assert formula.type == "formula"
    assert formula.ref == "formula:local.list-models"
    assert formula.rel == "formulas/local/list-models/#{formula.version}"
  end
end
