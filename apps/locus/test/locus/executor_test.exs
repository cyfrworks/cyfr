# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.ExecutorTest do
  @moduledoc """
  Which executor a build runs under, and that the unisolated one is a
  choice of the test build alone: the roster is fixed when Locus is
  compiled, by the build environment and nothing a deployment can set.
  """

  use ExUnit.Case, async: true

  alias Locus.Executor
  alias Locus.Test.CodeLines

  @source Path.expand("../../lib/locus/executor.ex", __DIR__)

  test "this build, the test environment's, knows the direct launcher and picks it without a spawner" do
    assert Executor.executors() == [Locus.Keeper, Locus.DirectLauncher]
    refute Locus.Keeper.running?()
    assert Executor.executor() == {:ok, Locus.DirectLauncher}
  end

  test "the roster is decided by the build environment: every build but the test one knows the spawner alone" do
    code = @source |> File.read!() |> CodeLines.lines() |> Enum.join("\n")

    assert code =~
             ~r/@executors if Mix\.env\(\) == :test,\s+do: \[Locus\.Keeper, Locus\.DirectLauncher\],\s+else: \[Locus\.Keeper\]/

    # The launcher is named by the roster and the pick from it, and by
    # nothing a setting could reach.
    assert code |> String.split("Locus.DirectLauncher") |> length() == 3
    refute code =~ "Application.get_env"
    refute code =~ "System.get_env"
  end

  test "nothing else in the builder picks the direct launcher" do
    lib = Path.expand("../../lib/locus", __DIR__)

    named =
      for path <- Path.wildcard(Path.join(lib, "*.ex")),
          Path.basename(path) not in ["executor.ex", "direct_launcher.ex"],
          line <- path |> File.read!() |> CodeLines.lines(),
          line =~ "DirectLauncher",
          do: {Path.basename(path), String.trim(line)}

    # The boot's check that serving without cyfr-keeper is this build's to do.
    assert named == [{"application.ex", "if Locus.DirectLauncher in executors do"}]
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
