# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.SeedPacksTest do
  @moduledoc """
  What the seed ships of scrolls: CYFR's own pack, `cyfr`, alone, its
  record a `cyfr` one, and scrolls alone, each one `SKILL.md` with nothing
  that runs, so an operator's update of CYFR never brings a person
  something to agree to; and CYFR's own words name a scroll by its full
  name, never bare.
  """

  use ExUnit.Case, async: true

  alias Compendium.Packs

  @seed Path.expand("../../../../seed/aqua", __DIR__)

  # The words that name a scroll: `aqua.skill_get(name: "x")`, a job's
  # `scrolls: ["x"]`, and "the `x` scroll".
  defp bare_names(text, scrolls) do
    names = Enum.join(Enum.map(scrolls, &Regex.escape/1), "|")

    [
      ~r/skill_get\(name: "([^":]+)"\)/,
      ~r/scrolls: \[\s*"([^":]+)"/,
      Regex.compile!("`(#{names})`\\s+scroll")
    ]
    |> Enum.flat_map(&Regex.scan(&1, text, capture: :all_but_first))
    |> List.flatten()
  end

  defp shipped_scrolls do
    @seed |> Path.join("scrolls/cyfr/skills") |> File.ls!() |> Enum.sort()
  end

  defp seed_texts do
    @seed
    |> Path.join("**/*.md")
    |> Path.wildcard(match_dot: true)
    |> Map.new(&{Path.relative_to(&1, @seed), File.read!(&1)})
  end

  test "CYFR's words name no scroll bare" do
    scrolls = shipped_scrolls()

    found =
      for {path, text} <- seed_texts(), name <- bare_names(text, scrolls), do: {path, name}

    assert found == []
  end

  test "the check finds a bare name planted in each of its forms (its positive control)" do
    planted = """
    Build it by the `builder` scroll, with aqua.skill_get(name: "builder"),
    or hand it on with scrolls: ["research"].
    """

    assert bare_names(planted, shipped_scrolls()) == ["builder", "research", "builder"]

    assert bare_names(
             "by the `cyfr:builder` scroll, skill_get(name: \"cyfr:builder\")",
             shipped_scrolls()
           ) ==
             []
  end

  test "the seed ships the pack cyfr alone, its record cyfr's, holding scrolls alone, each one SKILL.md" do
    assert File.ls!(Path.join(@seed, "scrolls")) == ["cyfr"]

    cyfr = Path.join(@seed, "scrolls/cyfr")

    assert {:ok, %{origin: "cyfr", on: true, executable: []}} =
             Packs.decode_record(File.read!(Path.join(cyfr, ".cyfr-pack.json")))

    files =
      cyfr
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.reject(&File.dir?/1)
      |> Enum.map(&Path.relative_to(&1, cyfr))
      |> Enum.sort()

    expected =
      [".cyfr-pack.json" | for(name <- shipped_scrolls(), do: "skills/#{name}/SKILL.md")]
      |> Enum.sort()

    assert files == expected

    for name <- shipped_scrolls() do
      bytes = File.read!(Path.join(cyfr, "skills/#{name}/SKILL.md"))
      refute String.starts_with?(bytes, "#!")
      assert {:ok, meta, _body} = Compendium.AquaAgent.parse_frontmatter(bytes)
      assert meta["name"] == name
    end

    refute File.exists?(Path.join(@seed, "skills"))
  end
end
