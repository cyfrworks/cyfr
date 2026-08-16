# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.QueryCounter do
  @moduledoc """
  Count the repo queries a function issues, via `[:arca, :repo, :query]`
  telemetry.

  Only queries issued by the calling process are counted, so concurrent
  tests do not pollute each other's totals. Returns the function's result
  and `%{total: n, by_source: %{"table" => n}}` (source is the Ecto query
  source, `nil` for raw SQL).
  """

  @event [:arca, :repo, :query]

  @spec count((-> result)) :: {result, %{total: non_neg_integer(), by_source: map()}}
        when result: term()
  def count(fun) when is_function(fun, 0) do
    owner = self()
    handler_id = {__MODULE__, make_ref()}
    table = :ets.new(:query_counter, [:public, :duplicate_bag])

    :ok =
      :telemetry.attach(
        handler_id,
        @event,
        fn _event, _measurements, metadata, _config ->
          if self() == owner do
            :ets.insert(table, {:query, metadata[:source]})
          end
        end,
        nil
      )

    try do
      result = fun.()

      queries = :ets.tab2list(table)

      by_source =
        queries
        |> Enum.map(fn {:query, source} -> source end)
        |> Enum.frequencies()

      {result, %{total: length(queries), by_source: by_source}}
    after
      :telemetry.detach(handler_id)
      :ets.delete(table)
    end
  end

  @doc "Assert `fun` issues exactly `n` queries; returns the function's result."
  @spec assert_queries(non_neg_integer(), (-> result)) :: result when result: term()
  def assert_queries(n, fun) when is_integer(n) and is_function(fun, 0) do
    {result, %{total: total, by_source: by_source}} = count(fun)

    if total != n do
      raise ExUnit.AssertionError,
        message: "expected #{n} repo queries, got #{total} (by source: #{inspect(by_source)})"
    end

    result
  end
end
