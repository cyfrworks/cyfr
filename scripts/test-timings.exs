# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# The analysis of a timing run: the rows `Prima.Test.TimingFormatter`
# appended to `<dir>/p<partition>.tsv`. It reads files only.
#
#   elixir scripts/test-timings.exs summary [--expect N] DIR
#     each partition's VM test time (its suites' run times), their mean and
#     max/mean, the summed test time of sync and of async modules with the
#     sync share, the 20 slowest tests and the 20 slowest modules
#   elixir scripts/test-timings.exs modules DIR
#     every module's wall time, slowest first
#   elixir scripts/test-timings.exs weights DIR
#     one `<seconds>\t<path>` line per test file, the sum of its modules'
#     walls with one decimal, sorted by path
#
# Exits 1 on an empty, missing (partition 1..N under `--expect N`) or
# malformed file: ExUnit runs a formatter it cannot load as none at all,
# so a silently unloaded one fails here. Exits 64 on a usage error.

defmodule TestTimings do
  def main(["summary", "--expect", n, dir]) do
    case Integer.parse(n) do
      {count, ""} when count > 0 -> summary(dir, Enum.map(1..count, &"p#{&1}.tsv"))
      _other -> usage()
    end
  end

  def main(["summary", dir]), do: summary(dir, nil)
  def main(["modules", dir]), do: modules(dir)
  def main(["weights", dir]), do: weights(dir)
  def main(_args), do: usage()

  defp usage do
    IO.puts(
      :stderr,
      "usage: elixir scripts/test-timings.exs summary [--expect N] DIR | modules DIR | weights DIR"
    )

    System.halt(64)
  end

  defp fail(message) do
    IO.puts(:stderr, "test-timings: " <> message)
    System.halt(1)
  end

  # Every partition file to read, `{name, rows}`, refusing an empty,
  # missing or malformed one.
  defp read(dir, expected) do
    names =
      expected ||
        dir
        |> Path.join("p*.tsv")
        |> Path.wildcard()
        |> Enum.map(&Path.basename/1)
        |> Enum.sort()

    if names == [], do: fail("no partition file (p*.tsv) in #{dir}")

    for name <- names do
      path = Path.join(dir, name)

      case File.read(path) do
        {:ok, ""} ->
          fail("#{path} is empty")

        {:ok, text} ->
          {name,
           text
           |> String.split("\n", trim: true)
           |> Enum.with_index(1)
           |> Enum.map(&parse(path, &1))}

        {:error, reason} ->
          fail("#{path} cannot be read: #{:file.format_error(reason)}")
      end
    end
  end

  defp parse(path, {line, number}) do
    case String.split(line, "\t") do
      ["test", file, at, module, mode, state, usec] when mode in ~w(async sync) ->
        {:test, file, integer!(path, number, at), module, mode, state,
         integer!(path, number, usec)}

      ["module", file, module, mode, usec] when mode in ~w(async sync) ->
        {:module, file, module, mode, integer!(path, number, usec)}

      ["run", app, run, "-"] ->
        {:run, app, integer!(path, number, run), nil}

      ["run", app, run, load] ->
        {:run, app, integer!(path, number, run), integer!(path, number, load)}

      _other ->
        fail("#{path}:#{number} is not a timing row: #{inspect(line)}")
    end
  end

  defp integer!(path, number, text) do
    case Integer.parse(text) do
      {value, ""} when value >= 0 -> value
      _other -> fail("#{path}:#{number} has #{inspect(text)} where a whole number belongs")
    end
  end

  defp seconds(usec), do: :erlang.float_to_binary(usec / 1_000_000, decimals: 1)

  defp summary(dir, expected) do
    partitions = read(dir, expected)
    rows = Enum.flat_map(partitions, &elem(&1, 1))

    vm =
      for {name, rows} <- partitions do
        runs = for {:run, _app, run, _load} <- rows, do: run

        if runs == [],
          do: fail("#{Path.join(dir, name)} has no run row: its suite never finished")

        {name, Enum.sum(runs)}
      end

    IO.puts("partition VM test time (s):")
    for {name, usec} <- vm, do: IO.puts("  #{name}\t#{seconds(usec)}")

    times = Enum.map(vm, &elem(&1, 1))
    mean = Enum.sum(times) / length(times)
    max_over_mean = if mean > 0, do: Enum.max(times) / mean, else: 0.0

    IO.puts(
      "  mean #{seconds(round(mean))}  max/mean #{:erlang.float_to_binary(max_over_mean, decimals: 2)}"
    )

    tests =
      for {:test, file, line, module, mode, state, usec} <- rows,
          do: {file, line, module, mode, state, usec}

    sync = tests |> Enum.filter(&(elem(&1, 3) == "sync")) |> Enum.map(&elem(&1, 5)) |> Enum.sum()

    async =
      tests |> Enum.filter(&(elem(&1, 3) == "async")) |> Enum.map(&elem(&1, 5)) |> Enum.sum()

    share = if sync + async > 0, do: 100 * sync / (sync + async), else: 0.0

    IO.puts(
      "test time: sync #{seconds(sync)} s, async #{seconds(async)} s, " <>
        "sync share #{:erlang.float_to_binary(share, decimals: 1)}%"
    )

    IO.puts("20 slowest tests (s):")

    for {file, line, module, mode, state, usec} <-
          tests |> Enum.sort_by(&(-elem(&1, 5))) |> Enum.take(20),
        do: IO.puts("  #{seconds(usec)}\t#{file}:#{line}\t#{module}\t#{mode}\t#{state}")

    IO.puts("20 slowest modules (s):")
    for line <- rows |> module_lines() |> Enum.take(20), do: IO.puts("  " <> line)
  end

  defp module_lines(rows) do
    for {:module, file, module, mode, usec} <- Enum.sort_by(rows, &module_order/1),
        do: "#{seconds(usec)}\t#{module}\t#{mode}\t#{file}"
  end

  defp module_order({:module, _file, _module, _mode, usec}), do: -usec
  defp module_order(_other), do: 0

  defp modules(dir) do
    rows = dir |> read(nil) |> Enum.flat_map(&elem(&1, 1))
    for line <- module_lines(rows), do: IO.puts(line)
  end

  defp weights(dir) do
    rows = dir |> read(nil) |> Enum.flat_map(&elem(&1, 1))

    walls =
      Enum.reduce(rows, %{}, fn
        {:module, file, _module, _mode, usec}, acc -> Map.update(acc, file, usec, &(&1 + usec))
        _other, acc -> acc
      end)

    if walls == %{}, do: fail("no module rows in #{dir}")
    for {file, usec} <- Enum.sort(walls), do: IO.puts("#{seconds(usec)}\t#{file}")
  end
end

TestTimings.main(System.argv())
