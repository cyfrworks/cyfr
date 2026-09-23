# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.LockingSeamTest do
  @moduledoc """
  The two adapters lock differently, and each difference is spelled in
  exactly one place: a row lock clause only in `Arca.QueryHelpers`
  (`for_update/1`), and SQLite's immediate transaction only in
  `Arca.Repo` (`locking_transaction/2`). A locking transaction that
  reaches the adapter any other way is a lock one adapter raises on or
  silently ignores, so it is refused here.

  The scan reads code lines only (`Cyfr.Test.CodeLines`): a comment or a
  doc naming a lock is prose, not a lock.
  """

  use ExUnit.Case, async: true

  alias Cyfr.Test.{CodeLines, SourceTree}

  @root Path.expand("../../../..", __DIR__)

  # Both spellings of each: `lock(query, …)` / `lock: "…"` in a query, and
  # `mode: :immediate` / `[:mode, :immediate]`-style keyword building.
  @lock_clause ~r/(?<![\w.])lock\(|(?<![\w:])lock:\s/
  @immediate ~r/mode:\s*:immediate|:mode,\s*:immediate/

  @homes %{
    lock: "apps/arca/lib/arca/query_helpers.ex",
    immediate: "apps/arca/lib/arca/repo.ex"
  }

  defp arca_sources do
    for path <- SourceTree.files!(Path.join(@root, "apps/arca/lib/**/*.ex")),
        do: {Path.relative_to(path, @root), SourceTree.read(path)}
  end

  # `sources` is `[{relative_path, source}]`, so a planted file is checked
  # exactly as a real one is.
  defp violations(sources) do
    for {path, source} <- sources,
        {line, n} <- CodeLines.code_lines(source),
        {kind, pattern} <- [lock: @lock_clause, immediate: @immediate],
        line =~ pattern,
        path != @homes[kind],
        do: "#{path}:#{n}: #{kind} outside #{@homes[kind]}: #{String.trim(line)}"
  end

  test "the scan reads the storage layer's source, not nothing" do
    sources = arca_sources()

    assert length(sources) > 40,
           "expected apps/arca/lib to be scanned, found #{length(sources)} files"

    homes = Map.new(sources)

    for {kind, home} <- @homes do
      assert Map.has_key?(homes, home), "#{home}, the #{kind} helper's home, was not scanned"
    end

    assert CodeLines.lines(homes[@homes.lock]) |> Enum.any?(&(&1 =~ @lock_clause)),
           "the scan no longer sees for_update/1's own lock clause"

    assert CodeLines.lines(homes[@homes.immediate]) |> Enum.any?(&(&1 =~ @immediate)),
           "the scan no longer sees locking_transaction/2's own immediate mode"
  end

  test "no lock clause or immediate transaction outside its one home" do
    assert violations(arca_sources()) == [],
           """
           A lock spelled outside its helper:

           #{Enum.map_join(violations(arca_sources()), "\n", &"  #{&1}")}

           Open the transaction with `Arca.Repo.locking_transaction/2` and lock
           rows with `Arca.QueryHelpers.for_update/1`: SQLite raises on a lock
           clause, and PostgreSQL ignores an immediate mode.
           """
  end

  describe "a planted violation" do
    test "a lock clause in a storage module is refused, in either spelling" do
      planted = [
        {"apps/arca/lib/arca/planted.ex",
         ~S'''
         defmodule Arca.Planted do
           import Ecto.Query

           def a(q), do: q |> lock("FOR UPDATE") |> Arca.Repo.all()
           def b, do: Arca.Repo.all(from(r in "rows", lock: "FOR UPDATE", select: r.id))
         end
         '''}
      ]

      assert [
               "apps/arca/lib/arca/planted.ex:4: lock outside" <> _,
               "apps/arca/lib/arca/planted.ex:5: lock outside" <> _
             ] = violations(planted)
    end

    test "an immediate transaction outside Arca.Repo is refused, in either spelling" do
      planted = [
        {"apps/arca/lib/arca/planted.ex",
         ~S'''
         defmodule Arca.Planted do
           def a(fun), do: Arca.Repo.transaction(fun, mode: :immediate)
           def b(fun), do: Arca.Repo.transaction(fun, Keyword.put([], :mode, :immediate))
         end
         '''}
      ]

      assert [
               "apps/arca/lib/arca/planted.ex:2: immediate outside" <> _,
               "apps/arca/lib/arca/planted.ex:3: immediate outside" <> _
             ] = violations(planted)
    end

    test "each helper's home is exempt only for its own spelling" do
      planted = [
        {@homes.lock, "defmodule Q do\n  def a, do: Arca.Repo.transaction(& &1, mode: :immediate)\nend\n"},
        {@homes.immediate, "defmodule R do\n  def a(q), do: lock(q, \"FOR UPDATE\")\nend\n"}
      ]

      assert [
               "apps/arca/lib/arca/query_helpers.ex:2: immediate outside" <> _,
               "apps/arca/lib/arca/repo.ex:2: lock outside" <> _
             ] = violations(planted)
    end

    test "prose naming a lock is not a lock" do
      planted = [
        {"apps/arca/lib/arca/planted.ex",
         ~S'''
         defmodule Arca.Planted do
           @moduledoc """
           Takes a row lock: see mode: :immediate and lock("FOR UPDATE").
           """

           # lock: a comment is prose
           def a, do: :ok
         end
         '''}
      ]

      assert violations(planted) == []
    end
  end
end
