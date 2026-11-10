# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Test.SourceTree do
  @moduledoc """
  One read and one parse per source file per suite run, shared by every
  architecture test.

  `files!/2` is how a scan finds its files: a glob that matches nothing
  raises, so a scan pointed at a moved or misspelled tree cannot pass by
  reading nothing. It needs no table.

  `read/1`, `quoted/1`, `code_lines/1` and `aliases/1` memoize in an ETS
  table owned by the test-runner process: the database apps' suite boot
  (`Arca.Test.SuiteBoot.boot!/1`) calls `ensure_table/0` before tests
  start, and the umbrella runs them all in one VM, so the call is
  idempotent and the table lives until that VM exits. Each entry is
  computed once: the first caller claims it and a process of its own
  fills it, and a caller that finds the claim waits for that process to
  end rather than compute again, so async scans walking the same tree at
  the same time share one parse of each file. An entry is never changed
  once filled: source files do not change while the suite runs.

  Computes on the spot when the table is absent: Prima's and Locus's
  suites do not create it.
  """

  alias Prima.Test.CodeLines

  @table :prima_test_source_tree

  @doc """
  Create the memo table, once per VM.

  Every database app's suite boot calls it, and the umbrella runs them all
  in one VM, so the second call must find the table rather than raise. The
  table is owned by the calling process — the test runner's — so it
  outlives every test and no two tests race to create it.
  """
  @spec ensure_table() :: :ok
  def ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Every umbrella app's `lib` directory relative to `root` (`"apps/cyfr/lib"`,
  …), found rather than listed so a new app is scanned the day it lands.
  Raises when there is none, so a scan pointed at the wrong root cannot pass
  by reading nothing.
  """
  @spec app_libs(Path.t()) :: [String.t()]
  def app_libs(root) do
    libs =
      root
      |> Path.join("apps/*/mix.exs")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(Path.join(Path.dirname(&1), "lib"), root))
      |> Enum.filter(&File.dir?(Path.join(root, &1)))
      |> Enum.sort()

    if libs == [], do: raise("no umbrella app lib directory under #{root}"), else: libs
  end

  @doc """
  `Path.wildcard/2`, refusing an empty match.

  Raises with `glob` in the message when it matches nothing. `opts` pass
  through to `Path.wildcard/2`.
  """
  @spec files!(String.t(), keyword()) :: [String.t()]
  def files!(glob, opts \\ []) do
    case Path.wildcard(glob, opts) do
      [] -> raise "no file matches #{glob}"
      paths -> paths
    end
  end

  @doc "`File.read!/1`, memoized for the life of the suite."
  @spec read(Path.t()) :: String.t()
  def read(path) do
    path = Path.expand(path)
    memo({:read, path}, fn -> File.read!(path) end)
  end

  @doc """
  The file's code as `Code.string_to_quoted!/2` reads it, with columns
  and the path for a parse error, memoized beside its source.

  Every scan of a file reads this one tree: a scan that needs another
  view (`Macro.prewalk/3`, its own walk) derives it, and never changes
  what it was given.
  """
  @spec quoted(Path.t()) :: Macro.t()
  def quoted(path) do
    path = Path.expand(path)
    memo({:quoted, path}, fn -> Code.string_to_quoted!(read(path), file: path, columns: true) end)
  end

  @doc """
  `Prima.Test.CodeLines.code_lines/1` over a file, memoized beside its
  source.

  Classifying a file costs a tokenize, and the architecture rosters read
  the same trees several times over; the memo makes the second read free.
  """
  @spec code_lines(Path.t()) :: [{String.t(), pos_integer()}]
  def code_lines(path) do
    path = Path.expand(path)
    memo({:code_lines, path}, fn -> CodeLines.code_lines(read(path)) end)
  end

  @doc """
  `Prima.Test.CodeLines.aliases/1` over a file, memoized beside its source.

  Every module name the file names, with its line — the view the
  architecture rosters read.
  """
  @spec aliases(Path.t()) :: [{String.t(), pos_integer()}]
  def aliases(path) do
    path = Path.expand(path)
    memo({:aliases, path}, fn -> CodeLines.aliases(read(path)) end)
  end

  # An entry is `{key, {:filling, filler}}` while `filler` computes it and
  # `{key, {:value, value}}` from then on. `filler` is spawned before the
  # claim and starts only when its claim won, so a waiter's monitor on it
  # ends once the value is in the table or the computation failed.
  defp memo(key, compute) do
    case :ets.whereis(@table) do
      :undefined -> compute.()
      _table -> fetch(key, compute)
    end
  end

  defp fetch(key, compute) do
    case :ets.lookup(@table, key) do
      [{^key, {:value, value}}] ->
        value

      [{^key, {:filling, filler}} = claim] ->
        await(claim, filler, key, compute)

      [] ->
        filler =
          spawn(fn ->
            receive do
              :fill -> :ets.insert(@table, {key, {:value, compute.()}})
            end
          end)

        if :ets.insert_new(@table, {key, {:filling, filler}}),
          do: send(filler, :fill),
          else: Process.exit(filler, :kill)

        fetch(key, compute)
    end
  end

  # A filler gone without a value raised (a file that does not parse) or
  # was killed: its claim is dropped and the caller computes in place, so
  # the error is raised where the scan reports it.
  defp await(claim, filler, key, compute) do
    ref = Process.monitor(filler)

    receive do
      {:DOWN, ^ref, :process, _filler, _reason} ->
        case :ets.lookup(@table, key) do
          [{^key, {:value, value}}] ->
            value

          _gone ->
            :ets.delete_object(@table, claim)
            compute.()
        end
    end
  end
end
