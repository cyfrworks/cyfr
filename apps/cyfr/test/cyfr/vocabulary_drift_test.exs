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
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @literals ["\"sub-agent\"", "\"orchestrator\""]

  # Files that keep the literal, by exact count.
  @orchestrator_literal_allowed %{
    # The approval row's payload key and its reader.
    "apps/cyfr/lib/aqua/conversation_runner.ex" => 2
  }

  # One walk of the tree serves both pins.
  setup_all do
    counts =
      for path <- Path.wildcard(Path.join(@root, "apps/cyfr/lib/**/*.ex")),
          lines = path |> Cyfr.Test.SourceTree.read() |> Cyfr.Test.CodeLines.lines(),
          literal <- @literals,
          n = Enum.count(lines, &String.contains?(&1, literal)),
          n > 0,
          reduce: %{} do
        acc ->
          rel = Path.relative_to(path, @root)
          Map.update(acc, literal, %{rel => n}, &Map.put(&1, rel, n))
      end

    {:ok, counts: counts}
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
