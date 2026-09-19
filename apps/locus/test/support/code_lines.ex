# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Test.CodeLines do
  @moduledoc """
  The line filter behind Locus's architecture tests: the code lines of a
  source file, without heredocs, line comments and one-line documentation
  attributes, and with a multi-alias spelled out (`alias Foo.{A, B}`
  becomes `alias Foo.A Foo.B`), so a scan for fully qualified names sees
  both plain and braced aliases. Locus's own, since its suite loads
  nothing of the control plane's.
  """

  # `Foo.Bar.{A, B}` → the base and the brace body. Members are split on the
  # comma so a nested `Foo.{A.B, C}` expands to `Foo.A.B` and `Foo.C`.
  @multi_alias ~r/\b([A-Z]\w*(?:\.[A-Z]\w*)*)\.\{([^}]*)\}/

  @doc "The kept code lines, in file order."
  @spec lines(String.t()) :: [String.t()]
  def lines(source) do
    source
    |> String.split("\n")
    |> Enum.reduce({[], false}, fn line, {kept, in_heredoc?} ->
      toggles =
        line
        |> String.graphemes()
        |> Enum.chunk_every(3, 1, :discard)
        |> Enum.count(&(&1 == ["\"", "\"", "\""]))

      now_inside? = if rem(toggles, 2) == 1, do: not in_heredoc?, else: in_heredoc?

      keep? =
        not in_heredoc? and not now_inside? and
          not String.match?(line, ~r/^\s*#/) and
          not String.match?(line, ~r/^\s*@(module|type)?doc\s+"/)

      {if(keep?, do: [expand_multi_alias(line) | kept], else: kept), now_inside?}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc "`Foo.{A, B}` spelled out as `Foo.A Foo.B`, so a regex can see both."
  @spec expand_multi_alias(String.t()) :: String.t()
  def expand_multi_alias(line) do
    Regex.replace(@multi_alias, line, fn _match, base, members ->
      members
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map_join(" ", &"#{base}.#{&1}")
    end)
  end
end
