# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ToolPattern do
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

  A name that begins with `@` is reserved (`reserved?/1`): a server's
  resources and prompts, `@resources` and `@prompts`, which no MCP tool's
  name can spell. It is matched only by naming it, never by `"*"` or a
  `prefix.*`, so no pattern a grant held before a reserved name existed
  covers one.
  """

  @doc """
  Whether `value` matches `pattern` under the grammar. An invalid pattern
  matches nothing, and a reserved name only itself.
  """
  @spec matches?(String.t(), String.t()) :: boolean()
  def matches?("*", value) when is_binary(value), do: not reserved?(value)

  def matches?(pattern, value) when is_binary(pattern) and is_binary(value) do
    cond do
      not valid?(pattern) -> false
      pattern == value -> true
      reserved?(value) -> false
      String.ends_with?(pattern, ".*") -> String.starts_with?(value, dot_prefix(pattern))
      true -> false
    end
  end

  @doc "Whether `name` is a reserved name, one that begins with `@`."
  @spec reserved?(String.t()) :: boolean()
  def reserved?(name) when is_binary(name), do: String.starts_with?(name, "@")

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
  Expand `patterns` against a catalog of concrete names, each taking what
  it matches (`matches?/2`): `"*"` the whole catalog but its reserved
  names, `prefix.*` its dot-boundary matches, an exact name only itself
  and only if the catalog contains it. Unknown or invalid patterns
  expand to nothing — a consent blob may hold entries for tools that no
  longer exist, and an expansion is an allowlist, so dropping them is the
  fail-safe direction.
  Result is sorted and unique.
  """
  @spec expand([String.t()], [String.t()]) :: [String.t()]
  def expand(patterns, catalog) when is_list(patterns) and is_list(catalog) do
    patterns
    |> Enum.flat_map(fn pattern ->
      if valid?(pattern), do: Enum.filter(catalog, &matches?(pattern, &1)), else: []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp dot_prefix(pattern), do: String.slice(pattern, 0..-3//1) <> "."
end
