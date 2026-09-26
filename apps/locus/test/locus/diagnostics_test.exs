# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.DiagnosticsTest do
  @moduledoc """
  Whatever a build writes, the lines kept of it encode on the wire: valid
  UTF-8, each within the line bound with its `stage: ` prefix, all within
  the log bound, each charged as its whole encoded progress line; the
  build's own lines stop at a budget behind one line saying so, and the
  builder's keep a reserve past it.
  """

  use ExUnit.Case, async: true

  alias Prima.BuilderProtocol
  alias Locus.Diagnostics

  # What each admitted line spells, read back from its progress line, and
  # the terminal line its diagnostics make.
  defp read!(admitted) do
    for {progress, diagnostic} <- admitted do
      assert {:ok, {:progress, stage, message}} = BuilderProtocol.read_line(progress)
      assert Jason.decode!(diagnostic) == Diagnostics.line(stage, message)
      {stage, message}
    end
  end

  defp encodes!(admitted) do
    diagnostics = Enum.map(admitted, &elem(&1, 1))

    assert {:ok, line} =
             BuilderProtocol.encode_refusal({:failed, {:status, 1}}, {:encoded, diagnostics})

    assert {:ok, {:refusal, _refusal, lines}} = BuilderProtocol.read_line(line)
    lines
  end

  # The bytes the admitted lines cost on the wire, each with its newline.
  defp charged(admitted), do: Enum.reduce(admitted, 0, &(byte_size(elem(&1, 0)) + 1 + &2))

  defp cost(stage, message) do
    {:ok, line} = BuilderProtocol.encode_progress(stage, message)
    byte_size(line) + 1
  end

  test "a line is its stage and its message, and an empty message is no line" do
    budget = Diagnostics.budget()

    assert [{progress, diagnostic}] =
             Diagnostics.admit(budget, :output, "Compiling vector v0.1.0")

    assert {:ok, ^progress} = BuilderProtocol.encode_progress(:output, "Compiling vector v0.1.0")
    assert diagnostic == ~s("output: Compiling vector v0.1.0")

    assert Diagnostics.admit(budget, :output, "") == []

    assert Diagnostics.line(:compiling, "Compiling reagent (rust)...") ==
             "compiling: Compiling reagent (rust)..."
  end

  test "bytes that are not UTF-8 are replaced, so the line encodes" do
    admitted = Diagnostics.admit(Diagnostics.budget(), :output, <<"ok ", 0xFF, 0xFE, " still">>)
    assert [{:output, message}] = read!(admitted)
    assert String.valid?(message)
    assert message =~ "ok " and message =~ " still"
    encodes!(admitted)
  end

  test "a line longer than the wire's bound goes out in pieces cut between characters" do
    max = BuilderProtocol.max_line_bytes()
    long = String.duplicate("é", max)

    admitted = Diagnostics.admit(Diagnostics.budget(), :validating, long)
    pieces = read!(admitted)
    assert length(pieces) == 3
    assert Enum.map_join(pieces, fn {_stage, message} -> message end) == long

    for line <- encodes!(admitted) do
      assert byte_size(line) <= max
      assert String.valid?(line)
    end
  end

  test "a build's log stops at its budget behind one line saying so, and stays stopped" do
    budget = Diagnostics.budget()
    line = String.duplicate("x", 1_000)

    admitted = Enum.flat_map(1..3_000, fn _ -> Diagnostics.admit(budget, :output, line) end)
    pieces = read!(admitted)
    lines = encodes!(admitted)

    assert charged(admitted) <= BuilderProtocol.max_log_bytes()
    assert length(pieces) < 3_000

    assert {:output, "the build's log passed" <> _} = List.last(pieces)
    assert Enum.count(pieces, fn {_stage, message} -> message =~ "is not kept" end) == 1

    # A short line that would fit never follows the line saying the rest is gone.
    assert Diagnostics.admit(budget, :output, "short") == []

    # The builder's own lines keep a reserve, so a refusal is still explained.
    explained = Diagnostics.admit(budget, :compiling, "the build produced more than 500 files")
    assert [{:compiling, "the build produced more than 500 files"}] = read!(explained)
    assert charged(admitted ++ explained) <= BuilderProtocol.max_log_bytes()

    assert encodes!(admitted ++ explained) ==
             lines ++ ["compiling: the build produced more than 500 files"]
  end

  test "a line is charged at its encoded size, escapes and multi-byte characters included" do
    # Six bytes of text: a quote and a backslash escape to two bytes each,
    # a control character to six, and `é` is two bytes as it is.
    message = ~s(a"\\) <> <<1>> <> "é"
    assert byte_size(message) == 6
    cost = cost(:output, message)
    assert cost == cost(:output, "") + byte_size(~s(a\\"\\\\\\u0001é))

    budget = Diagnostics.budget()
    admitted = Stream.repeatedly(fn -> Diagnostics.admit(budget, :output, message) end)

    kept =
      admitted
      |> Enum.take_while(fn [one] -> not cut?(one) end)
      |> length()

    # Every line the budget kept cost its encoded bytes: exactly as many fit
    # as the build's share of the log holds at that cost.
    share = BuilderProtocol.max_log_bytes() - reserve()
    assert kept == div(share, cost)
  end

  test "a one-byte message costs its whole envelope" do
    cost = cost(:output, "a")
    assert cost > 50

    budget = Diagnostics.budget()

    kept =
      Stream.repeatedly(fn -> Diagnostics.admit(budget, :output, "a") end)
      |> Enum.take_while(fn [one] -> not cut?(one) end)
      |> length()

    share = BuilderProtocol.max_log_bytes() - reserve()
    assert kept == div(share, cost)
  end

  test "a budget spent at the encoded bound admits nothing further, not even the cut line" do
    budget = Diagnostics.budget()
    max = BuilderProtocol.max_log_bytes()
    unit = cost(:compiling, "")
    long = String.duplicate("x", 60_000)

    # The builder's own lines fill the log to its last byte.
    full = div(max, unit + 60_000)
    admitted = Enum.flat_map(1..full, fn _ -> Diagnostics.admit(budget, :compiling, long) end)
    rest = max - charged(admitted)
    last = Diagnostics.admit(budget, :compiling, String.duplicate("y", rest - unit))
    assert charged(admitted ++ last) == max

    assert Diagnostics.admit(budget, :compiling, "a") == []
    assert Diagnostics.admit(budget, :output, "a") == []
    assert Diagnostics.admit(budget, :output, "b") == []
    encodes!(admitted ++ last)
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

  defp cut?({progress, _diagnostic}), do: progress =~ "the rest of it is not kept"

  # The build's share of the log ends where the cut line says it did.
  defp reserve do
    budget = Diagnostics.budget()
    long = String.duplicate("x", 60_000)

    [{progress, _}] =
      Stream.repeatedly(fn -> Diagnostics.admit(budget, :output, long) end)
      |> Enum.find(fn [one] -> cut?(one) end)

    [_, share] = Regex.run(~r/passed (\d+) bytes/, progress)
    BuilderProtocol.max_log_bytes() - String.to_integer(share)
  end
end
