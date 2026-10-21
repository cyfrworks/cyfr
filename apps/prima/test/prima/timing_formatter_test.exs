# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Test.TimingFormatterTest do
  @moduledoc """
  `Prima.Test.TimingFormatter` writes one `test` row per test, one `module`
  row per module run and one `run` row per suite, and refuses to start
  without its directory. A module's wall spans its start to its finish,
  setup included, and is never less than its tests' summed time, even when
  the formatter reads both events late. It reaches nothing outside this
  application, which is also tested alone; the analysis that reads the rows
  is checked at the umbrella level (`Cyfr.TestTimingsScriptTest`).

  The suite it formats is a tiny one, run here through `ExUnit.run/0` with
  this formatter alone, no after-suite callbacks and no failures record:
  the inner run neither takes this suite's modules, reports to this
  suite's formatters, runs this suite's callbacks nor writes its record,
  and ExUnit's configuration is put back as it was. A holder process
  suspends the inner run's formatter before the sync module starts and
  resumes it once that module's test has run, so the formatter reads the
  module's start after its test, as a starved formatter reads it.
  """

  # It runs a suite of its own and sets a process-wide variable.
  use ExUnit.Case, async: false

  @env "CYFR_TEST_TIMINGS_DIR"

  # How long the inner suite and the holder wait for each other.
  @bound 10_000

  setup do
    previous = System.get_env(@env)
    dir = Path.join(System.tmp_dir!(), "timing-formatter-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      if previous, do: System.put_env(@env, previous), else: System.delete_env(@env)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  # The inner suite's modules, under names of their own: an async one with
  # a passing, a failing and a skipped test; an async one run twice by its
  # parameters, the runs meeting so both are open at once; an async one
  # whose setup outlasts its test once the formatter has read its start,
  # and which then has the formatter held; and a sync one, which therefore
  # starts while the formatter is held, and lets it go once its test has
  # run, before ExUnit reports the test finished. The modules are unloaded
  # when the test ends, so a later definition starts from none of them.
  defp define_inner_suite do
    async = __MODULE__.Async
    param = __MODULE__.Param
    span = __MODULE__.Span
    sync = __MODULE__.Sync
    holder = __MODULE__.Holder

    on_exit(fn ->
      for module <- [async, param, span, sync] do
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

        test "fails" do
          Process.sleep(2)
          flunk("the inner suite's failing test")
        end

        @tag :skip
        test "is skipped", do: :ok
      end

      defmodule #{inspect(param)} do
        use ExUnit.Case, async: true, parameterize: [%{run: 1}, %{run: 2}]

        test "meets its other run" do
          send(#{inspect(holder)}, {:arrived, self()})
          assert_receive :met, #{@bound}
        end
      end

      defmodule #{inspect(span)} do
        use ExUnit.Case, async: true

        setup_all do
          send(#{inspect(holder)}, {:formatter, self()})
          assert_receive {:formatter, formatter}, #{@bound}

          # This setup runs in a process of its own, so the start its
          # module's process cast is read once the formatter's open modules
          # name it, under whatever key.
          Prima.Test.Wait.wait_until(
            fn ->
              formatter
              |> :sys.get_state()
              |> Map.fetch!(:modules)
              |> Map.keys()
              |> Enum.any?(&(&1 == __MODULE__ or match?({__MODULE__, _}, &1)))
            end,
            #{@bound}
          )

          Process.sleep(20)
          send(#{inspect(holder)}, {:hold, self()})
          assert_receive :held, #{@bound}
          :ok
        end

        test "passes after its setup", do: :ok
      end

      defmodule #{inspect(sync)} do
        use ExUnit.Case, async: false

        test "passes in turn" do
          on_exit(fn ->
            send(#{inspect(holder)}, {:release, self()})
            assert_receive :released, #{@bound}
          end)

          Process.sleep(2)
        end
      end
      """,
      __ENV__.file
    )

    %{async: async, param: param, span: span, sync: sync, holder: holder}
  end

  # Run the defined modules as a suite of their own beside their holder,
  # and put ExUnit's configuration back afterwards whatever happens.
  # Answers the run's result and how the hold went.
  defp run_inner_suite(%{holder: name}) do
    saved = Application.get_all_env(:ex_unit)
    holder = start_holder(name)

    result =
      try do
        ExUnit.configure(
          formatters: [Prima.Test.TimingFormatter],
          after_suite: [],
          failures_manifest_path: nil,
          only_test_ids: nil,
          include: [],
          exclude: [],
          repeat_until_failure: 0,
          # The parameterized module's two runs meet, so both need a case.
          max_cases: 4
        )

        ExUnit.run()
      after
        for {key, _value} <- Application.get_all_env(:ex_unit),
            not Keyword.has_key?(saved, key),
            do: Application.delete_env(:ex_unit, key)

        for {key, value} <- saved, do: Application.put_env(:ex_unit, key, value)
      end

    {result, stop_holder(holder)}
  end

  # The holder, registered as `name`: it names the inner run's formatter
  # (the one started after it), lets the parameterized runs meet, and
  # suspends the formatter when asked until asked to resume it or the
  # bound passes. It lets the formatter go when the outer test stops it or
  # ends, so no exit path leaves the formatter suspended.
  defp start_holder(name) do
    outer = self()
    before = formatters()

    pid =
      spawn(fn ->
        Process.register(self(), name)
        send(outer, {name, :ready})

        hold(%{
          outer: Process.monitor(outer),
          before: before,
          formatter: nil,
          arrived: [],
          held: :not_held,
          deadline: nil
        })
      end)

    assert_receive {^name, :ready}, @bound
    pid
  end

  defp stop_holder(holder) do
    monitor = Process.monitor(holder)
    send(holder, {:stop, self()})

    receive do
      {:hold, report} ->
        Process.demonitor(monitor, [:flush])
        report

      {:DOWN, ^monitor, :process, _pid, reason} ->
        {:holder_ended, reason}
    after
      @bound -> :holder_silent
    end
  end

  defp hold(state) do
    receive do
      {:formatter, from} ->
        state = with_formatter(state)
        send(from, {:formatter, state.formatter})
        hold(state)

      {:arrived, from} ->
        case [from | state.arrived] do
          [_, _] = both ->
            Enum.each(both, &send(&1, :met))
            hold(%{state | arrived: []})

          one ->
            hold(%{state | arrived: one})
        end

      {:hold, from} ->
        state = with_formatter(state)
        :ok = :sys.suspend(state.formatter)
        send(from, :held)
        deadline = System.monotonic_time(:millisecond) + @bound
        hold(%{state | held: :holding, deadline: deadline})

      {:release, from} ->
        state = release(state, :released_after_sync)
        send(from, :released)
        hold(state)

      {:stop, from} ->
        state = release(state, :stopped_holding)
        send(from, {:hold, state.held})

      {:DOWN, monitor, :process, _pid, _reason} when monitor == state.outer ->
        release(state, :outer_ended)
    after
      remaining(state) -> hold(release(state, :lapsed))
    end
  end

  defp remaining(%{held: :holding, deadline: deadline}),
    do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp remaining(_state), do: :infinity

  defp with_formatter(%{formatter: nil, before: before} = state) do
    [formatter] = formatters() -- before
    %{state | formatter: formatter}
  end

  defp with_formatter(state), do: state

  defp release(%{held: :holding} = state, outcome) do
    # A formatter already stopped has nothing left to let go.
    try do
      :sys.resume(state.formatter)
    catch
      :exit, _reason -> :ok
    end

    %{state | held: outcome}
  end

  defp release(state, _outcome), do: state

  defp formatters do
    Enum.filter(Process.list(), fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} ->
          dictionary[:"$initial_call"] == {Prima.Test.TimingFormatter, :init, 1}

        nil ->
          false
      end
    end)
  end

  defp rows(dir) do
    [file] = Path.wildcard(Path.join(dir, "p*.tsv"))

    file
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split(&1, "\t"))
  end

  test "writes a row per test, per module run and per run", %{dir: dir} do
    outer = Enum.sort(Application.get_all_env(:ex_unit))
    suite = define_inner_suite()
    System.put_env(@env, dir)

    assert {%{total: 7, failures: 1, skipped: 1}, :released_after_sync} =
             run_inner_suite(suite)

    assert Enum.sort(Application.get_all_env(:ex_unit)) == outer

    rows = rows(dir)
    file = "apps/prima/test/prima/timing_formatter_test.exs"

    tests = for ["test" | fields] <- rows, do: fields
    assert length(tests) == 7

    for [^file, line, _module, _mode, _state, usec] <- tests do
      assert String.to_integer(line) > 0
      assert String.to_integer(usec) >= 0
    end

    assert Enum.all?(tests, &match?([^file | _], &1))

    by_module =
      Enum.group_by(tests, &Enum.at(&1, 2), fn [_file, _line, _module, mode, state, usec] ->
        {mode, state, String.to_integer(usec)}
      end)

    assert map_size(by_module) == 4

    assert [
             {"async", "failed", failed_us},
             {"async", "passed", passed_us},
             {"async", "skipped", skipped_us}
           ] = Enum.sort(by_module[inspect(suite.async)])

    assert [{"async", "passed", _}, {"async", "passed", _}] = by_module[inspect(suite.param)]
    assert [{"async", "passed", _}] = by_module[inspect(suite.span)]
    assert [{"sync", "passed", sync_us}] = by_module[inspect(suite.sync)]
    assert Enum.all?([failed_us, passed_us, sync_us], &(&1 >= 2_000))

    modules = for ["module" | fields] <- rows, do: fields

    walls =
      Enum.group_by(modules, &Enum.at(&1, 1), fn [module_file, _module, mode, wall] ->
        {module_file, mode, String.to_integer(wall)}
      end)

    assert map_size(walls) == 4
    assert [{^file, "async", async_wall}] = walls[inspect(suite.async)]
    # One row per run of the parameterized module, both open at once.
    assert [{^file, "async", _}, {^file, "async", _}] = walls[inspect(suite.param)]
    assert [{^file, "async", span_wall}] = walls[inspect(suite.span)]
    assert [{^file, "sync", sync_wall}] = walls[inspect(suite.sync)]

    # A module runs its tests one after another.
    assert async_wall >= failed_us + passed_us + skipped_us
    # Its setup slept 20 ms after the formatter had read its start.
    assert span_wall >= 20_000
    # Read late, its start and finish together, yet never under its test.
    assert sync_wall >= sync_us

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
