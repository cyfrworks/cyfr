# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Test.TimingFormatterTest do
  @moduledoc """
  `Prima.Test.TimingFormatter` writes one `test` row per test, one `module`
  row per module and one `run` row per suite, and refuses to start without
  its directory. It reaches nothing outside this application, which is
  also tested alone; the analysis that reads the rows is checked at the
  umbrella level (`Cyfr.TestTimingsScriptTest`).

  The suite it formats is a tiny one, run here through `ExUnit.run/0` with
  this formatter alone, no after-suite callbacks and no failures record:
  the inner run neither takes this suite's modules, reports to this
  suite's formatters, runs this suite's callbacks nor writes its record,
  and ExUnit's configuration is put back as it was.
  """

  # It runs a suite of its own and sets a process-wide variable.
  use ExUnit.Case, async: false

  @env "CYFR_TEST_TIMINGS_DIR"

  setup do
    previous = System.get_env(@env)
    dir = Path.join(System.tmp_dir!(), "timing-formatter-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      if previous, do: System.put_env(@env, previous), else: System.delete_env(@env)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  # Two modules of the inner suite, under names of their own: an async one
  # with a passing, a failing and a skipped test, and a sync one.
  defp define_inner_suite do
    suffix = System.unique_integer([:positive])
    async = Module.concat([__MODULE__, "Async#{suffix}"])
    sync = Module.concat([__MODULE__, "Sync#{suffix}"])

    Code.compile_string(
      """
      defmodule #{inspect(async)} do
        use ExUnit.Case, async: true

        test "passes" do
          Process.sleep(2)
        end

        test "fails" do
          Process.sleep(2)
          flunk("the inner suite's failing test")
        end

        @tag :skip
        test "is skipped", do: :ok
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

    {async, sync}
  end

  # Run the defined modules as a suite of their own, and put ExUnit's
  # configuration back afterwards whatever happens.
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

  defp rows(dir) do
    [file] = Path.wildcard(Path.join(dir, "p*.tsv"))

    file
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split(&1, "\t"))
  end

  test "writes a row per test, per module and per run", %{dir: dir} do
    outer = Enum.sort(Application.get_all_env(:ex_unit))
    {async, sync} = define_inner_suite()
    System.put_env(@env, dir)

    assert %{total: 4, failures: 1, skipped: 1} = run_inner_suite()
    assert Enum.sort(Application.get_all_env(:ex_unit)) == outer

    rows = rows(dir)
    file = "apps/prima/test/prima/timing_formatter_test.exs"

    tests = for ["test" | fields] <- rows, do: fields
    assert length(tests) == 4

    for [^file, line, _module, _mode, _state, usec] <- tests do
      assert String.to_integer(line) > 0
      assert String.to_integer(usec) >= 0
    end

    assert Enum.all?(tests, &match?([^file | _], &1))

    by_state =
      tests
      |> Enum.map(fn [_file, _line, module, mode, state, usec] ->
        {module, mode, state, String.to_integer(usec)}
      end)
      |> Enum.sort()

    assert [
             {a1, "async", "failed", failed_us},
             {a2, "async", "passed", passed_us},
             {a3, "async", "skipped", _skipped_us},
             {s1, "sync", "passed", sync_us}
           ] = by_state

    assert Enum.uniq([a1, a2, a3]) == [inspect(async)]
    assert s1 == inspect(sync)
    assert Enum.all?([failed_us, passed_us, sync_us], &(&1 >= 2_000))

    modules = for ["module" | fields] <- rows, do: fields

    assert [[^file, async_name, "async", async_wall], [^file, sync_name, "sync", sync_wall]] =
             Enum.sort_by(modules, &Enum.at(&1, 2))

    assert async_name == inspect(async)
    assert sync_name == inspect(sync)
    assert String.to_integer(async_wall) >= 4_000
    assert String.to_integer(sync_wall) >= 2_000

    assert [["prima", run_us, load]] = for(["run" | fields] <- rows, do: fields)
    assert String.to_integer(run_us) > 0
    assert load == "-"
  end

  test "refuses to start without an absolute directory" do
    System.delete_env(@env)
    assert_raise ArgumentError, ~r/#{@env}/, fn -> Prima.Test.TimingFormatter.init([]) end

    System.put_env(@env, "relative/dir")
    assert_raise ArgumentError, ~r/absolute/, fn -> Prima.Test.TimingFormatter.init([]) end
  end
end
