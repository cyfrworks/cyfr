# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.VocabularyDriftTest do
  @moduledoc """
  Checks assistant, role, scroll and note terminology in code and product
  copy. Persisted payload keys are explicitly exempted where required.

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
  @literals ["\"sub-agent\"", "\"orchestrator\""]

  # Files that keep the literal, by exact count: none.
  @orchestrator_literal_allowed %{}

  @type_value ~r/"(?:soul|role)"/
  @type_key ~r/\["(?:soul|role)"\]|"(?:soul|role)"\s*=>/

  # Lines that spell an agent type as a bare value, by file and exact count.
  @type_literal_allowed %{
    # The two attributes the vocabulary is read from.
    "apps/cyfr/lib/compendium/aqua_agent.ex" => 2
  }

  defp type_value_line?(line) do
    String.replace(line, @type_key, "") =~ @type_value
  end

  # One walk of the tree serves every pin.
  setup_all do
    sources =
      for path <- Cyfr.Test.SourceTree.files!(Path.join(@root, "apps/cyfr/lib/**/*.ex")) do
        {Path.relative_to(path, @root),
         path |> Cyfr.Test.SourceTree.read() |> Cyfr.Test.CodeLines.lines()}
      end

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

    {:ok, counts: counts, type_counts: type_counts}
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

  @old_words ~r/sub-agent|\bsub_agent\b|orchestrator/i

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

  test "the \"orchestrator\" literal survives only as the runner's payload key", %{
    counts: counts
  } do
    assert Map.get(counts, "\"orchestrator\"", %{}) == @orchestrator_literal_allowed
  end
end
