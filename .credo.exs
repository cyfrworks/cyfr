# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Credo's configuration: the warning category and each further check that
# holds a rule of AGENTS.md, run as `mix credo --strict` by the commit gate
# and CI. Every finding a check reports fails the run unless
# .credo_baseline.exs records it.
#
# The baseline holds the findings the tree had when these checks were
# enabled, one row per check, file and trigger with its count; line numbers
# are not part of a row, so an edit elsewhere in the file keeps it. The
# baseline only shrinks:
#   - a finding beyond a row's count, or with no row, fails the run, and the
#     message names the count the row allows;
#   - on a full run (`--strict`, no check, tag or file selection), a row
#     whose count exceeds today's findings fails the run too, so the change
#     that fixes a finding removes or lowers its row.
# A row is added only as a stated, justified decision of the change.

unless Code.ensure_loaded?(CyfrCredo.Baseline) do
  defmodule CyfrCredo.Baseline.Stale do
    @moduledoc false
    use Credo.Check,
      category: :warning,
      base_priority: :higher,
      explanations: [
        check: """
        A .credo_baseline.exs row allows more findings than the tree has:
        lower its count, or remove the row, in the change that fixed them.
        """
      ]

    @impl true
    def run(_source_file, _params), do: []
  end

  defmodule CyfrCredo.Baseline.Filter do
    @moduledoc false
    use Credo.Execution.Task

    alias Credo.Execution

    def call(exec, _opts) do
      path = CyfrCredo.Baseline.path()
      rows = CyfrCredo.Baseline.read!(path)
      allowed = Map.new(rows, fn row -> {row.key, row.count} end)
      groups = exec |> Execution.get_issues() |> Enum.group_by(&key/1)

      kept =
        Enum.flat_map(groups, fn {key, issues} ->
          case Map.get(allowed, key, 0) do
            count when length(issues) <= count -> []
            0 -> issues
            count -> Enum.map(issues, &note_allowed(&1, count))
          end
        end)

      stale =
        if full_run?(exec) do
          for row <- rows, length(Map.get(groups, row.key, [])) < row.count do
            stale_issue(path, row, length(Map.get(groups, row.key, [])))
          end
        else
          []
        end

      Execution.put_issues(exec, kept ++ stale)
    end

    defp key(issue), do: {issue.check, issue.filename, trigger(issue.trigger)}

    defp trigger(trigger) when is_binary(trigger), do: trigger

    defp trigger(trigger) when is_atom(trigger) and not is_nil(trigger),
      do: Atom.to_string(trigger)

    defp trigger(_trigger), do: ""

    defp note_allowed(issue, count) do
      %{issue | message: "#{issue.message} (.credo_baseline.exs allows #{count} here)"}
    end

    # Only a run that analysed every file with every check at every priority
    # can tell that a recorded finding is gone.
    defp full_run?(exec) do
      switches = exec.cli_options.switches

      exec.strict and exec.cli_options.args == [] and not exec.read_from_stdin and
        exec.only_checks in [nil, ""] and exec.ignore_checks in [nil, ""] and
        exec.only_checks_tags == [] and exec.ignore_checks_tags == [] and
        Enum.all?([:files_included, :files_excluded, :checks_with_tag, :checks_without_tag], fn
          switch -> Map.get(switches, switch, []) == []
        end)
    end

    defp stale_issue(path, row, found) do
      {check, file, trigger} = row.key

      %Credo.Issue{
        check: CyfrCredo.Baseline.Stale,
        category: :warning,
        priority: Credo.Priority.to_integer(:higher),
        exit_status: CyfrCredo.Baseline.Stale.exit_status(),
        filename: Path.relative_to_cwd(path),
        line_no: row.line,
        trigger: trigger,
        message:
          "#{inspect(check)} #{file} #{inspect(trigger)} is recorded #{row.count} " <>
            "time(s) but found #{found}: lower or remove the row"
      }
    end
  end

  defmodule CyfrCredo.Baseline do
    @moduledoc false
    import Credo.Plugin

    @path Path.expand(".credo_baseline.exs", __DIR__)

    def path, do: @path

    def init(exec) do
      append_task(
        exec,
        Credo.CLI.Command.Suggest.SuggestCommand,
        :filter_issues,
        CyfrCredo.Baseline.Filter
      )
    end

    # Each row is {check, file, trigger, count}: a check module, a path
    # relative to the umbrella root, the trigger the check reports and a
    # positive count. A malformed or repeated row raises, failing the run.
    def read!(path) do
      text = File.read!(path)
      {rows, _binding} = Code.eval_string(text, [], file: path)
      {:ok, quoted} = Code.string_to_quoted(text, file: path)
      lines = row_lines(quoted)

      unless is_list(rows) and length(rows) == length(lines) do
        raise "#{path} must be one list of {check, file, trigger, count} rows"
      end

      rows =
        rows
        |> Enum.zip(lines)
        |> Enum.map(fn
          {{check, file, trigger, count}, line}
          when is_atom(check) and is_binary(file) and is_binary(trigger) and is_integer(count) and
                 count > 0 ->
            %{key: {check, file, trigger}, count: count, line: line}

          {row, line} ->
            raise "#{path}:#{line}: not a {check, file, trigger, positive count} row: #{inspect(row)}"
        end)

      case rows |> Enum.frequencies_by(& &1.key) |> Enum.find(fn {_key, n} -> n > 1 end) do
        nil -> rows
        {key, _n} -> raise "#{path}: #{inspect(key)} has more than one row"
      end
    end

    defp row_lines(list) when is_list(list) do
      Enum.map(list, fn
        {:{}, meta, _elements} -> meta[:line]
        _other -> nil
      end)
    end

    defp row_lines(_other), do: []
  end
end

%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/",
          "src/",
          "test/",
          "web/",
          "apps/*/lib/",
          "apps/*/src/",
          "apps/*/test/",
          "apps/*/web/"
        ],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      plugins: [{CyfrCredo.Baseline, []}],
      strict: true,
      checks: %{
        enabled: [
          # The warning category, every check of it, the ones Credo leaves
          # off by default among them, except two that would do nothing:
          # LazyLogging runs only on Elixir before 1.7, and ForbiddenModule
          # forbids nothing until it is given modules.
          {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
          {Credo.Check.Warning.BoolOperationOnSameValues, []},
          {Credo.Check.Warning.Dbg, []},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.IoInspect, []},
          {Credo.Check.Warning.LeakyEnvironment, []},
          {Credo.Check.Warning.MapGetUnsafePass, []},
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []},
          {Credo.Check.Warning.MixEnv, []},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.OperationWithConstantResult, []},
          {Credo.Check.Warning.RaiseInsideRescue, []},
          {Credo.Check.Warning.SpecWithStruct, []},
          {Credo.Check.Warning.StructFieldAmount, []},
          {Credo.Check.Warning.UnsafeExec, []},
          {Credo.Check.Warning.UnsafeToAtom, []},
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedFileOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedMapOperation, []},
          {Credo.Check.Warning.UnusedPathOperation, []},
          {Credo.Check.Warning.UnusedRegexOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},
          {Credo.Check.Warning.UnusedTupleOperation, []},
          {Credo.Check.Warning.WrongTestFileExtension, []},
          {Credo.Check.Warning.WrongTestFilename, []},
          # "An intentional exception carries its reason", and skipped
          # checks are reported precisely: a skipped test says why.
          {Credo.Check.Design.SkipTestWithoutComment, []},
          # "Comments explain non-obvious invariants ... Change history,
          # incident histories, phase IDs and plan references belong in
          # commit messages or separate design material": a TODO or FIXME is
          # a plan note in the source.
          {Credo.Check.Design.TagTODO, []},
          {Credo.Check.Design.TagFIXME, []}
        ]
      }
    }
  ]
}
