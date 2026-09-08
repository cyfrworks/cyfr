# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.VocabularyDriftTest do
  @moduledoc """
  The product has one assistant, its roles, its scrolls and its notes.
  Three of the four readers of the old `type` vocabulary failed open — a
  renamed string rendered an empty closet, an empty crew, a silent
  fallback — so the words are held out of the code by test rather than by
  memory: no `"sub-agent"` literal anywhere under `lib/`, and the
  `"orchestrator"` literal only where it is a persisted payload key the
  runner reads back from rows written before the rename (identifiers such
  as `conversations.orchestrator` are not literals and are not renamed).

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

  # Files that keep the literal, by exact count.
  @orchestrator_literal_allowed %{
    # The approval row's payload key, written where the card is minted and
    # read where it is decided.
    "apps/cyfr/lib/aqua/runner/stream.ex" => 1,
    "apps/cyfr/lib/aqua/runner/approvals.ex" => 1
  }

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
      for path <- Path.wildcard(Path.join(@root, "apps/cyfr/lib/**/*.ex")) do
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
  # may say what the code no longer does. `UPGRADING.md` is the one file
  # that keeps the old words on purpose — it explains the rename.
  @product_files [
    "seed/aqua/**/*.md",
    "apps/codex/**/*.go",
    "README.md",
    "component-guide.md",
    "integration-guide.md",
    "tincture-guide.md",
    "seed/components/formulas/local/aqua/*/cyfr-manifest.json"
  ]

  @old_words ~r/sub-agent|\bsub_agent\b|orchestrator/i

  test "the seed, the CLI, the guides and the manifest speak soul, role and scroll" do
    stale =
      for glob <- @product_files,
          path <- Path.wildcard(Path.join(@root, glob)),
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
