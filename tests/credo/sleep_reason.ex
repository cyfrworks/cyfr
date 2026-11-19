# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Credo.SleepReason do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [files: %{included: ["apps/*/test/"]}],
    explanations: [
      check: """
      A sleep in a test (`Process.sleep/1`, `:timer.sleep/1`) carries its
      reason in a comment, on its own line or in the comment directly above
      it:

          # sleep-ok: the proof's one-millisecond lifespan has passed
          Process.sleep(10)

      Concurrent tests synchronize on observable events or bounded condition
      checks (AGENTS.md, Validation; `Prima.Test.Wait.wait_until/3`). A
      sleep is right where a clock is what the test is about: the deadline,
      lifespan, window or backoff under test, the tick two timestamps need,
      the poll interval of a bounded wait, a pause in which something must
      not happen, a stand-in kept busy. The reason says which, in words: the
      marker alone is refused. Only a comment counts, as the tokenizer reads
      the file: text in a string or a heredoc that looks like one does not.

      `Process.sleep(:infinity)`, however it is written (piped included), is
      exempt: it keeps a stand-in process alive until it is killed and waits
      for nothing.

      The check sees `Process.sleep`, `Elixir.Process.sleep`,
      `:timer.sleep`, their captures, and a bare `sleep/1` in a file that
      imports `Process` or `:timer` with it. Outside its reach: a sleep
      called through an alias of `Process`, through `apply/3` or a module
      held in a variable, and one a macro's expansion supplies.
      """
    ]

  @marker ~r/\A#\s*sleep-ok:(.*)\z/su
  @word ~r/\w/u

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    source = SourceFile.source(source_file)

    case Code.string_to_quoted_with_comments(source, columns: true) do
      {:ok, ast, comments} -> issues(ast, reasons(comments, source), issue_meta)
      # Credo reports a file it cannot parse on its own.
      {:error, _reason} -> []
    end
  end

  defp issues(ast, reasons, issue_meta) do
    imported = imports_sleep?(ast)
    {_ast, sleeps} = Macro.prewalk(ast, [], &collect(&1, &2, imported))

    sleeps
    |> Enum.reject(fn {line_no, _trigger} -> reasoned?(reasons, line_no) end)
    |> Enum.reverse()
    |> Enum.map(fn {line_no, trigger} ->
      format_issue(issue_meta,
        message: "A sleep in a test needs `# sleep-ok: <reason>` on its line or the line above.",
        trigger: trigger,
        line_no: line_no
      )
    end)
  end

  # Each comment line as the tokenizer gives it, with whether it gives a
  # reason (the marker, then words) and whether it is the only thing on its
  # line.
  defp reasons(comments, source) do
    lines = source |> String.split("\n") |> List.to_tuple()

    Map.new(comments, fn %{line: line, column: column, text: text} ->
      before = lines |> elem(line - 1) |> String.slice(0, column - 1)
      {line, {reason?(text), String.trim(before) == ""}}
    end)
  end

  defp reason?(text) do
    case Regex.run(@marker, text) do
      [_, reason] -> reason =~ @word
      nil -> false
    end
  end

  # A reason on the sleep's own line, or in the comment lines that end on
  # the line above it: a reason may run over several comment lines, and a
  # line with code on it ends the comment.
  defp reasoned?(reasons, line_no) do
    match?({true, _alone}, Map.get(reasons, line_no)) or reasoned_above?(reasons, line_no - 1)
  end

  defp reasoned_above?(reasons, line_no) do
    case Map.get(reasons, line_no) do
      {true, true} -> true
      {false, true} -> reasoned_above?(reasons, line_no - 1)
      _code_or_no_comment -> false
    end
  end

  # A pipe into a sleep is decided with the argument the pipe places; the
  # call it leaves behind is replaced so the walk below does not count it
  # again with no argument.
  defp collect({:|>, meta, [left, right]} = ast, acc, imported) do
    case sleep(right, imported) do
      {line_no, trigger, []} -> {{:|>, meta, [left, :piped]}, add(acc, line_no, trigger, [left])}
      _not_a_bare_sleep -> {ast, acc}
    end
  end

  defp collect(ast, acc, imported) do
    case sleep(ast, imported) do
      {line_no, trigger, args} -> {ast, add(acc, line_no, trigger, args)}
      nil -> {ast, acc}
    end
  end

  defp add(acc, _line_no, _trigger, [:infinity]), do: acc
  defp add(acc, line_no, trigger, _args), do: [{line_no, trigger} | acc]

  defp sleep({{:., _, [module, :sleep]}, meta, args}, _imported) when is_list(args) do
    cond do
      process?(module) -> {meta[:line], "Process.sleep", args}
      module == :timer -> {meta[:line], ":timer.sleep", args}
      true -> nil
    end
  end

  defp sleep({:sleep, meta, args}, true) when is_list(args) and length(args) <= 1,
    do: {meta[:line], "sleep", args}

  # &sleep/1, imported: the name is no call in a capture.
  defp sleep({:/, _, [{:sleep, meta, context}, 1]}, true) when is_atom(context),
    do: {meta[:line], "sleep", []}

  defp sleep(_ast, _imported), do: nil

  defp process?({:__aliases__, _, [:Process]}), do: true
  defp process?({:__aliases__, _, [:"Elixir", :Process]}), do: true
  defp process?(Process), do: true
  defp process?(_module), do: false

  defp imports_sleep?(ast) do
    {_ast, imported} =
      Macro.prewalk(ast, false, fn
        {:import, _, [module | options]} = node, acc ->
          {node, acc or ((process?(module) or module == :timer) and brings_sleep?(options))}

        node, acc ->
          {node, acc}
      end)

    imported
  end

  defp brings_sleep?([]), do: true

  defp brings_sleep?([options]) when is_list(options) do
    only = Keyword.get(options, :only, :functions)
    except = Keyword.get(options, :except, [])

    (only == :functions or (is_list(only) and {:sleep, 1} in only)) and
      not (is_list(except) and {:sleep, 1} in except)
  end

  defp brings_sleep?(_options), do: true
end
