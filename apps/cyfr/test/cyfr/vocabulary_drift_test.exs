# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.VocabularyDriftTest do
  @moduledoc """
  Checks assistant, role, scroll and note terminology in code and product
  copy. The words the product does not use are spelled split here so the
  file passes the gate it enforces.

  The agent-type values are held the same way: `"soul"` and `"role"` are
  `Compendium.AquaAgent`'s (`soul_type/0`, `role_type/0`, `type_of/1`),
  and a reader comparing against a bare literal would filter to nothing
  if the writer's spelling moved. `"role"` is also the provider-shape
  message key (`%{"role" => "user"}`) and a membership field
  (`m["role"]`): a key is followed by `=>` or wrapped in `[...]`, and
  neither spelling is the type value, so both are set aside before a
  line is counted.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @literals ["\"sub-agent\""]

  # The lib trees the code-line pins read: the host's, and Sanctum's, which
  # holds the gate.
  @lib_trees ["apps/cyfr/lib/**/*.ex", "apps/sanctum/lib/**/*.ex"]

  # The agent a turn is addressed to is a soul or a role, never this word:
  # no code line under `apps/cyfr/lib` and `apps/sanctum/lib` and no column
  # of the baseline says it, quoted, bare, as an atom or as a field — by
  # file and exact count, none.
  @unused_word "orch" <> "estrator"
  @unused_word_allowed %{}
  @baseline "apps/arca/priv/repo/migrations/*_baseline.exs"

  @type_value ~r/"(?:soul|role)"/
  @type_key ~r/\["(?:soul|role)"\]|"(?:soul|role)"\s*=>|Arg\.new\("(?:soul|role)",/

  # Lines that spell an agent type as a bare value, by file and exact count.
  @type_literal_allowed %{
    # The two attributes the vocabulary is read from.
    "apps/cyfr/lib/compendium/aqua_agent.ex" => 2
  }

  defp type_value_line?(line) do
    String.replace(line, @type_key, "") =~ @type_value
  end

  defp unused_word_line?(line) do
    line |> String.downcase() |> String.contains?(@unused_word)
  end

  test "the scan distinguishes argument names from agent type values" do
    refute type_value_line?("Arg.new(\"role\", :string, required: true)")
    assert type_value_line?("agent.type == \"role\"")
  end

  # One walk of the lib trees serves every pin.
  setup_all do
    sources = Enum.flat_map(@lib_trees, &code_lines/1)

    counts =
      for {rel, lines} <- sources,
          literal <- @literals,
          n = Enum.count(lines, &String.contains?(&1, literal)),
          n > 0,
          reduce: %{} do
        acc -> Map.update(acc, literal, %{rel => n}, &Map.put(&1, rel, n))
      end

    type_counts =
      for {rel, lines} <- sources,
          n = Enum.count(lines, &type_value_line?/1),
          n > 0,
          into: %{},
          do: {rel, n}

    unused_counts =
      for {rel, lines} <- sources ++ code_lines(@baseline),
          n = Enum.count(lines, &unused_word_line?/1),
          n > 0,
          into: %{},
          do: {rel, n}

    {:ok, counts: counts, type_counts: type_counts, unused_counts: unused_counts}
  end

  defp code_lines(glob) do
    for path <- Prima.Test.SourceTree.files!(Path.join(@root, glob)) do
      {Path.relative_to(path, @root),
       path |> Prima.Test.SourceTree.read() |> Prima.Test.CodeLines.lines()}
    end
  end

  test "the agent-type values are spelled in Compendium.AquaAgent and read from there", %{
    type_counts: type_counts
  } do
    assert type_counts == @type_literal_allowed
  end

  # The product's words reach the person through the seed, the CLI, README,
  # ARCHITECTURE.md and the shipped guides as well as the code; each speaks
  # the code's vocabulary.
  @product_files ["seed/aqua/**/*.md", "apps/codex/**/*.go", "README.md", "ARCHITECTURE.md"]

  # The guides a project ships are the scaffold tarball's items
  # (scripts/scaffold-tarball.sh), the one list every copy is held to
  # (`Cyfr.DocsDriftTest` here, codex's scaffold test there), so a guide
  # shipped later is scanned without this file naming it.
  defp shipped_guides do
    script = File.read!(Path.join(@root, "scripts/scaffold-tarball.sh"))

    [_, items] =
      Regex.run(~r/\nITEMS=\((.*?)\n\)/s, script) ||
        flunk("scaffold-tarball.sh has no ITEMS list")

    guides =
      items
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
      |> Enum.flat_map(&String.split/1)
      |> Enum.filter(&String.ends_with?(&1, "-guide.md"))

    assert "integration-guide.md" in guides, "the scaffold ships #{inspect(guides)}"
    guides
  end

  @unused_words Regex.compile!("sub-agent|\\bsub_agent\\b|" <> @unused_word, "i")

  test "the seed, the CLI and the guides speak soul, role and scroll" do
    stale =
      for glob <- @product_files ++ shipped_guides(),
          path <- Prima.Test.SourceTree.files!(Path.join(@root, glob)),
          not String.ends_with?(path, "_test.go"),
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          line =~ @unused_words,
          do: "#{Path.relative_to(path, @root)}:#{n}: #{String.trim(line)}"

    assert stale == [], Enum.join(stale, "\n")
  end

  test "no code line under lib says \"sub-agent\"", %{counts: counts} do
    assert Map.get(counts, "\"sub-agent\"", %{}) == %{}
  end

  test "no code line under lib and no column of the baseline says \"#{@unused_word}\"", %{
    unused_counts: unused_counts
  } do
    assert unused_counts == @unused_word_allowed
  end
end
