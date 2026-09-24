# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.DiagnosticsTest do
  @moduledoc """
  Whatever a build writes, the lines kept of it encode on the wire: valid
  UTF-8, each within the line bound with its `stage: ` prefix, all within
  the log bound; the build's own lines stop at a budget behind one line
  saying so, and the builder's keep a reserve past it.
  """

  use ExUnit.Case, async: true

  alias Prima.BuilderProtocol
  alias Locus.Diagnostics

  defp encodes!(pieces) do
    for {stage, message} <- pieces do
      assert {:ok, _line} = BuilderProtocol.encode_progress(stage, message)
    end

    lines = Enum.map(pieces, fn {stage, message} -> Diagnostics.line(stage, message) end)
    assert {:ok, _line} = BuilderProtocol.encode_refusal({:failed, {:status, 1}}, lines)
    lines
  end

  test "a line is its stage and its message, and an empty message is no line" do
    budget = Diagnostics.budget()

    assert Diagnostics.admit(budget, :output, "Compiling vector v0.1.0") ==
             [{:output, "Compiling vector v0.1.0"}]

    assert Diagnostics.admit(budget, :output, "") == []

    assert Diagnostics.line(:compiling, "Compiling reagent (rust)...") ==
             "compiling: Compiling reagent (rust)..."
  end

  test "bytes that are not UTF-8 are replaced, so the line encodes" do
    pieces = Diagnostics.admit(Diagnostics.budget(), :output, <<"ok ", 0xFF, 0xFE, " still">>)
    assert [{:output, message}] = pieces
    assert String.valid?(message)
    assert message =~ "ok " and message =~ " still"
    encodes!(pieces)
  end

  test "a line longer than the wire's bound goes out in pieces cut between characters" do
    max = BuilderProtocol.max_line_bytes()
    long = String.duplicate("é", max)

    pieces = Diagnostics.admit(Diagnostics.budget(), :validating, long)
    assert length(pieces) == 3
    assert Enum.map_join(pieces, fn {_stage, message} -> message end) == long

    for line <- encodes!(pieces) do
      assert byte_size(line) <= max
      assert String.valid?(line)
    end
  end

  test "a build's log stops at its budget behind one line saying so, and stays stopped" do
    budget = Diagnostics.budget()
    line = String.duplicate("x", 1_000)

    pieces = Enum.flat_map(1..3_000, fn _ -> Diagnostics.admit(budget, :output, line) end)
    lines = encodes!(pieces)

    kept = Enum.reduce(lines, 0, &(byte_size(&1) + 1 + &2))
    assert kept <= BuilderProtocol.max_log_bytes()
    assert length(pieces) < 3_000

    assert {:output, "the build's log passed" <> _} = List.last(pieces)
    assert Enum.count(pieces, fn {_stage, message} -> message =~ "is not kept" end) == 1

    # A short line that would fit never follows the line saying the rest is gone.
    assert Diagnostics.admit(budget, :output, "short") == []

    # The builder's own lines keep a reserve, so a refusal is still explained.
    assert [{:compiling, "the build produced more than 500 files"}] =
             Diagnostics.admit(budget, :compiling, "the build produced more than 500 files")

    assert {:ok, _} =
             BuilderProtocol.encode_refusal(
               {:failed, {:status, 0}},
               lines ++ ["compiling: the build produced more than 500 files"]
             )
  end

  test "a sentence is cut to the wire's bound between characters, and is never empty" do
    max = BuilderProtocol.max_line_bytes()

    assert Diagnostics.sentence("a reagent is not built from javascript") ==
             "a reagent is not built from javascript"

    cut = Diagnostics.sentence(String.duplicate("é", max))
    assert byte_size(cut) == max and String.valid?(cut)
    assert {:ok, _} = BuilderProtocol.encode_refusal({:malformed, cut}, [])

    assert {:ok, _} = BuilderProtocol.encode_refusal({:unavailable, Diagnostics.sentence("")}, [])
    assert String.valid?(Diagnostics.sentence(<<0xFF, 0xFE>>))
  end
end
