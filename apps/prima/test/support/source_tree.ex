# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Test.SourceTree do
  @moduledoc """
  One read per source file per suite run, shared by every architecture test.

  Shares source reads across roster and inventory tests.

  `files!/2` is how a scan finds its files: a glob that matches nothing
  raises, so a scan pointed at a moved or misspelled tree cannot pass by
  reading nothing. It needs no table.

  `read/1` memoizes files in an ETS table owned by the test-runner process;
  each app's `test_helper.exs` calls `ensure_table/0` before tests start,
  and the umbrella runs them all in one VM, so the call is idempotent.

  Falls back to a plain read when the table is absent — Opus and Locus keep
  copies of their own and do not create it.
  """

  alias Prima.Test.CodeLines

  @table :prima_test_source_tree

  @doc false
  def table, do: @table

  @doc """
  Create the memo table, once per VM.

  Every app's `test_helper.exs` calls it, and the umbrella runs them all in
  one VM, so the second call must find the table rather than raise. The
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

  @doc """
  `File.read!/1`, memoized for the life of the suite.

  Source files do not change while the suite runs, so a second reader gets
  the first reader's bytes. Two processes racing to fill the same key both
  insert the same value, which is harmless.
  """
  @spec read(Path.t()) :: String.t()
  def read(path) do
    case :ets.whereis(@table) do
      :undefined ->
        File.read!(path)

      _ ->
        case :ets.lookup(@table, path) do
          [{^path, source}] ->
            source

          [] ->
            source = File.read!(path)
            :ets.insert(@table, {path, source})
            source
        end
    end
  end

  @doc """
  `Prima.Test.CodeLines.code_lines/1` over a file, memoized beside its
  source.

  Classifying a file costs a tokenize, and the architecture rosters read
  the same trees several times over; the memo makes the second read free.
  Falls back to classifying on the spot when the table is absent.
  """
  @spec code_lines(Path.t()) :: [{String.t(), pos_integer()}]
  def code_lines(path), do: memo({:code_lines, path}, fn -> CodeLines.code_lines(read(path)) end)

  @doc """
  `Prima.Test.CodeLines.aliases/1` over a file, memoized beside its source.

  Every module name the file names, with its line — the view the
  architecture rosters read.
  """
  @spec aliases(Path.t()) :: [{String.t(), pos_integer()}]
  def aliases(path), do: memo({:aliases, path}, fn -> CodeLines.aliases(read(path)) end)

  defp memo(key, compute) do
    case :ets.whereis(@table) do
      :undefined ->
        compute.()

      _ ->
        case :ets.lookup(@table, key) do
          [{^key, value}] ->
            value

          [] ->
            value = compute.()
            :ets.insert(@table, {key, value})
            value
        end
    end
  end

  @doc "Every `{path, source}` under `glob`, each file read at most once."
  @spec sources(String.t()) :: [{Path.t(), String.t()}]
  def sources(glob) do
    glob
    |> files!()
    |> Enum.map(&{&1, read(&1)})
  end
end
