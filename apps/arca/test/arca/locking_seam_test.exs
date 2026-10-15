# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.LockingSeamTest do
  @moduledoc """
  The two adapters lock differently, and each difference is spelled in
  exactly one place: a row lock clause only in `Arca.QueryHelpers`
  (`for_update/1`), and SQLite's write lock and PostgreSQL's advisory
  lock only in `Arca.Repo`, whose transaction hook sets every
  transaction's mode and runs the one statement that takes the write
  lock, and whose `transaction_lock/1` takes a server-wide lock on each
  adapter. A locking transaction that reaches the adapter any other way
  is a lock one adapter raises on or silently ignores, a mode or a
  lock-taking write spelled elsewhere bypasses the hook's bounded wait,
  and an advisory lock spelled elsewhere is a lock SQLite has no
  statement for, so each is refused here.

  A lock written as SQL is refused as its Ecto spelling is: a row lock
  clause (`FOR UPDATE`, `FOR SHARE` and their key variants) outside
  `Arca.QueryHelpers`, a transaction mode (`BEGIN IMMEDIATE`) outside
  `Arca.Repo`, and a table lock (`LOCK TABLE`) anywhere, since neither
  adapter's locking goes through one.

  The scan reads code lines (`Prima.Test.CodeLines`): a comment or a doc
  naming a lock is prose, not a lock. The SQL spellings are also read on
  the lines `CodeLines` drops as text, the body of a heredoc or sigil and a
  multi-line string's later lines, unless the text is documentation: that
  is where a statement sent with `query!` or `fragment` is written.
  """

  use ExUnit.Case, async: true

  alias Prima.Test.{CodeLines, SourceTree}

  @root Path.expand("../../../..", __DIR__)

  # Both spellings of each: `lock(query, …)`, bare or qualified as
  # `Ecto.Query.lock` or `Query.lock`, / `lock: "…"` in a query, where a
  # function of our own named `lock` (its definition, its spec, a call with
  # no arguments) is no clause, since Ecto's `lock` always takes one;
  # `mode: …` / `[:mode, …]`-style keyword building, whatever the value;
  # the write that touches no row, which takes SQLite's lock; and every
  # PostgreSQL advisory lock function: session or transaction, waiting or
  # `try`, exclusive or shared, and its unlocks.
  @lock_clause ~r/(?:\bQuery\.|(?<![\w.]))(?<!def |defp |@spec )lock\((?!\s*\))|(?<![\w:])lock:\s/
  @mode ~r/(?<![\w:])mode:\s|(?<![\w:]):mode,/
  @lock_write ~r/\bWHERE\s+0\b/i
  @advisory ~r/\bpg_(?:try_)?advisory_/i
  # The same locks written as SQL, in any case: a row lock clause in each
  # strength PostgreSQL has, a transaction that opens with a mode, and a
  # table lock.
  @row_lock_sql ~r/\bFOR\s+(?:NO\s+KEY\s+)?UPDATE\b|\bFOR\s+(?:KEY\s+)?SHARE\b/i
  @begin_mode ~r/\bBEGIN\s+(?:IMMEDIATE|EXCLUSIVE|DEFERRED)\b/i
  @table_lock ~r/\bLOCK\s+(?:TABLE\b|(?:ONLY\s+)?[\w."]+\s+IN\s+[\w\s]+?\s+MODE\b)/i

  # Elixir spellings are read on code lines only; SQL ones on code lines
  # and on the text of strings and heredocs.
  @code_patterns [lock: @lock_clause, mode: @mode]
  @sql_patterns [
    lock_write: @lock_write,
    advisory: @advisory,
    row_lock_sql: @row_lock_sql,
    begin_mode: @begin_mode,
    table_lock: @table_lock
  ]

  @text_tokens [:bin_string, :list_string, :bin_heredoc, :list_heredoc, :sigil]

  # A table lock has no home: neither adapter's locking takes one.
  @homes %{
    lock: "apps/arca/lib/arca/query_helpers.ex",
    mode: "apps/arca/lib/arca/repo.ex",
    lock_write: "apps/arca/lib/arca/repo.ex",
    advisory: "apps/arca/lib/arca/repo.ex",
    row_lock_sql: "apps/arca/lib/arca/query_helpers.ex",
    begin_mode: "apps/arca/lib/arca/repo.ex",
    table_lock: nil
  }

  defp arca_sources do
    for path <- SourceTree.files!(Path.join(@root, "apps/arca/lib/**/*.ex")),
        do: {Path.relative_to(path, @root), SourceTree.read(path)}
  end

  # The lines of `source` a string, heredoc or sigil spans that are
  # neither code (`code`, `CodeLines.code_lines/1`'s answer) nor
  # documentation: the text `CodeLines` drops, read here for SQL alone.
  defp text_lines(source, code) do
    {:ok, _line, _column, _warnings, tokens, _terminators} =
      :elixir_tokenizer.tokenize(String.to_charlist(source), 1, [])

    code_numbers = MapSet.new(code, &elem(&1, 1))

    text =
      for [at, name, token] <- Enum.chunk_every([nil, nil | Enum.reverse(tokens)], 3, 1, :discard),
          is_tuple(token) and elem(token, 0) in @text_tokens,
          {line, _column, _extra} <- [elem(token, 1)],
          not doc?(at, name, line),
          n <- line..(line + newlines(token)),
          into: MapSet.new(),
          do: n

    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {_line, n} -> n in text and n not in code_numbers end)
  end

  # `@doc`, `@moduledoc`, `@typedoc` or `@shortdoc` with its text opening
  # on the attribute's own line.
  defp doc?({:at_op, {line, _, _}, :@}, {:identifier, {line, _, _}, name}, line),
    do: name in [:doc, :moduledoc, :typedoc, :shortdoc]

  defp doc?(_at, _name, _line), do: false

  # How many lines past its first a text token runs: the newlines in its
  # literal parts, and the lines each interpolation spans.
  defp newlines(token) do
    token
    |> parts()
    |> Enum.reduce(0, fn
      {{start, _, _}, {stop, _, _}, _tokens}, acc -> acc + stop - start
      literal, acc -> acc + length(String.split(IO.chardata_to_string(literal), "\n")) - 1
    end)
  end

  defp parts({:bin_string, _meta, parts}), do: parts
  defp parts({:list_string, _meta, parts}), do: parts
  defp parts({:bin_heredoc, _meta, _indent, parts}), do: parts
  defp parts({:list_heredoc, _meta, _indent, parts}), do: parts
  defp parts({:sigil, _meta, _name, parts, _modifiers, _indent, _delimiter}), do: parts

  # `sources` is `[{relative_path, source}]`, so a planted file is checked
  # exactly as a real one is.
  defp violations(sources) do
    for {path, source} <- sources,
        code <- [CodeLines.code_lines(source)],
        {line, n} <- Enum.sort_by(code ++ text_lines(source, code), &elem(&1, 1)),
        {kind, pattern} <- @code_patterns ++ @sql_patterns,
        Keyword.has_key?(@sql_patterns, kind) or {line, n} in code,
        line =~ pattern,
        path != @homes[kind],
        do: "#{path}:#{n}: #{kind} outside #{@homes[kind] || "any home"}: #{String.trim(line)}"
  end

  test "the scan reads the storage layer's source, not nothing" do
    sources = arca_sources()

    assert length(sources) > 40,
           "expected apps/arca/lib to be scanned, found #{length(sources)} files"

    homes = Map.new(sources)

    for {kind, home} <- @homes, home != nil do
      assert Map.has_key?(homes, home), "#{home}, the #{kind} helper's home, was not scanned"
    end

    assert CodeLines.lines(homes[@homes.lock]) |> Enum.any?(&(&1 =~ @lock_clause)),
           "the scan no longer sees for_update/1's own lock clause"

    assert CodeLines.lines(homes[@homes.mode]) |> Enum.any?(&(&1 =~ @mode)),
           "the scan no longer sees prepare_transaction/2's own transaction mode"

    assert CodeLines.lines(homes[@homes.lock_write]) |> Enum.any?(&(&1 =~ @lock_write)),
           "the scan no longer sees prepare_transaction/2's own lock-taking write"

    assert CodeLines.lines(homes[@homes.advisory]) |> Enum.any?(&(&1 =~ @advisory)),
           "the scan no longer sees transaction_lock/1's own advisory lock"

    assert CodeLines.lines(homes[@homes.row_lock_sql]) |> Enum.any?(&(&1 =~ @row_lock_sql)),
           "the scan no longer sees for_update/1's own FOR UPDATE"
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
           wait that never parks a scheduler. Take a server-wide lock with
           `Arca.Repo.transaction_lock/1`, which spells it for each adapter.
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
               "apps/arca/lib/arca/planted.ex:4: row_lock_sql outside" <> _,
               "apps/arca/lib/arca/planted.ex:5: lock outside" <> _,
               "apps/arca/lib/arca/planted.ex:5: row_lock_sql outside" <> _
             ] = violations(planted)
    end

    test "an advisory lock outside Arca.Repo is refused, waiting or try, in any case" do
      planted = [
        {"apps/arca/lib/arca/planted.ex",
         ~S'''
         defmodule Arca.Planted do
           def a(k), do: Arca.Repo.query!("SELECT pg_advisory_xact_lock($1)", [k])
           def b(k), do: Arca.Repo.query!("SELECT pg_advisory_lock($1)", [k])
           def c(k), do: Arca.Repo.query!("SELECT pg_try_advisory_xact_lock($1)", [k])
           def d(k), do: Arca.Repo.query!("SELECT PG_ADVISORY_LOCK_SHARED($1)", [k])
           def e(k), do: Arca.Repo.query!("SELECT pg_advisory_unlock($1)", [k])
           def f, do: Arca.Repo.query!("SELECT PG_ADVISORY_UNLOCK_ALL()")
         end
         '''}
      ]

      assert [
               "apps/arca/lib/arca/planted.ex:2: advisory outside" <> _,
               "apps/arca/lib/arca/planted.ex:3: advisory outside" <> _,
               "apps/arca/lib/arca/planted.ex:4: advisory outside" <> _,
               "apps/arca/lib/arca/planted.ex:5: advisory outside" <> _,
               "apps/arca/lib/arca/planted.ex:6: advisory outside" <> _,
               "apps/arca/lib/arca/planted.ex:7: advisory outside" <> _
             ] = violations(planted)
    end

    test "a function named lock is not a lock clause, and Ecto's lock beside it still is" do
      planted = [
        {"apps/arca/lib/arca/planted.ex",
         ~S'''
         defmodule Arca.Planted do
           @spec lock() :: :ok
           def lock do
             Arca.Repo.transaction_lock(1)
           end

           @spec lock(integer()) :: :ok
           def lock(key), do: Arca.Repo.transaction_lock(key)
           defp lock(key, _), do: Arca.Repo.transaction_lock(key)
           def a, do: Arca.AthanorCensus.lock()
           def b, do: lock( )

           def c(q), do: q |> lock("FOR UPDATE") |> Arca.Repo.all()
           def d(q), do: Arca.Repo.all(lock(q, "FOR UPDATE"))
           def e, do: Arca.Repo.all(from(r in "rows", lock: "FOR UPDATE", select: r.id))
           def f(q), do: Arca.Repo.all(Ecto.Query.lock(q, "FOR UPDATE"))
           def g(q), do: q |> Query.lock("FOR SHARE") |> Arca.Repo.all()
         end
         '''}
      ]

      assert [
               "apps/arca/lib/arca/planted.ex:13: lock outside" <> _,
               "apps/arca/lib/arca/planted.ex:13: row_lock_sql outside" <> _,
               "apps/arca/lib/arca/planted.ex:14: lock outside" <> _,
               "apps/arca/lib/arca/planted.ex:14: row_lock_sql outside" <> _,
               "apps/arca/lib/arca/planted.ex:15: lock outside" <> _,
               "apps/arca/lib/arca/planted.ex:15: row_lock_sql outside" <> _,
               "apps/arca/lib/arca/planted.ex:16: lock outside" <> _,
               "apps/arca/lib/arca/planted.ex:16: row_lock_sql outside" <> _,
               "apps/arca/lib/arca/planted.ex:17: lock outside" <> _,
               "apps/arca/lib/arca/planted.ex:17: row_lock_sql outside" <> _
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
        {@homes.mode, "defmodule R do\n  def a(q), do: lock(q, \"FOR UPDATE\")\nend\n"},
        {@homes.lock,
         "defmodule S do\n  def a, do: Arca.Repo.query!(\"SELECT pg_advisory_xact_lock(1)\")\nend\n"}
      ]

      assert [
               "apps/arca/lib/arca/query_helpers.ex:2: mode outside" <> _,
               "apps/arca/lib/arca/query_helpers.ex:3: lock_write outside" <> _,
               "apps/arca/lib/arca/repo.ex:2: lock outside" <> _,
               "apps/arca/lib/arca/repo.ex:2: row_lock_sql outside" <> _,
               "apps/arca/lib/arca/query_helpers.ex:2: advisory outside" <> _
             ] = violations(planted)
    end

    test "a lock written as SQL in a query string or fragment is refused, in any case" do
      planted = [
        {"apps/arca/lib/arca/planted.ex",
         ~S'''
         defmodule Arca.Planted do
           def a, do: Arca.Repo.query!("SELECT id FROM rows WHERE id = $1 FOR UPDATE", [1])
           def b, do: Arca.Repo.query!("select id from rows for no key update")
           def c, do: Arca.Repo.query!("SELECT id FROM rows FOR SHARE SKIP LOCKED")
           def d, do: Arca.Repo.query!("SELECT id FROM rows FOR KEY SHARE")
           def e(q), do: from(r in q, where: fragment("? IN (SELECT id FROM t FOR UPDATE)", r.id))
           def f, do: Arca.Repo.query!("LOCK TABLE rows IN EXCLUSIVE MODE")
           def g, do: Arca.Repo.query!("lock only rows in access exclusive mode")
           def h, do: Arca.Repo.query!("BEGIN IMMEDIATE")
           def i, do: Arca.Repo.query!("begin exclusive transaction")
         end
         '''}
      ]

      assert [
               "apps/arca/lib/arca/planted.ex:2: row_lock_sql outside" <> _,
               "apps/arca/lib/arca/planted.ex:3: row_lock_sql outside" <> _,
               "apps/arca/lib/arca/planted.ex:4: row_lock_sql outside" <> _,
               "apps/arca/lib/arca/planted.ex:5: row_lock_sql outside" <> _,
               "apps/arca/lib/arca/planted.ex:6: row_lock_sql outside" <> _,
               "apps/arca/lib/arca/planted.ex:7: table_lock outside any home" <> _,
               "apps/arca/lib/arca/planted.ex:8: table_lock outside any home" <> _,
               "apps/arca/lib/arca/planted.ex:9: begin_mode outside" <> _,
               "apps/arca/lib/arca/planted.ex:10: begin_mode outside" <> _
             ] = violations(planted)
    end

    test "a lock in heredoc or multi-line SQL is refused on the line it is written" do
      planted = [
        {"apps/arca/lib/arca/planted.ex",
         ~S'''
         defmodule Arca.Planted do
           @locked """
           SELECT id
             FROM rows
            WHERE id = $1
              FOR UPDATE
           """

           def a, do: Arca.Repo.query!(@locked, [1])

           def b do
             Arca.Repo.query!(~s"""
             LOCK TABLE rows
             """)
           end

           def c, do: Arca.Repo.query!("SELECT 1;
             BEGIN IMMEDIATE;
             COMMIT")

           def d, do: Arca.Repo.query!("SELECT #{
             "pg_advisory_xact_lock(1)"
           }
           FROM t WHERE 0
           ")

           def e do
             Arca.Repo.query!(~S"""
             SELECT id FROM rows
               for key share
             """)
           end
         end
         '''}
      ]

      assert [
               "apps/arca/lib/arca/planted.ex:6: row_lock_sql outside" <> _,
               "apps/arca/lib/arca/planted.ex:13: table_lock outside any home" <> _,
               "apps/arca/lib/arca/planted.ex:18: begin_mode outside" <> _,
               "apps/arca/lib/arca/planted.ex:22: advisory outside" <> _,
               "apps/arca/lib/arca/planted.ex:24: lock_write outside" <> _,
               "apps/arca/lib/arca/planted.ex:30: row_lock_sql outside" <> _
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
           the write lock: UPDATE t SET x = x WHERE 0, and pg_advisory_xact_lock.
           """

           @doc """
           Never LOCK TABLE, BEGIN IMMEDIATE or SELECT … FOR SHARE here.
           """
           # lock: a comment is prose, and so is mode: :deferred, WHERE 0 or pg_advisory_lock,
           # LOCK TABLE t, BEGIN EXCLUSIVE or FOR UPDATE
           def a, do: :ok
         end
         '''}
      ]

      assert violations(planted) == []
    end
  end
end
