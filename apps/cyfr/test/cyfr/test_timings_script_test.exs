# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.TestTimingsScriptTest do
  @moduledoc """
  `scripts/test-timings.exs` reads what `Prima.Test.TimingFormatter`
  writes: `summary`, `modules` and `weights` each answer the rows of a
  formatted run, and each refuses an empty directory and a malformed row.

  Checked here, at the umbrella level, because the script is the
  umbrella's: Prima's own suite is also run alone, from a copy of that
  application, where `scripts/` is not. The formatted run is a tiny suite
  run through `ExUnit.run/0` with the formatter alone, no after-suite
  callbacks and no failures record, and ExUnit's configuration is put back
  as it was.
  """

  # It runs a suite of its own and sets a process-wide variable.
  use ExUnit.Case, async: false

  @env "CYFR_TEST_TIMINGS_DIR"
  @script Path.expand("../../../../scripts/test-timings.exs", __DIR__)
  @file_path "apps/cyfr/test/cyfr/test_timings_script_test.exs"

  setup do
    previous = System.get_env(@env)
    dir = Path.join(System.tmp_dir!(), "test-timings-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      if previous, do: System.put_env(@env, previous), else: System.delete_env(@env)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  # Two modules under names of their own, each with one test, purged when
  # the case ends so a repeated run defines them afresh.
  defp define_inner_suite do
    async = __MODULE__.Async
    sync = __MODULE__.Sync

    on_exit(fn ->
      for module <- [async, sync] do
        :code.delete(module)
        :code.purge(module)
      end
    end)

    Code.compile_string(
      """
      defmodule #{inspect(async)} do
        use ExUnit.Case, async: true

        test "passes" do
          Process.sleep(2)
        end
      end

      defmodule #{inspect(sync)} do
        use ExUnit.Case, async: false

        test "passes in turn" do
          Process.sleep(2)
        end
      end
      """,
      __ENV__.file
    )

    {inspect(async), inspect(sync)}
  end

  defp run_inner_suite do
    saved = Application.get_all_env(:ex_unit)

    try do
      ExUnit.configure(
        formatters: [Prima.Test.TimingFormatter],
        after_suite: [],
        failures_manifest_path: nil,
        only_test_ids: nil,
        include: [],
        exclude: [],
        repeat_until_failure: 0
      )

      ExUnit.run()
    after
      for {key, _value} <- Application.get_all_env(:ex_unit),
          not Keyword.has_key?(saved, key),
          do: Application.delete_env(:ex_unit, key)

      for {key, value} <- saved, do: Application.put_env(:ex_unit, key, value)
    end
  end

  # The script takes its directory as an argument and reads nothing of the
  # server's environment, so every `CYFR_*` name, the timings directory
  # this case sets among them, is unset for it.
  defp script(args) do
    unset = for {name, _} <- System.get_env(), String.starts_with?(name, "CYFR_"), do: {name, nil}
    System.cmd("elixir", [@script | args], stderr_to_stdout: true, env: unset)
  end

  defp lines(output), do: String.split(output, "\n", trim: true)

  test "summary, modules and weights read a formatted run", %{dir: dir} do
    outer = Enum.sort(Application.get_all_env(:ex_unit))
    {async, sync} = define_inner_suite()
    System.put_env(@env, dir)

    assert %{total: 2, failures: 0} = run_inner_suite()
    assert Enum.sort(Application.get_all_env(:ex_unit)) == outer
    [partition] = dir |> Path.join("p*.tsv") |> Path.wildcard() |> Enum.map(&Path.basename/1)

    {summary, 0} = script(["summary", dir])
    summary = lines(summary)
    assert "partition VM test time (s):" in summary
    assert Enum.any?(summary, &(&1 =~ ~r/^  #{Regex.escape(partition)}\t\d+\.\d$/))
    assert Enum.any?(summary, &(&1 =~ ~r/^  mean \d+\.\d  max\/mean \d+\.\d\d$/))

    assert Enum.any?(
             summary,
             &(&1 =~ ~r/^test time: sync \d+\.\d s, async \d+\.\d s, sync share/)
           )

    for {module, mode} <- [{async, "async"}, {sync, "sync"}] do
      assert Enum.any?(
               summary,
               &(&1 =~
                   ~r/^  \d+\.\d\t#{Regex.escape(@file_path)}:\d+\t#{Regex.escape(module)}\t#{mode}\tpassed$/)
             )

      assert Enum.any?(
               summary,
               &(&1 =~
                   ~r/^  \d+\.\d\t#{Regex.escape(module)}\t#{mode}\t#{Regex.escape(@file_path)}$/)
             )
    end

    {modules, 0} = script(["modules", dir])

    assert [{async, "async"}, {sync, "sync"}] ==
             modules
             |> lines()
             |> Enum.map(fn line ->
               [seconds, module, mode, @file_path] = String.split(line, "\t")
               assert seconds =~ ~r/^\d+\.\d$/
               {module, mode}
             end)
             |> Enum.sort()

    {weights, 0} = script(["weights", dir])
    assert [[seconds, @file_path]] = weights |> lines() |> Enum.map(&String.split(&1, "\t"))
    assert seconds =~ ~r/^\d+\.\d$/

    empty = Path.join(dir, "empty")
    File.mkdir_p!(empty)

    malformed = Path.join(dir, "malformed")
    File.mkdir_p!(malformed)
    rows = File.read!(Path.join(dir, partition))
    File.write!(Path.join(malformed, partition), rows <> "module\tnot a row\n")

    for refused <- [empty, malformed], command <- ["summary", "modules", "weights"] do
      assert {_output, status} = script([command, refused])
      assert status != 0, "#{command} accepted #{refused}"
    end
  end
end
