# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.MapUtil do
  @moduledoc """
  Small map-building helpers shared across the umbrella.

  The map twin of `Arca.QueryHelpers.maybe_put/3` (which builds keyword
  lists): one spelling of "add the entry only when there is a value", so
  the copies that used to live beside every wire-map builder collapse
  into one.
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
end
