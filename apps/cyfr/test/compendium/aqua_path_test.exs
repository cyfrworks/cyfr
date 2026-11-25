# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AquaPathTest do
  use ExUnit.Case, async: true

  alias Compendium.AquaPath

  doctest Compendium.AquaPath

  test "the root names a tenant scope — the layout table and this module agree" do
    assert hd(AquaPath.root()) in Arca.Storage.tenant_roots()
  end

  test "paths compose from the root" do
    assert AquaPath.soul_file() == AquaPath.root() ++ ["aqua.md"]
    assert AquaPath.crew_file("scribe") == AquaPath.crew_root() ++ ["scribe.md"]

    assert AquaPath.scroll_manifest("mine", "pdf") ==
             AquaPath.scroll_dir("mine", "pdf") ++ ["SKILL.md"]

    assert AquaPath.scroll_dir("mine", "pdf") == AquaPath.pack_dir("mine") ++ ["skills", "pdf"]
    assert AquaPath.crew_root() == AquaPath.root() ++ ["crew"]
    assert AquaPath.scrolls_root() == AquaPath.root() ++ ["scrolls"]
    assert AquaPath.pack_dir("mine") == AquaPath.scrolls_root() ++ ["mine"]
  end

  test "one router from a name to its file — the soul's name is reserved" do
    assert AquaPath.soul?("aqua")
    refute AquaPath.soul?("web")
    assert AquaPath.agent_file("aqua") == AquaPath.soul_file()
    assert AquaPath.agent_file("web") == AquaPath.crew_file("web")
    # A crew file named like the soul is not the soul: the router never
    # points at it, so it can only be a stray.
    refute AquaPath.crew_file("aqua") == AquaPath.soul_file()
  end

  test "locate/1 speaks the unit grammars — the soul and the crew are files, a pack is a dir" do
    assert AquaPath.locate(AquaPath.soul_file()) == {:file, AquaPath.soul_file()}
    assert AquaPath.locate(AquaPath.crew_file("x")) == {:file, AquaPath.crew_file("x")}

    assert AquaPath.locate(AquaPath.scroll_manifest("mine", "pdf")) ==
             {:dir, AquaPath.pack_dir("mine"), AquaPath.record_name()}

    assert AquaPath.locate(AquaPath.pack_dir("mine") ++ [".claude-plugin", "plugin.json"]) ==
             {:dir, AquaPath.pack_dir("mine"), AquaPath.record_name()}

    assert AquaPath.commits_whole?(AquaPath.pack_dir("mine"))
    refute AquaPath.commits_whole?(AquaPath.crew_file("x"))

    assert AquaPath.locate(AquaPath.root()) == :above_unit
    assert AquaPath.locate(AquaPath.crew_root()) == :above_unit
    assert AquaPath.locate(AquaPath.scrolls_root()) == :above_unit
    # The layout before packs is plain storage now.
    assert AquaPath.locate(["aqua", "skills", "pdf", "SKILL.md"]) == :above_unit
  end

  test "a file outside the soul, the crew and the scrolls is plain storage" do
    assert AquaPath.locate(["aqua", "drafts", "old.md"]) == :above_unit
    # The roles are gone: their old folder is plain storage.
    assert AquaPath.locate(["aqua", "roles", "builder.md"]) == :above_unit
    assert AquaPath.locate(["aqua", "drafts"]) == :above_unit
  end

  test "only the grammar mints a unit — junk names and non-.md files stay plain storage" do
    assert AquaPath.locate(AquaPath.crew_root() ++ ["notes.txt"]) == :above_unit
    assert AquaPath.locate(AquaPath.crew_root() ++ ["bad name.md"]) == :above_unit
    assert AquaPath.locate(AquaPath.crew_root() ++ [".md"]) == :above_unit
    assert AquaPath.locate(AquaPath.scrolls_root() ++ ["bad name", "SKILL.md"]) == :above_unit

    refute AquaPath.valid_name?("../escape")
    refute AquaPath.valid_name?("")
    refute AquaPath.valid_name?(nil)
  end
end
