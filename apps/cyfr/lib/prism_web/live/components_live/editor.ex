# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ComponentsLive.Editor do
  @moduledoc """
  Pure data-transformation helpers extracted from `PrismWeb.ComponentsLive`.

  These functions perform validation, parsing, serialization and formatting on
  plain data only — they never touch the socket, assigns, or rendered markup.
  """

  defdelegate build_ref_from_parts(type, publisher, name, version),
    to: Compendium.Catalogue,
    as: :build_ref

  def format_push_error(reason) when is_binary(reason), do: "Push failed: #{reason}"

  def format_push_error({:error, msg}) when is_binary(msg),
    do: "Push failed: #{msg}"

  def format_push_error(reason), do: "Push failed: " <> PrismWeb.MCPHelpers.error_message(reason)

  def type_sort_order("catalyst"), do: 0
  def type_sort_order("reagent"), do: 1
  def type_sort_order("formula"), do: 2
  def type_sort_order("tincture"), do: 3
  def type_sort_order(_), do: 4
end
