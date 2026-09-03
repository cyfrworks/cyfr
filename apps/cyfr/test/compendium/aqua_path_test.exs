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
    assert AquaPath.role_file("scribe") == AquaPath.roles_root() ++ ["scribe.md"]
    assert AquaPath.skill_manifest("pdf") == AquaPath.skill_dir("pdf") ++ ["SKILL.md"]
    assert AquaPath.roles_root() == AquaPath.root() ++ ["roles"]
    assert AquaPath.skills_root() == AquaPath.root() ++ ["skills"]
  end

  test "one router from a name to its file — the soul's name is reserved" do
    assert AquaPath.soul?("aqua")
    refute AquaPath.soul?("aqua_web")
    assert AquaPath.agent_file("aqua") == AquaPath.soul_file()
    assert AquaPath.agent_file("aqua_web") == AquaPath.role_file("aqua_web")
    # A role file named like the soul is not the soul: the router never
    # points at it, so it can only be a stray.
    refute AquaPath.role_file("aqua") == AquaPath.soul_file()
  end

  test "locate/1 speaks the unit grammars — the soul and roles are files, skills are dirs" do
    assert AquaPath.locate(AquaPath.soul_file()) == {:file, AquaPath.soul_file()}
    assert AquaPath.locate(AquaPath.role_file("x")) == {:file, AquaPath.role_file("x")}

    assert AquaPath.locate(AquaPath.skill_manifest("pdf")) ==
             {:dir, AquaPath.skill_dir("pdf"), AquaPath.skill_manifest_name()}

    assert AquaPath.locate(AquaPath.skill_dir("pdf") ++ ["helpers", "fill.md"]) ==
             {:dir, AquaPath.skill_dir("pdf"), AquaPath.skill_manifest_name()}

    assert AquaPath.locate(AquaPath.root()) == :above_unit
    assert AquaPath.locate(AquaPath.roles_root()) == :above_unit
    assert AquaPath.locate(AquaPath.skills_root()) == :above_unit
  end

  test "an older tree's agents/ files are units for deletion only" do
    # `reset all` can drop a stale shadow left under the old directory;
    # nothing else reads there.
    assert AquaPath.locate(["aqua", "agents", "old.md"]) == {:file, ["aqua", "agents", "old.md"]}
    assert AquaPath.locate(["aqua", "agents"]) == :above_unit
  end

  test "only the grammar mints a unit — junk names and non-.md files stay plain storage" do
    assert AquaPath.locate(AquaPath.roles_root() ++ ["notes.txt"]) == :above_unit
    assert AquaPath.locate(AquaPath.roles_root() ++ ["bad name.md"]) == :above_unit
    assert AquaPath.locate(AquaPath.roles_root() ++ [".md"]) == :above_unit
    assert AquaPath.locate(AquaPath.skills_root() ++ ["bad name", "SKILL.md"]) == :above_unit

    refute AquaPath.valid_name?("../escape")
    refute AquaPath.valid_name?("")
    refute AquaPath.valid_name?(nil)
  end
end
