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
      reason, on its own line or in the comment directly above it:

          # sleep-ok: the proof's one-millisecond lifespan has passed
          Process.sleep(10)

      Concurrent tests synchronize on observable events or bounded condition
      checks (AGENTS.md, Validation; `Prima.Test.Wait.wait_until/3`). A
      sleep is right where a clock is what the test is about: the deadline,
      lifespan, window or backoff under test, the tick two timestamps need,
      the poll interval of a bounded wait, a pause in which something must
      not happen, a stand-in kept busy. The reason says which, in words: the
      marker alone is refused.

      `Process.sleep(:infinity)` is exempt: it keeps a stand-in process
      alive until it is killed and waits for nothing.
      """
    ]

  @marker ~r/#\s*sleep-ok:\s*[[:alnum:]]/u
  @comment ~r/^\s*#/

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    lines = source_file |> SourceFile.lines() |> Map.new()

    source_file
    |> Credo.Code.prewalk(&collect/2)
    |> Enum.reject(fn {line_no, _trigger} -> reasoned?(lines, line_no) end)
    |> Enum.reverse()
    |> Enum.map(fn {line_no, trigger} ->
      format_issue(issue_meta,
        message: "A sleep in a test needs `# sleep-ok: <reason>` on its line or the line above.",
        trigger: trigger,
        line_no: line_no
      )
    end)
  end

  defp collect({{:., _, [{:__aliases__, _, [:Process]}, :sleep]}, meta, args} = ast, acc),
    do: {ast, sleep(meta, args, "Process.sleep", acc)}

  defp collect({{:., _, [:timer, :sleep]}, meta, args} = ast, acc),
    do: {ast, sleep(meta, args, ":timer.sleep", acc)}

  defp collect(ast, acc), do: {ast, acc}

  defp sleep(_meta, [:infinity], _trigger, acc), do: acc
  defp sleep(meta, _args, trigger, acc), do: [{meta[:line], trigger} | acc]

  # The sleep's own line, then each line of the comment that ends on the
  # line above it: a reason may run over several comment lines.
  defp reasoned?(lines, line_no) do
    Map.get(lines, line_no, "") =~ @marker or reasoned_above?(lines, line_no - 1)
  end

  defp reasoned_above?(lines, line_no) do
    line = Map.get(lines, line_no, "")
    line =~ @comment and (line =~ @marker or reasoned_above?(lines, line_no - 1))
  end
end
