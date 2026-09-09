# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.SourceTree do
  @moduledoc """
  One read per source file per suite run, shared by every architecture test.

  Shares source reads across roster and inventory tests.

  `read/1` memoizes files in an ETS table owned by the test-runner process.
  `test_helper.exs` creates the table before tests start.

  Falls back to a plain read when the table is absent — the opus and locus
  suites load this module through a `Code.require_file` shim and do not
  create it.
  """

  @table :cyfr_test_source_tree

  @doc false
  def table, do: @table

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

  @doc "Every `{path, source}` under `glob`, each file read at most once."
  @spec sources(String.t()) :: [{Path.t(), String.t()}]
  def sources(glob) do
    glob
    |> Path.wildcard()
    |> Enum.map(&{&1, read(&1)})
  end
end
