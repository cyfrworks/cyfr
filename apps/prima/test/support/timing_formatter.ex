# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Test.TimingFormatter do
  @moduledoc """
  A passive ExUnit formatter that records how long each test and each test
  module took, without changing how the suite runs (`--slowest` would: it
  turns on `--trace`, which runs every async module serially).

  Use it beside the CLI formatter, after the runner's `--`:

      CYFR_TEST_TIMINGS_DIR=/abs/dir scripts/test-partitioned.sh -- \\
        --formatter ExUnit.CLIFormatter --formatter Prima.Test.TimingFormatter

  Every app's tests can load it: each app depends on Prima, and Prima's
  `test/support` compiles in the test environment. Without
  `CYFR_TEST_TIMINGS_DIR` (an absolute directory) it raises at init.

  It appends tab-separated rows to `<dir>/p<MIX_TEST_PARTITION or 0>.tsv`,
  one VM's apps one after another; paths run from the `apps/` segment and
  times are microseconds:

  | Row      | Fields                                                     |
  |----------|------------------------------------------------------------|
  | `test`   | file, line, module, `async` or `sync`, state, usec         |
  | `module` | file, module, `async` or `sync`, wall usec from `module_started` to `module_finished` |
  | `run`    | app, run usec, load usec or `-`                            |

  ExUnit runs a formatter it cannot load as no formatter at all, so the
  analysis (`elixir scripts/test-timings.exs`) refuses a missing or empty
  file instead.
  """

  use GenServer

  @env "CYFR_TEST_TIMINGS_DIR"

  @impl true
  def init(_opts) do
    dir = System.get_env(@env)

    unless is_binary(dir) and dir != "" and Path.type(dir) == :absolute do
      raise ArgumentError, "#{@env} must name an absolute directory, got: #{inspect(dir)}"
    end

    File.mkdir_p!(dir)
    path = Path.join(dir, "p#{System.get_env("MIX_TEST_PARTITION", "0")}.tsv")
    {:ok, io} = File.open(path, [:append, :utf8])
    {:ok, %{io: io, modules: %{}}}
  end

  @impl true
  def handle_cast({:module_started, %ExUnit.TestModule{} = module}, state) do
    started = System.monotonic_time(:microsecond)
    {:noreply, put_in(state.modules[key(module)], started)}
  end

  def handle_cast({:module_finished, %ExUnit.TestModule{} = module}, state) do
    finished = System.monotonic_time(:microsecond)
    {started, modules} = Map.pop(state.modules, key(module))

    if started do
      row(state.io, [
        "module",
        relative(module.file),
        inspect(module.name),
        mode(async_module?(module.name)),
        finished - started
      ])
    end

    {:noreply, %{state | modules: modules}}
  end

  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    row(state.io, [
      "test",
      relative(test.tags[:file]),
      test.tags[:line],
      inspect(test.module),
      mode(async_module?(test.module)),
      state_name(test.state),
      test.time
    ])

    {:noreply, state}
  end

  def handle_cast({:suite_finished, times}, state) do
    load = if times[:load], do: times.load, else: "-"
    row(state.io, ["run", app(), times.run, load])
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: File.close(state.io)

  # Concurrent async modules are told apart by name, and a parameterized
  # module's runs by their parameters.
  defp key(%ExUnit.TestModule{name: name, parameters: parameters}), do: {name, parameters}

  defp row(io, fields), do: IO.write(io, Enum.map_join(fields, "\t", &to_string/1) <> "\n")

  defp mode(true), do: "async"
  defp mode(_sync), do: "sync"

  defp async_module?(module) do
    function_exported?(module, :__ex_unit__, 1) and module.__ex_unit__(:config).async?
  end

  defp state_name(nil), do: "passed"
  defp state_name({state, _detail}), do: Atom.to_string(state)

  defp relative(nil), do: "-"

  defp relative(file) do
    case String.split(file, "/apps/", parts: 2) do
      [_root, rest] -> "apps/" <> rest
      [_none] -> file
    end
  end

  defp app do
    if Code.ensure_loaded?(Mix.Project), do: Mix.Project.config()[:app] || "-", else: "-"
  end
end
