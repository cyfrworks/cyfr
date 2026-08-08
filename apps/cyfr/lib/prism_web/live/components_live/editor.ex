# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ComponentsLive.Editor do
  @moduledoc """
  Pure data-transformation helpers extracted from `PrismWeb.ComponentsLive`.

  These functions perform validation, parsing, serialization and formatting on
  plain data only — they never touch the socket, assigns, or rendered markup.
  """

  # Build a component reference from its parts: e.g.
  # ("catalyst", "moonmoon69", "supabase", "1.0.0") -> "catalyst:moonmoon69.supabase:1.0.0"
  def build_ref_from_parts(type, publisher, name, version) do
    base = if publisher && publisher != "", do: "#{publisher}.#{name}", else: name
    ref = if type && type != "", do: "#{type}:#{base}", else: base
    if version, do: "#{ref}:#{version}", else: ref
  end

  def format_push_error(reason) when is_binary(reason), do: "Push failed: #{reason}"

  def format_push_error({:error, msg}) when is_binary(msg),
    do: "Push failed: #{msg}"

  def format_push_error(reason), do: "Push failed: #{inspect(reason)}"

  def type_sort_order("catalyst"), do: 0
  def type_sort_order("reagent"), do: 1
  def type_sort_order("formula"), do: 2
  def type_sort_order("tincture"), do: 3
  def type_sort_order(_), do: 4
end
