# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.CodeLines do
  @moduledoc """
  The one line filter behind every architecture roster test.

  Eight tests each carried a private copy, in three quietly divergent
  variants — some stripped one-line `@doc` strings and some did not, so a
  `@doc "pinned by Sanctum.VaultTest"` counted as a reach in half the
  rosters, while every copy's comment claimed it matched the siblings.
  One spelling, the strict one: heredoc prose, `#` comments and one-line
  `@doc`/`@moduledoc` strings are ABOUT a dependency, never a reach.

  A kept line also has its multi-aliases expanded — `alias Foo.{A, B}`
  becomes `alias Foo.A Foo.B` — because every roster matches a fully
  qualified name by regex, and after `Foo.` a `{` is not `[A-Z]`. A plain
  `alias Foo.Bar` names itself and so stays visible; the braced form named
  nothing a roster could see, and `Sanctum.Provisioning` had been reaching
  `Compendium.AutoIndexer` and `Compendium.Pull` through one for long
  enough that `Compendium.ReverseSurfaceTest` passed while the license
  boundary it guards had widened by two namespaces. Expanding here rather
  than in each test keeps the twelve matchers reading one filter.

  Canonical copy: `apps/cyfr/test/support/code_lines.ex`. The other apps
  load it through a `Code.require_file` shim (the `component_helpers`
  precedent) so per-app `mix test` still works.
  """

  # `Foo.Bar.{A, B}` → the base and the brace body. Members are split on the
  # comma so a nested `Foo.{A.B, C}` expands to `Foo.A.B` and `Foo.C`.
  @multi_alias ~r/\b([A-Z]\w*(?:\.[A-Z]\w*)*)\.\{([^}]*)\}/

  @doc "The kept code lines with their 1-based numbers: `[{line, n}]`."
  @spec code_lines(String.t()) :: [{String.t(), pos_integer()}]
  def code_lines(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], false}, fn {line, n}, {kept, in_heredoc?} ->
      toggles =
        line
        |> String.graphemes()
        |> Enum.chunk_every(3, 1, :discard)
        |> Enum.count(&(&1 == ["\"", "\"", "\""]))

      now_inside? = if rem(toggles, 2) == 1, do: not in_heredoc?, else: in_heredoc?

      keep? =
        not in_heredoc? and not now_inside? and
          not String.match?(line, ~r/^\s*#/) and
          not String.match?(line, ~r/^\s*@(module)?doc\s+"/)

      {if(keep?, do: [{expand_multi_alias(line), n} | kept], else: kept), now_inside?}
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

  @doc "Just the kept code lines, in file order."
  @spec lines(String.t()) :: [String.t()]
  def lines(source), do: source |> code_lines() |> Enum.map(&elem(&1, 0))
end
