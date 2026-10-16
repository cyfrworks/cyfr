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

  test "each model catalyst's newest version has CYFR attach its key, to its egress hosts" do
    for unit <- SeedBundle.model_chat_units() do
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
  test "each stock catalyst's newest version lets every source class reach its egress, and only that" do
    units = SeedBundle.model_chat_units() ++ [SeedBundle.local_unit!("catalysts", "http")]
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

  test "the shipped canvas is the default layout's, and the rules and the publish check accept it" do
    canvas = SeedBundle.local_unit!("tinctures", "canvas")
    assert canvas.type == "tincture"
    assert canvas.ref == "tincture:local.canvas"

    # The default layout's one canvas, with nothing placed over it.
    assert [%{id: "home", tincture: ref, postures: postures}] = Prima.Layout.default().canvases
    assert ref == canvas.ref
    assert postures == %{}

    assert Prima.Manifest.validate(canvas.manifest, fn _ -> true end) == :ok
    assert {:ok, declaration} = Compendium.tincture_declaration(canvas.manifest)
    assert declaration.frame.placement == "canvas"
    assert declaration.frame.background == false
    assert declaration.frame.capabilities == []
    assert {:ok, "canvas.js"} = Compendium.tincture_canvas_module(canvas.manifest)

    # It reads the athanor's runs, names no feed, and declares nothing
    # else: no action, no connect origin and no page of its own.
    assert declaration.actions == []
    assert [%{name: "runs.changes", subject: nil}] = declaration.streams
    assert Compendium.tincture_check_streams(declaration, Sanctum.Catalog.streams()) == :ok
    assert Compendium.tincture_check_canvas_streams(declaration, Sanctum.Catalog.streams()) == :ok

    for key <- ~w(entry actions connect),
        do: refute(Map.has_key?(canvas.manifest["tincture"], key), key)

    refute Map.has_key?(canvas.manifest, "caps")
    refute Map.has_key?(canvas.manifest, "dependencies")

    dir = Path.join(Path.expand("../../../../seed/components", __DIR__), canvas.rel)

    files =
      for path <- Prima.Test.SourceTree.files!(Path.join(dir, "**/*")),
          File.regular?(path),
          do: {Path.relative_to(path, dir), File.stat!(path).size}

    assert Enum.sort(Enum.map(files, &elem(&1, 0))) == ["canvas.js", "cyfr-manifest.json"]
    assert {:ok, _size} = Compendium.Tincture.check_version(canvas.manifest, files)

    # The module draws only through the toolkit: it reaches no page, no
    # request and no markup of its own.
    module = File.read!(Path.join(dir, "canvas.js"))

    for reach <-
          ~w(document window fetch XMLHttpRequest WebSocket EventSource importScripts innerHTML),
        do: refute(module =~ reach, reach)

    refute module =~ ~r/https?:\/\//
  end

  test "the shipped desktop is gone" do
    seed = Path.expand("../../../../seed/components/tinctures/local", __DIR__)
    refute File.exists?(Path.join(seed, "desktop"))
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
