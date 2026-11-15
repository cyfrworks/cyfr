# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.BrowserOwnerBoundaryTest do
  @moduledoc """
  The person's browser is a third owner of a program's session, beside a
  person at a screen and a turn, and only `Opus.Browser` acts as it: over
  the code of every app's `lib`, read as Elixir's own syntax tree, the
  owner's constructor (`Opus.Programs.browser/2`) is called in
  `lib/opus/browser.ex` alone, and the caller it builds, a tuple led by
  `:browser`, is written nowhere but in `Opus.Programs` itself.
  """

  use ExUnit.Case, async: true

  @moduletag :sqlite

  @root Path.expand("../../../..", __DIR__)
  @browser "apps/cyfr/lib/opus/browser.ex"
  @programs "apps/cyfr/lib/opus/programs.ex"

  defp lib_asts do
    for dir <- Prima.Test.SourceTree.app_libs(@root),
        file <- Prima.Test.SourceTree.files!(Path.join([@root, dir, "**/*.ex"])),
        do: {Path.relative_to(file, @root), Code.string_to_quoted!(File.read!(file))}
  end

  defp found(ast, match?) do
    {_ast, hits} =
      Macro.prewalk(ast, [], fn node, hits ->
        if match?.(node), do: {node, [node | hits]}, else: {node, hits}
      end)

    hits
  end

  # `Opus.Programs.browser(…)`, or `Programs.browser(…)` under an alias.
  defp constructs?({{:., _, [{:__aliases__, _, aliases}, :browser]}, _, [_, _]}),
    do: List.last(aliases) == :Programs

  defp constructs?(_node), do: false

  # A three-element tuple led by `:browser`: the owner's caller.
  defp owner_tuple?({:{}, _, [:browser, _, _]}), do: true
  defp owner_tuple?(_node), do: false

  test "only Opus.Browser builds the browser's owner" do
    asts = lib_asts()
    assert length(asts) > 100, "the scan read the source tree"

    callers = for {rel, ast} <- asts, found(ast, &constructs?/1) != [], do: rel
    assert callers == [@browser]
  end

  test "the owner's caller tuple is written in Opus.Programs alone" do
    writers = for {rel, ast} <- lib_asts(), found(ast, &owner_tuple?/1) != [], do: rel
    assert writers == [@programs]
  end

  test "the scan finds a planted construction and a planted tuple" do
    planted =
      Code.string_to_quoted!("""
      defmodule Planted do
        alias Opus.Programs
        def a(x, y), do: Programs.browser(x, y)
        def b(x, y), do: {:browser, x, y}
      end
      """)

    assert [_] = found(planted, &constructs?/1)
    assert [_] = found(planted, &owner_tuple?/1)
  end
end
