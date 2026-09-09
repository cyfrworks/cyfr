# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.MapUtil do
  @moduledoc """
  Small map- and keyword-building helpers shared across the umbrella.

  Adds entries only when their values are present.
  """

  @doc """
  Put `value` under `key` only when it is present — `nil` and the empty
  string both leave the map untouched. `""` counts as absent because these
  maps are wire shapes (OCI annotations, URL query params) where an empty
  string is an unfilled field, not a value to emit.
  """
  @spec put_present(map(), term(), term()) :: map()
  def put_present(map, _key, nil), do: map
  def put_present(map, _key, ""), do: map
  def put_present(map, key, value), do: Map.put(map, key, value)

  @doc """
  The keyword twin: append `key` only when `value` is not `nil`.

  Lives here rather than in `Arca.QueryHelpers` because the callers building
  option lists are not building queries. `Cyfr.Network` — the SSOT for
  outbound HTTP — imported it from the row plane's fail-closed tenant-scoping
  helpers to assemble Req options, which gave the network seam a compile-time
  edge into storage for three lines of `Keyword.put`.

  Unlike `put_present/3`, `""` is kept: a keyword option list is not a wire
  shape, and an empty string can be a deliberate value there.
  """
  @spec put_unless_nil(keyword(), atom(), term()) :: keyword()
  def put_unless_nil(opts, _key, nil), do: opts
  def put_unless_nil(opts, key, value), do: Keyword.put(opts, key, value)
end
