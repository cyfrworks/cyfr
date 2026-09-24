# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.CodeLinesTest do
  @moduledoc """
  What the one line filter keeps, and what it drops.

  Every architecture roster reads the tree through `code_lines/1`, so its
  mistakes are theirs: a line it drops is a dependency no roster sees, and
  a line of prose it keeps is a dependency that is not there.

  The filter that came before this one counted `\"""` occurrences per line
  to decide whether it was inside a heredoc. The cases below are the ones
  that counting got wrong — a `\"""` written inside a comment turned the
  rest of the file into heredoc body, which is a roster that silently
  stops reading — and the ones it got right, which still hold.
  """

  use ExUnit.Case, async: true

  alias Prima.Test.CodeLines

  defp names(source) do
    source
    |> CodeLines.code_lines()
    |> Enum.flat_map(fn {line, _n} -> ~r/Ns\.[A-Za-z]+/ |> Regex.scan(line) |> List.flatten() end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp numbers(source), do: source |> CodeLines.code_lines() |> Enum.map(&elem(&1, 1))

  describe "what the counting filter got right, and this one keeps" do
    test "a heredoc body is prose" do
      source = ~S'''
      defmodule A do
        @moduledoc """
        Ns.InModuleDoc
        """

        def a, do: Ns.InCode
      end
      '''

      assert names(source) == ["Ns.InCode"]
    end

    test "a whole-line comment is prose" do
      assert names("# Ns.InComment\nx = Ns.InCode\n") == ["Ns.InCode"]
    end

    test "a one-line documentation attribute is prose" do
      source = ~S'''
      defmodule A do
        @doc "Ns.InDoc"
        def a, do: Ns.InCode
      end
      '''

      assert names(source) == ["Ns.InCode"]
    end

    test "a multi-alias is spelled out so a scan sees each member" do
      assert names("alias Ns.{One, Two}\n") == ["Ns.One", "Ns.Two"]
      assert CodeLines.expand_multi_alias("alias Ns.{A.B, C}") == "alias Ns.A.B Ns.C"
    end

    test "interpolated code inside a string is code" do
      assert names(~S|x = "#{Ns.Interpolated.f()}"| <> "\n") == ["Ns.Interpolated"]
    end

    test "line numbers are the file's, 1-based" do
      assert numbers("x = 1\n# comment\ny = 2\n") == [1, 3]
    end
  end

  describe "what counting got wrong" do
    # The fault that matters: the rest of the file was read as heredoc
    # body, so every reach below the comment was invisible.
    test ~S(a comment holding """ does not make the rest of the file prose) do
      source = """
      defmodule A do
        # a comment holding \"\"\" in it
        def a, do: Ns.BelowTheComment
      end
      """

      assert names(source) == ["Ns.BelowTheComment"]
    end

    test "a trailing comment is prose, cut at the column the tokenizer reports" do
      assert names("call(x) # Ns.InTrailingComment\n") == []
      assert CodeLines.lines("call(x) # trailing\n") == ["call(x) "]
    end

    test "a charlist heredoc's body is prose" do
      source = ~S'''
      x = ~c"""
      Ns.InCharlistHeredoc
      """

      y = Ns.InCode
      '''

      assert names(source) == ["Ns.InCode"]
    end

    # The opening line carries the sigil's token and stays, text and all,
    # exactly as a one-line string's content does; the lines the body has
    # to itself are what go.
    test "a multi-line sigil's body is prose" do
      source = "x = ~s|Ns.OnTheOpeningLine\nNs.InTheSigilBody|\ny = Ns.InCode\n"

      assert names(source) == ["Ns.InCode", "Ns.OnTheOpeningLine"]
    end

    test "a string's text on a code line stays, so a scan can read the sentence" do
      assert CodeLines.lines(~S|{:error, "not found"}| <> "\n") == [~S|{:error, "not found"}|]
    end

    test "a @typedoc one-liner is prose, as @doc and @moduledoc are" do
      source = ~S'''
      defmodule A do
        @typedoc "Ns.InTypedoc"
        @type t :: Ns.InCode.t()
      end
      '''

      assert names(source) == ["Ns.InCode"]
    end
  end

  test "a source that does not tokenize raises rather than reading nothing" do
    assert_raise RuntimeError, ~r/does not tokenize/, fn ->
      CodeLines.code_lines(~S|x = "unterminated| <> "\n")
    end
  end
end
