# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.LockingSeamTest do
  @moduledoc """
  The two adapters lock differently, and each difference is spelled in
  exactly one place: a row lock clause only in `Arca.QueryHelpers`
  (`for_update/1`), and SQLite's write lock only in `Arca.Repo`, whose
  transaction hook sets every transaction's mode and runs the one
  statement that takes the lock. A locking transaction that reaches the
  adapter any other way is a lock one adapter raises on or silently
  ignores, and a mode or a lock-taking write spelled elsewhere bypasses
  the hook's bounded wait, so each is refused here.

  The scan reads code lines only (`Prima.Test.CodeLines`): a comment or a
  doc naming a lock is prose, not a lock.
  """

  use ExUnit.Case, async: true

  alias Prima.Test.{CodeLines, SourceTree}

  @root Path.expand("../../../..", __DIR__)

  # Both spellings of each: `lock(query, …)` / `lock: "…"` in a query;
  # `mode: …` / `[:mode, …]`-style keyword building, whatever the value;
  # and the write that touches no row, which takes SQLite's lock.
  @lock_clause ~r/(?<![\w.])lock\(|(?<![\w:])lock:\s/
  @mode ~r/(?<![\w:])mode:\s|(?<![\w:]):mode,/
  @lock_write ~r/\bWHERE\s+0\b/i

  @patterns [lock: @lock_clause, mode: @mode, lock_write: @lock_write]

  @homes %{
    lock: "apps/arca/lib/arca/query_helpers.ex",
    mode: "apps/arca/lib/arca/repo.ex",
    lock_write: "apps/arca/lib/arca/repo.ex"
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
        {kind, pattern} <- @patterns,
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

    assert CodeLines.lines(homes[@homes.mode]) |> Enum.any?(&(&1 =~ @mode)),
           "the scan no longer sees prepare_transaction/2's own transaction mode"

    assert CodeLines.lines(homes[@homes.lock_write]) |> Enum.any?(&(&1 =~ @lock_write)),
           "the scan no longer sees prepare_transaction/2's own lock-taking write"
  end

  test "no lock clause, transaction mode or lock-taking write outside its one home" do
    assert violations(arca_sources()) == [],
           """
           A lock spelled outside its helper:

           #{Enum.map_join(violations(arca_sources()), "\n", &"  #{&1}")}

           Open the transaction with `Arca.Repo.locking_transaction/2` and lock
           rows with `Arca.QueryHelpers.for_update/1`: SQLite raises on a lock
           clause, PostgreSQL ignores a transaction mode, and on SQLite
           `Arca.Repo.prepare_transaction/2` alone takes the write lock, with a
           wait that never parks a scheduler.
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

    test "a transaction mode outside Arca.Repo is refused, in either spelling, for any value" do
      planted = [
        {"apps/arca/lib/arca/planted.ex",
         ~S'''
         defmodule Arca.Planted do
           def a(fun), do: Arca.Repo.transaction(fun, mode: :immediate)
           def b(fun), do: Arca.Repo.transaction(fun, Keyword.put([], :mode, :immediate))
           def c(fun), do: Arca.Repo.transaction(fun, mode: :deferred)
           def d(fun, mode), do: Arca.Repo.transaction(fun, mode: mode)
         end
         '''}
      ]

      assert [
               "apps/arca/lib/arca/planted.ex:2: mode outside" <> _,
               "apps/arca/lib/arca/planted.ex:3: mode outside" <> _,
               "apps/arca/lib/arca/planted.ex:4: mode outside" <> _,
               "apps/arca/lib/arca/planted.ex:5: mode outside" <> _
             ] = violations(planted)
    end

    test "the lock-taking write outside Arca.Repo is refused, in any case" do
      planted = [
        {"apps/arca/lib/arca/planted.ex",
         ~S'''
         defmodule Arca.Planted do
           def a, do: Arca.Repo.query!("UPDATE schema_migrations SET version = version WHERE 0")
           def b, do: Arca.Repo.query!("update server_meta set key = key where 0")
         end
         '''}
      ]

      assert [
               "apps/arca/lib/arca/planted.ex:2: lock_write outside" <> _,
               "apps/arca/lib/arca/planted.ex:3: lock_write outside" <> _
             ] = violations(planted)
    end

    test "each helper's home is exempt only for its own spelling" do
      planted = [
        {@homes.lock,
         "defmodule Q do\n  def a, do: Arca.Repo.transaction(& &1, mode: :immediate)\n" <>
           "  def b, do: Arca.Repo.query!(\"UPDATE t SET x = x WHERE 0\")\nend\n"},
        {@homes.mode, "defmodule R do\n  def a(q), do: lock(q, \"FOR UPDATE\")\nend\n"}
      ]

      assert [
               "apps/arca/lib/arca/query_helpers.ex:2: mode outside" <> _,
               "apps/arca/lib/arca/query_helpers.ex:3: lock_write outside" <> _,
               "apps/arca/lib/arca/repo.ex:2: lock outside" <> _
             ] = violations(planted)
    end

    test "a field or option that merely ends in mode is not a transaction mode" do
      planted = [
        {"apps/arca/lib/arca/planted.ex",
         ~S'''
         defmodule Arca.Planted do
           def a, do: %{invoke_mode: :open_inert}
           def b, do: [journal_mode: :wal, mode_label: "x"]
         end
         '''}
      ]

      assert violations(planted) == []
    end

    test "prose naming a lock is not a lock" do
      planted = [
        {"apps/arca/lib/arca/planted.ex",
         ~S'''
         defmodule Arca.Planted do
           @moduledoc """
           Takes a row lock: see mode: :immediate and lock("FOR UPDATE"),
           and the write lock: UPDATE t SET x = x WHERE 0.
           """

           # lock: a comment is prose, and so is mode: :deferred or WHERE 0
           def a, do: :ok
         end
         '''}
      ]

      assert violations(planted) == []
    end
  end
end
