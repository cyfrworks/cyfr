# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ToolPattern do
  @moduledoc """
  The one tool-pattern grammar: `"*"` | exact name | `"prefix.*"`.

  A `prefix.*` pattern matches on a dot boundary — `"component.*"` matches
  `"component.get"`, never `"component"` itself and never
  `"componentx.get"`. A bare `prefix*` (no dot) is not a pattern: substring
  matching would let a grant like `read*` cover a hostile upstream server's
  `readwrite_danger`, so anything with a `*` placed other than as the whole
  pattern or a trailing `.*` is invalid.

  Used for consent tool expansion and external
  tool-server `tool_patterns`. External MCP tool names often carry no dot
  segments; for those, grants are exact names or `"*"` by construction.
  """

  @doc """
  Whether `value` matches `pattern` under the grammar. An invalid pattern
  matches nothing.
  """
  @spec matches?(String.t(), String.t()) :: boolean()
  def matches?("*", value) when is_binary(value), do: true

  def matches?(pattern, value) when is_binary(pattern) and is_binary(value) do
    cond do
      not valid?(pattern) -> false
      pattern == value -> true
      String.ends_with?(pattern, ".*") -> String.starts_with?(value, dot_prefix(pattern))
      true -> false
    end
  end

  @doc """
  Whether `pattern` is well-formed: `"*"`, a non-empty literal without `*`,
  or `<prefix>.*` with a non-empty, `*`-free prefix.
  """
  @spec valid?(term()) :: boolean()
  def valid?("*"), do: true

  def valid?(pattern) when is_binary(pattern) and pattern != "" do
    case String.split(pattern, "*") do
      [_literal] -> true
      [prefix, ""] -> String.ends_with?(prefix, ".") and prefix != "."
      _ -> false
    end
  end

  def valid?(_), do: false

  @doc """
  Expand `patterns` against a catalog of concrete names: `"*"` takes the
  whole catalog, `prefix.*` its dot-boundary matches, an exact name only
  itself and only if the catalog contains it. Unknown or invalid patterns
  expand to nothing — a consent blob may hold entries for tools that no
  longer exist, and an expansion is an allowlist, so dropping them is the
  fail-safe direction.
  Result is sorted and unique.
  """
  @spec expand([String.t()], [String.t()]) :: [String.t()]
  def expand(patterns, catalog) when is_list(patterns) and is_list(catalog) do
    patterns
    |> Enum.flat_map(fn pattern ->
      cond do
        pattern == "*" ->
          catalog

        is_binary(pattern) and String.ends_with?(pattern, ".*") and valid?(pattern) ->
          Enum.filter(catalog, &String.starts_with?(&1, dot_prefix(pattern)))

        pattern in catalog ->
          [pattern]

        true ->
          []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp dot_prefix(pattern), do: String.slice(pattern, 0..-3//1) <> "."
end
