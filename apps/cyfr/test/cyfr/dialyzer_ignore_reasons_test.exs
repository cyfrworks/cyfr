# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.DialyzerIgnoreReasonsTest do
  @moduledoc """
  Every Dialyzer filter in `.dialyzer_ignore.exs` carries the reason its
  warning is accepted: a comment on the line, or the lines, directly above
  the entry, each entry its own. An entry with no comment above it, one
  whose comment is separated from it by a blank line or another entry, or
  one whose only comment is another line's trailing comment, is bare and
  refused.

  The file is read as code, the way Dialyxir reads it: each element of its
  one list is an entry, a `{file, kind}` tuple or a regex over the raw
  warning text, and the count read here is the count Dialyxir evaluates.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @ignore_file Path.join(@repo_root, ".dialyzer_ignore.exs")

  test "every filter in .dialyzer_ignore.exs carries a reason comment" do
    text = File.read!(@ignore_file)
    {filters, _binding} = Code.eval_string(text, [], file: @ignore_file)

    assert is_list(filters) and filters != []
    assert length(entries(text)) == length(filters)

    assert bare_entries(text) == [],
           "#{@ignore_file} has entries without a reason comment directly above them, " <>
             "at lines #{inspect(bare_entries(text))}"
  end

  test "a planted {file, kind} entry without a reason is refused" do
    {text, line} = plant_after_list_open(~s|  {"lib/planted.ex", :pattern_match},|)
    assert bare_entries(text) == [line]
  end

  test "a planted regex entry without a reason is refused" do
    {text, line} = plant_after_list_open(~S|  ~r{lib/planted\.ex:\d+:\d+:.*opaque},|)
    assert bare_entries(text) == [line]
  end

  test "an entry under another entry's reason is refused" do
    text = File.read!(@ignore_file)
    [first | _] = entries(text)
    lines = String.split(text, "\n")
    # The first entry's last line: the line before the next comment or entry.
    last = first_entry_end(lines, first)
    planted = List.insert_at(lines, last, ~s|  {"lib/planted.ex", :guard_fail},|)

    assert bare_entries(Enum.join(planted, "\n")) == [last + 1]
  end

  test "a reason separated from its entry by a blank line is refused" do
    text = File.read!(@ignore_file)
    [first | _] = entries(text)
    planted = text |> String.split("\n") |> List.insert_at(first - 1, "") |> Enum.join("\n")

    assert bare_entries(planted) == [first + 1]
  end

  test "another entry's trailing comment is no reason" do
    text = File.read!(@ignore_file)
    [first | _] = entries(text)
    lines = String.split(text, "\n")
    last = first_entry_end(lines, first)

    planted =
      lines
      |> List.update_at(last - 1, &(&1 <> " # trailing"))
      |> List.insert_at(last, ~s|  {"lib/planted.ex", :guard_fail},|)

    assert bare_entries(Enum.join(planted, "\n")) == [last + 1]
  end

  # The first line of each entry of the file's one list, in order.
  defp entries(text) do
    {:__block__, _meta, [list]} =
      Code.string_to_quoted!(text, literal_encoder: &{:ok, {:__block__, &2, [&1]}})

    assert is_list(list), "the file is not one list of filters"

    Enum.map(list, fn
      {:__block__, meta, [{_file, _kind}]} -> meta[:line]
      {:sigil_r, meta, _args} -> meta[:line]
      other -> flunk("not a {file, kind} tuple or a regex: #{Macro.to_string(other)}")
    end)
  end

  defp bare_entries(text) do
    {_quoted, comments} = Code.string_to_quoted_with_comments!(text)
    commented = MapSet.new(comments, & &1.line)
    lines = text |> String.split("\n") |> List.to_tuple()

    text
    |> entries()
    |> Enum.reject(fn line -> line > 1 and reason_line?(lines, commented, line - 1) end)
  end

  # A reason is a comment that is the whole line, with text after the `#`.
  defp reason_line?(lines, commented, line) do
    MapSet.member?(commented, line) and
      Regex.match?(~r/^\s*#\s*\S/, elem(lines, line - 1))
  end

  defp plant_after_list_open(entry) do
    lines = File.read!(@ignore_file) |> String.split("\n")
    open = Enum.find_index(lines, &(&1 == "[")) + 1
    {lines |> List.insert_at(open, entry) |> Enum.join("\n"), open + 1}
  end

  defp first_entry_end(lines, first) do
    lines
    |> Enum.drop(first)
    |> Enum.find_index(&Regex.match?(~r/^\s*(#|\{|~r)/, &1))
    |> Kernel.+(first)
  end
end
