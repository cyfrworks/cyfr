# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.TextTest do
  @moduledoc """
  A cut fits the byte budget, never splits a character, and appends the
  marker only when something was cut — the marker's bytes are the
  caller's to budget for.
  """

  use ExUnit.Case, async: true

  alias Aqua.Text

  test "text that fits is returned as it is, with no marker" do
    assert Text.cut("hello", 5) == "hello"
    assert Text.cut("hello", 6, "[cut]") == "hello"
    assert Text.cut("", 0) == ""
    assert Text.cut("é", 2) == "é"
  end

  test "text over the budget is cut to it and marked" do
    assert Text.cut("hello world", 5) == "hello…"
    assert Text.cut("hello world", 5, " [cut]") == "hello [cut]"
  end

  test "a cut inside a multibyte character drops the whole character" do
    # "é" is two bytes: a budget of 3 lands inside the second one.
    assert Text.cut("ééé", 3, "") == "é"
    assert Text.cut("aé", 2, "") == "a"
    # A four-byte character cut anywhere inside leaves nothing of it.
    for max <- 1..3, do: assert(Text.cut("😀x", max, "") == "")
    assert Text.cut("😀x", 4, "") == "😀"
  end

  test "a budget of zero keeps nothing but the marker" do
    assert Text.cut("anything", 0) == "…"
    assert Text.cut("anything", 0, "") == ""
    assert Text.cut("", 0, "[cut]") == ""
  end

  test "the marker is not counted against the budget" do
    marker = "\n\n[cut — the outcome was longer than 64 KiB]"
    cut = Text.cut(String.duplicate("a", 100), 10, marker)

    assert cut == String.duplicate("a", 10) <> marker
    assert byte_size(cut) == 10 + byte_size(marker)
  end

  test "the output is always valid UTF-8, whatever the budget" do
    text = "aé😀中b" |> String.duplicate(5)

    for max <- 0..(byte_size(text) + 2), marker <- ["", "…"] do
      cut = Text.cut(text, max, marker)
      assert String.valid?(cut), "max #{max} split a character"
      assert byte_size(cut) <= max + byte_size(marker)
    end
  end

  test "a negative budget is not a budget" do
    assert_raise FunctionClauseError, fn -> Text.cut("x", -1) end
  end
end
