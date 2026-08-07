# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ToolPatternTest do
  use ExUnit.Case, async: true

  alias Sanctum.ToolPattern

  describe "matches?/2" do
    test "wildcard matches everything" do
      assert ToolPattern.matches?("*", "component.get")
      assert ToolPattern.matches?("*", "anything")
      assert ToolPattern.matches?("*", "")
    end

    test "exact names match only themselves" do
      assert ToolPattern.matches?("repo_get", "repo_get")
      refute ToolPattern.matches?("repo_get", "repo_get_extra")
      refute ToolPattern.matches?("repo_get", "repo")
    end

    test "prefix.* matches on the dot boundary only" do
      assert ToolPattern.matches?("component.*", "component.get")
      assert ToolPattern.matches?("component.*", "component.push")
      refute ToolPattern.matches?("component.*", "component")
      refute ToolPattern.matches?("component.*", "componentx.get")
    end

    test "a bare prefix* is not a pattern — substring matching is the hazard" do
      refute ToolPattern.matches?("read*", "readwrite_danger")
      refute ToolPattern.matches?("read*", "read")
      refute ToolPattern.matches?("issues_*", "issues_list")
    end

    test "other * placements match nothing" do
      refute ToolPattern.matches?("a*b", "axb")
      refute ToolPattern.matches?("*.get", "component.get")
      refute ToolPattern.matches?("a.*.b", "a.x.b")
    end
  end

  describe "valid?/1" do
    test "accepts the grammar" do
      assert ToolPattern.valid?("*")
      assert ToolPattern.valid?("component.get")
      assert ToolPattern.valid?("repo_get")
      assert ToolPattern.valid?("component.*")
      assert ToolPattern.valid?("a.b.*")
    end

    test "rejects everything else" do
      refute ToolPattern.valid?("")
      refute ToolPattern.valid?(".*")
      refute ToolPattern.valid?("read*")
      refute ToolPattern.valid?("a*b")
      refute ToolPattern.valid?("*.get")
      refute ToolPattern.valid?("a.*.b")
      refute ToolPattern.valid?("**")
      refute ToolPattern.valid?(nil)
      refute ToolPattern.valid?(:atom)
    end
  end

  describe "expand/2" do
    @catalog ~w(component.get component.push execution.run storage.read)

    test "wildcard takes the whole catalog, sorted" do
      assert ToolPattern.expand(["*"], @catalog) == Enum.sort(@catalog)
    end

    test "prefix.* takes its dot-boundary matches" do
      assert ToolPattern.expand(["component.*"], @catalog) ==
               ["component.get", "component.push"]
    end

    test "exact names must exist in the catalog" do
      assert ToolPattern.expand(["execution.run", "phantom.action"], @catalog) ==
               ["execution.run"]
    end

    test "invalid and stale patterns expand to nothing" do
      assert ToolPattern.expand(["component*", "read*", ""], @catalog) == []
    end

    test "overlapping patterns dedupe" do
      assert ToolPattern.expand(["component.*", "component.get", "*"], @catalog) ==
               Enum.sort(@catalog)
    end
  end
end
