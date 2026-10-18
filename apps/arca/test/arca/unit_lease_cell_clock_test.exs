# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.UnitLeaseCellClockTest do
  @moduledoc """
  The unit draft lease — unit publication's one write lease — is judged on
  the cell's clock (`Arca.ServerMetaStorage.now!/0`), as every lease in
  the cell is (ARCHITECTURE.md §1.3: a cell's leases are on its
  database's clock), never on a member's wall clock: the instant a draft
  is registered, taken, given back or retired is written from it and
  compared against it by `Arca.StorageUnits`, and the collector judges a
  draft's life and the grace on it (`Arca.StorageGC`).

  One host has one wall clock, which on SQLite is the cell's clock too,
  so no run here can put a member's clock twenty minutes ahead of the
  database's. The scan reads the two owners' syntax trees instead: a
  wall-clock read creeping back into either fails here, a comment or a
  doc naming one does not. What the judgement does with the clock it is
  given is `Arca.StorageGCTest`'s, with a skewed `now:`.
  """

  use ExUnit.Case, async: true

  @lib Path.expand("../../lib/arca", __DIR__)
  @owners ["storage_units.ex", "storage_gc.ex"]

  test "the unit lease's owners read the cell's clock and never a member's wall clock" do
    for file <- @owners do
      reads = clock_reads(File.read!(Path.join(@lib, file)))

      assert :cell in reads, "#{file} reads no cell clock — the scan is not reading"
      assert Enum.reject(reads, &(&1 == :cell)) == [], "#{file} reads a member's wall clock"
    end
  end

  test "the scan sees a wall-clock read called or captured, and none in a doc or a comment" do
    reads =
      clock_reads(~S'''
      defmodule Arca.Planted do
        @moduledoc "Never `DateTime.utc_now/0`."

        # Not System.os_time() either.
        def called, do: DateTime.utc_now()
        def captured(opts), do: Keyword.get_lazy(opts, :now, &NaiveDateTime.utc_now/0)
        def system, do: System.system_time(:millisecond)
        def cell(opts), do: Keyword.get_lazy(opts, :now, &Arca.ServerMetaStorage.now!/0)
      end
      ''')

    assert Enum.sort(reads) ==
             Enum.sort([
               {:DateTime, :utc_now},
               {:NaiveDateTime, :utc_now},
               {:System, :system_time},
               :cell
             ])
  end

  @wall [
    {:DateTime, :utc_now},
    {:NaiveDateTime, :utc_now},
    {:System, :os_time},
    {:System, :system_time}
  ]

  # Every clock the source reads, called or captured: `:cell` for the
  # cell's clock, `{module, function}` for a wall clock.
  defp clock_reads(source) do
    {:ok, ast} = Code.string_to_quoted(source)

    {_ast, reads} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, aliases}, fun]}, _, _args} = node, acc ->
          {node, read(List.last(aliases), fun, acc)}

        node, acc ->
          {node, acc}
      end)

    reads
  end

  defp read(:ServerMetaStorage, :now!, acc), do: [:cell | acc]
  defp read(mod, fun, acc), do: if({mod, fun} in @wall, do: [{mod, fun} | acc], else: acc)
end
