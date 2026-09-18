# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.VocabularyDriftTest do
  @moduledoc """
  Checks assistant, role, scroll and note terminology in code and product
  copy. The retired words are spelled split here so the file passes the
  gate it enforces.

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

  # The word the runner, the rows and the tool option used to call the
  # agent a turn is addressed to. It is gone from every code line under
  # lib and from every column of the baseline: quoted, bare, as an atom
  # or as a field — by file and exact count, none.
  @retired_word "orch" <> "estrator"
  @retired_word_allowed %{}
  @baseline "apps/cyfr/priv/repo/migrations/*_baseline.exs"

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

  defp retired_word_line?(line) do
    line |> String.downcase() |> String.contains?(@retired_word)
  end

  test "the scan distinguishes argument names from agent type values" do
    refute type_value_line?("Arg.new(\"role\", :string, required: true)")
    assert type_value_line?("agent.type == \"role\"")
  end

  # One walk of the tree serves every pin.
  setup_all do
    sources = code_lines("apps/cyfr/lib/**/*.ex")

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

    retired_counts =
      for {rel, lines} <- sources ++ code_lines(@baseline),
          n = Enum.count(lines, &retired_word_line?/1),
          n > 0,
          into: %{},
          do: {rel, n}

    {:ok, counts: counts, type_counts: type_counts, retired_counts: retired_counts}
  end

  defp code_lines(glob) do
    for path <- Cyfr.Test.SourceTree.files!(Path.join(@root, glob)) do
      {Path.relative_to(path, @root),
       path |> Cyfr.Test.SourceTree.read() |> Cyfr.Test.CodeLines.lines()}
    end
  end

  test "the agent-type values are spelled in Compendium.AquaAgent and read from there", %{
    type_counts: type_counts
  } do
    assert type_counts == @type_literal_allowed
  end

  # The product's words reach the person through the seed, the CLI, the
  # guides and the formula's manifest as well as the code; none of them
  # may say what the code no longer does.
  @product_files [
    "seed/aqua/**/*.md",
    "apps/codex/**/*.go",
    "README.md",
    "component-guide.md",
    "integration-guide.md",
    "tincture-guide.md"
  ]

  @old_words Regex.compile!("sub-agent|\\bsub_agent\\b|" <> @retired_word, "i")

  test "the seed, the CLI, the guides and the manifest speak soul, role and scroll" do
    stale =
      for glob <- @product_files,
          path <- Cyfr.Test.SourceTree.files!(Path.join(@root, glob)),
          not String.ends_with?(path, "_test.go"),
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          line =~ @old_words,
          do: "#{Path.relative_to(path, @root)}:#{n}: #{String.trim(line)}"

    assert stale == [], Enum.join(stale, "\n")
  end

  test "no code line under lib says \"sub-agent\"", %{counts: counts} do
    assert Map.get(counts, "\"sub-agent\"", %{}) == %{}
  end

  test "no code line under lib and no column of the baseline says \"#{@retired_word}\"", %{
    retired_counts: retired_counts
  } do
    assert retired_counts == @retired_word_allowed
  end
end
