# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.EnvFiles do
  @moduledoc """
  The `.env` files a `cyfr` boot reads (`config/runtime.exs`), read by
  Dotenvy with every value literal.

  Dotenvy runs the command inside a `$(…)` in an unquoted or double-quoted
  value and puts its output in the value's place. A boot runs nothing an
  operator's file says: each `$(…)` stays in the value as written, so a
  secret that happens to contain one is read as the secret. A single-quoted
  value is literal throughout.

  A `$(` closes on the physical line that opens it, or the boot is
  refused, naming the file and the line and never the value; so is an
  empty `$()`. Unchecked, Dotenvy reads an open `$(` on through the
  following lines and the settings on them up to the next `)`, and it trims
  the brackets' contents before anything sees them, line breaks included,
  so the line is decided first: before Dotenvy's read, each line holding a
  `$(` is parsed as the last of the file's opening lines, with the variables
  the files before it assigned, as Dotenvy will read it. Dotenvy trims the
  space just inside the brackets of a kept `$( … )`, which it reads as a
  command and its arguments: `$( id )` is read as `$(id)`.
  """

  @parser Dotenvy.Parser

  @doc """
  `Dotenvy.source!/2` with every `$(…)` kept as written, refusing a `$(` it
  cannot keep by the file and line that open it. Every other option and
  failure is Dotenvy's own.
  """
  @spec source!(Dotenvy.input_source() | [Dotenvy.input_source()], keyword()) ::
          %{optional(String.t()) => String.t()}
  def source!(inputs, opts \\ [])

  def source!(input, opts) when is_binary(input) or is_map(input), do: source!([input], opts)

  def source!(inputs, opts) when is_list(inputs) do
    refuse_unkept!(inputs, %{})

    case parse(fn -> Dotenvy.source(inputs, Keyword.put(opts, :sys_cmd_fn, &kept/3)) end) do
      {:ok, vars} -> vars
      {:error, error} -> raise error
      :unclosed -> raise "[Cyfr] FATAL: a $( in the .env files is not closed on its line"
    end
  end

  # The command a `$(…)` names, given back as it was written. Every `$(` has
  # been seen closed on its own line before Dotenvy reads the files, so its
  # text carries no line break; one that did is refused all the same.
  defp kept(command, args, _opts) do
    text = Enum.join([command | args], " ")
    if String.contains?(text, "\n"), do: throw(:unclosed), else: {"$(" <> text <> ")", 0}
  end

  defp parse(fun) do
    fun.()
  catch
    :throw, :unclosed -> :unclosed
  end

  # Walks the inputs as Dotenvy reads them: a map's variables join those
  # assigned so far, a missing file is passed over, and each file is read
  # with the variables before it. The first file that fails another way
  # ends the walk, and Dotenvy's own read reports it.
  defp refuse_unkept!([], _vars), do: :ok

  defp refuse_unkept!([map | rest], vars) when is_map(map),
    do: refuse_unkept!(rest, Map.merge(vars, map))

  defp refuse_unkept!([path | rest], vars) when is_binary(path) do
    # arca:bypass-ok=B — the operator's .env file, read by the boot's
    # runtime configuration before Arca is configured.
    case File.read(path) do
      {:ok, contents} ->
        refuse_lines!(path, contents, vars)

        case read(contents, vars) do
          {:ok, assigned} -> refuse_unkept!(rest, Map.merge(vars, assigned))
          _failure -> :ok
        end

      {:error, _} ->
        refuse_unkept!(rest, vars)
    end
  end

  # Each line holding a `$(`, read as the last of the file's opening lines:
  # an earlier line's `$(` has passed, so a failure here is this line's.
  defp refuse_lines!(path, contents, vars) do
    lines = String.split(contents, "\n")

    for {line, n} <- Enum.with_index(lines, 1), String.contains?(line, "$(") do
      opening = Enum.join(Enum.take(lines, n), "\n") <> "\n"

      case kind(read(opening, vars)) do
        nil -> :ok
        kind -> raise sentence(path, n, kind)
      end
    end
  end

  defp read(contents, vars),
    do: parse(fn -> @parser.parse(contents, vars, sys_cmd_fn: &kept/3) end)

  # The `$(` failure a read ended in, if it ended in one.
  defp kind(:unclosed), do: :unclosed
  defp kind({:error, ~s[Stop sequence not found: ")"]}), do: :unclosed
  defp kind({:error, "Shell command missing arguments; $() cannot be empty."}), do: :empty
  defp kind(_), do: nil

  defp sentence(path, line, :unclosed),
    do:
      "[Cyfr] FATAL: #{path} line #{line} opens a $( it does not close on that line. " <>
        ".env values are literal and no command runs; close the $( on its line, " <>
        "or single-quote the value"

  defp sentence(path, line, :empty),
    do:
      "[Cyfr] FATAL: #{path} line #{line} holds an empty $(). " <>
        ".env values are literal and no command runs; put text between the brackets, " <>
        "or single-quote the value"
end
