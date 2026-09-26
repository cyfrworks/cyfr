# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.ExecutorTest do
  @moduledoc """
  Which executor a build runs under, and that the unisolated one is the
  test build's alone: every build knows the keeper, and only the test
  build's application environment names a direct launcher, which only its
  test support compiles.
  """

  # One case replaces the application environment the launcher is named by.
  use ExUnit.Case, async: false

  alias Locus.Executor
  alias Locus.Test.CodeLines

  @lib Path.expand("../../lib/locus", __DIR__)
  @mix_exs Path.expand("../../mix.exs", __DIR__)

  test "every build knows the keeper alone; this one, the test build, picks its direct launcher without a keeper" do
    assert Executor.executors() == [Locus.Keeper]
    refute Locus.Keeper.running?()
    assert Executor.direct_launcher() == Locus.DirectLauncher
    assert Executor.executor() == {:ok, Locus.DirectLauncher}
  end

  test "a launcher the build does not compile is no launcher, and without one no build runs outside the keeper" do
    previous = Application.get_env(:locus, :direct_launcher)

    try do
      for name <- [nil, Locus.NotCompiled, "Locus.DirectLauncher"] do
        Application.put_env(:locus, :direct_launcher, name)
        assert Executor.direct_launcher() == nil
        assert Executor.executor() == {:error, :no_keeper}
        assert Executor.launcher() == {:error, :no_keeper}
      end
    after
      Application.put_env(:locus, :direct_launcher, previous)
    end
  end

  test "the launcher is compiled from the test support and named by the test build's environment alone" do
    refute File.exists?(Path.join(@lib, "direct_launcher.ex"))

    assert File.exists?(Path.expand("../support/direct_launcher.ex", __DIR__))

    mix = File.read!(@mix_exs)
    assert mix =~ ~S|defp elixirc_paths(:test), do: ["lib", "test/support"]|
    assert mix =~ ~S|defp elixirc_paths(_), do: ["lib"]|
    assert mix =~ ~S|defp env(:test), do: [direct_launcher: Locus.DirectLauncher]|
    assert mix =~ ~S|defp env(_env), do: []|

    # Nothing under `lib` names the launcher; it is reached through the one
    # key the test build sets.
    named =
      for path <- Path.wildcard(Path.join(@lib, "**/*.ex")),
          line <- path |> File.read!() |> CodeLines.lines(),
          line =~ "DirectLauncher",
          do: {Path.relative_to(path, @lib), String.trim(line)}

    assert named == []
  end

  test "a log arrives as lines: whole ones as they form, the last one at the end, a long one in pieces" do
    {:ok, lines} = Agent.start_link(fn -> [] end)
    emit = fn line -> Agent.update(lines, &[line | &1]) end

    log = Executor.Log.new()
    log = Executor.Log.add(log, "first\nsec", emit)
    log = Executor.Log.add(log, "ond\n\nthi", emit)
    assert Agent.get(lines, &Enum.reverse/1) == ["first", "second"]

    log = Executor.Log.add(log, String.duplicate("x", 70_000), emit)
    assert [long | _] = Agent.get(lines, & &1)
    assert byte_size(long) == 70_003

    log = Executor.Log.add(log, "rd", emit)
    assert :ok = Executor.Log.finish(log, emit)
    assert hd(Agent.get(lines, & &1)) == "rd"
  end
end
