# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Test.CodeLines do
  @moduledoc """
  The line filter behind Locus's architecture tests: Locus's own copy of
  `Prima.Test.CodeLines`, since its suite loads nothing of the control
  plane's. Everything below this moduledoc is that module's body, byte
  for byte, and `Cyfr.BoundariesTest` holds the two to it.
  """

  # `Foo.Bar.{A, B}` → the base and the brace body. Members are split on the
  # comma so a nested `Foo.{A.B, C}` expands to `Foo.A.B` and `Foo.C`.
  @multi_alias ~r/\b([A-Z]\w*(?:\.[A-Z]\w*)*)\.\{([^}]*)\}/

  # A documentation attribute whose value is prose. The whole opening line
  # goes: for a heredoc nothing but the delimiter is on it, and for a
  # one-liner the sentence is the line.
  @doc_attributes [:doc, :moduledoc, :typedoc, :shortdoc]

  # The tokens whose body is text rather than code. Interpolation inside
  # one is code, and is reached through the parts below.
  @text_tokens [:bin_string, :list_string, :bin_heredoc, :list_heredoc, :sigil]

  @doc """
  The kept code lines with their 1-based numbers: `[{line, n}]`.

  A line is code when Elixir's own tokenizer starts a token on it. That
  one rule is what excludes a heredoc's body, a charlist heredoc's body
  and a multi-line sigil's body — none of them carries a token start —
  and what excludes a comment line, which the tokenizer skips. A trailing
  comment is cut at the column the tokenizer reports it at, because a
  mention in a comment is prose and not a dependency.

  A string's text on a line that also carries code stays, because scans
  read it: the string-error ratchet counts `{:error, "…"}` sites and the
  environment-reading roster refuses a switch compared as `"true"`. Only
  a line a text body has to itself is dropped.

  Raises when the source does not tokenize, so a scan cannot pass by
  reading a file it could not parse.
  """
  @spec code_lines(String.t()) :: [{String.t(), pos_integer()}]
  def code_lines(source) do
    {tokens, comments} = tokenize!(source)
    code = code_line_numbers(tokens)
    prose = doc_line_numbers(tokens)

    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {_line, n} -> MapSet.member?(code, n) and not MapSet.member?(prose, n) end)
    |> Enum.map(fn {line, n} ->
      {line |> cut_comment(Map.get(comments, n)) |> expand_multi_alias(), n}
    end)
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

  @doc """
  Every module name the source NAMES, with the line it names it on.

  Read from the token stream rather than from the text, which is what
  makes it exact: a name written inside a string or a comment is prose and
  is not here, a name written inside an interpolation is code and
  is, and `alias Foo.{A, B}` is spelled out as `Foo.A` and `Foo.B`. A call
  on a root module (`EmissaryWeb.static_paths/0`) yields the root, because
  naming it is reaching for it.

  This is what the architecture rosters read. `code_lines/1` is the other
  view, for the scans that look for a sentence rather than a name.
  """
  @spec aliases(String.t()) :: [{String.t(), pos_integer()}]
  def aliases(source) do
    {tokens, _comments} = tokenize!(source)
    tokens |> Enum.flat_map(&[&1 | interpolated(&1)]) |> collect([])
  end

  defp collect([{:alias, {line, _column, _extra}, name} | rest], acc) do
    {segments, rest} = dotted(rest, [Atom.to_string(name)])
    base = segments |> Enum.reverse() |> Enum.join(".")

    case rest do
      [{:., _meta}, {:"{", _brace} | inside] ->
        {members, rest} = brace_members(inside, [], [])
        collect(rest, Enum.reduce(members, acc, &[{base <> "." <> &1, line} | &2]))

      _ ->
        collect(rest, [{base, line} | acc])
    end
  end

  defp collect([_token | rest], acc), do: collect(rest, acc)
  defp collect([], acc), do: acc |> Enum.reverse() |> Enum.uniq()

  defp dotted([{:., _meta}, {:alias, _pos, name} | rest], acc),
    do: dotted(rest, [Atom.to_string(name) | acc])

  defp dotted(rest, acc), do: {acc, rest}

  # The body of `Foo.{A, B.C}`: each member is a dotted name of its own.
  defp brace_members([{:"}", _meta} | rest], current, members),
    do: {Enum.reverse(add_member(current, members)), rest}

  defp brace_members([{:",", _meta} | rest], current, members),
    do: brace_members(rest, [], add_member(current, members))

  defp brace_members([{:alias, _meta, name} | rest], current, members),
    do: brace_members(rest, [Atom.to_string(name) | current], members)

  defp brace_members([_token | rest], current, members),
    do: brace_members(rest, current, members)

  defp brace_members([], current, members),
    do: {Enum.reverse(add_member(current, members)), []}

  defp add_member([], members), do: members
  defp add_member(current, members), do: [current |> Enum.reverse() |> Enum.join(".") | members]

  @doc "Just the kept code lines, in file order."
  @spec lines(String.t()) :: [String.t()]
  def lines(source), do: source |> code_lines() |> Enum.map(&elem(&1, 0))

  # The tokens in file order, and the first comment column on each line.
  # `preserve_comments` is how the tokenizer reports a comment it would
  # otherwise drop; the accumulator is a process-dictionary key of this
  # call alone, so two scans in one process cannot see each other's.
  defp tokenize!(source) do
    key = {__MODULE__, make_ref()}
    Process.put(key, %{})

    collect = fn line, column, _tokens, _comment, _rest ->
      Process.put(key, Map.put_new(Process.get(key), line, column))
      :ok
    end

    result = :elixir_tokenizer.tokenize(String.to_charlist(source), 1, preserve_comments: collect)
    comments = Process.delete(key)

    case result do
      {:ok, _line, _column, _warnings, tokens, _terminators} -> {Enum.reverse(tokens), comments}
      other -> raise "source does not tokenize: #{inspect(other, limit: 5)}"
    end
  end

  defp code_line_numbers(tokens) do
    tokens
    |> Enum.reduce(MapSet.new(), fn token, acc ->
      case line_of(token) do
        nil -> acc
        line -> acc |> MapSet.put(line) |> MapSet.union(code_line_numbers(interpolated(token)))
      end
    end)
  end

  # `:eol` is the newline that ends a construct, not a token on the line
  # it is reported at: a heredoc's closing delimiter carries one and is
  # not code.
  defp line_of({:eol, _meta}), do: nil

  defp line_of(token) when is_tuple(token) and tuple_size(token) >= 2 do
    case elem(token, 1) do
      {line, _column, _extra} when is_integer(line) -> line
      _ -> nil
    end
  end

  defp line_of(_token), do: nil

  # The tokens of every `#{…}` inside a text token, which are code on
  # whatever line they are written.
  defp interpolated(token) when is_tuple(token) and tuple_size(token) >= 3 do
    if elem(token, 0) in @text_tokens do
      token
      |> parts()
      |> Enum.flat_map(fn
        {_start, _stop, tokens} when is_list(tokens) -> tokens
        _literal -> []
      end)
    else
      []
    end
  end

  defp interpolated(_token), do: []

  defp parts({:bin_string, _meta, parts}), do: parts
  defp parts({:list_string, _meta, parts}), do: parts
  defp parts({:bin_heredoc, _meta, _indent, parts}), do: parts
  defp parts({:list_heredoc, _meta, _indent, parts}), do: parts
  defp parts({:sigil, _meta, _name, parts, _modifiers, _indent, _delimiter}), do: parts
  defp parts(_token), do: []

  # `@doc`, `@moduledoc`, `@typedoc` and `@shortdoc` followed by text, all
  # on one line: the attribute's own line is prose whether the text ends
  # there or opens a heredoc.
  defp doc_line_numbers(tokens) do
    tokens
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.reduce(MapSet.new(), fn
      [{:at_op, {line, _, _}, :@}, {:identifier, {line, _, _}, name}, text], acc
      when name in @doc_attributes ->
        if is_tuple(text) and elem(text, 0) in @text_tokens and line_of(text) == line,
          do: MapSet.put(acc, line),
          else: acc

      _chunk, acc ->
        acc
    end)
  end

  defp cut_comment(line, nil), do: line
  defp cut_comment(line, column), do: String.slice(line, 0, column - 1)
end
