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
    assert AquaPath.agent_file("scribe") == AquaPath.agents_root() ++ ["scribe.md"]
    assert AquaPath.skill_manifest("pdf") == AquaPath.skill_dir("pdf") ++ ["SKILL.md"]
    assert AquaPath.agents_root() == AquaPath.root() ++ ["agents"]
    assert AquaPath.skills_root() == AquaPath.root() ++ ["skills"]
  end

  test "locate/1 speaks the two unit grammars — agents are files, skills are dirs" do
    assert AquaPath.locate(AquaPath.agent_file("x")) == {:file, AquaPath.agent_file("x")}

    assert AquaPath.locate(AquaPath.skill_manifest("pdf")) ==
             {:dir, AquaPath.skill_dir("pdf"), AquaPath.skill_manifest_name()}

    assert AquaPath.locate(AquaPath.skill_dir("pdf") ++ ["helpers", "fill.md"]) ==
             {:dir, AquaPath.skill_dir("pdf"), AquaPath.skill_manifest_name()}

    assert AquaPath.locate(AquaPath.root()) == :above_unit
    assert AquaPath.locate(AquaPath.agents_root()) == :above_unit
    assert AquaPath.locate(AquaPath.skills_root()) == :above_unit
  end
end
