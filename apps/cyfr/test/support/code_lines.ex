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

  Canonical copy: `apps/cyfr/test/support/code_lines.ex`. The other apps
  load it through a `Code.require_file` shim (the `component_helpers`
  precedent) so per-app `mix test` still works.
  """

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

      {if(keep?, do: [{line, n} | kept], else: kept), now_inside?}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc "Just the kept code lines, in file order."
  @spec lines(String.t()) :: [String.t()]
  def lines(source), do: source |> code_lines() |> Enum.map(&elem(&1, 0))
end
