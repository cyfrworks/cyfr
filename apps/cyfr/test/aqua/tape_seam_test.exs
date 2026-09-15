# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.TapeSeamTest do
  @moduledoc """
  `Aqua.Tape` is the only persistence port of the runner and the loop:
  nothing under `Aqua.Runner` or `Aqua.Loop` names a storage module or
  the repo, the runner names neither the catalog nor a root run, and
  nothing in `Aqua` reaches the machine directly. The file set is a
  glob; the forbidden names are the boundary itself.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  @storage ~r/\bArca\.(\w+Storage|Execution|ExecutionAttempts|ExecutionEvents|ExecutionPayloads|BudgetReservations|AgentRevisions|Repo)\b/
  @catalog ~r/\bCyfr\.Ops\b/
  @root_run ~r/\bCyfr\.Execution\.run_root\b/
  @machine ~r/\bFile\.|\bSystem\.cmd\b|\bReq\./

  defp files(globs) do
    globs
    |> Enum.flat_map(&Cyfr.Test.SourceTree.files!(Path.join(@root, &1)))
    |> Enum.sort()
  end

  defp offenders(globs, pattern) do
    for path <- files(globs),
        {line, n} <- path |> Cyfr.Test.SourceTree.read() |> Cyfr.Test.CodeLines.code_lines(),
        line =~ pattern,
        do: "#{Path.relative_to(path, @root)}:#{n}: #{String.trim(line)}"
  end

  test "the runner and the loop persist only through the tape" do
    assert offenders(
             [
               "apps/cyfr/lib/aqua/runner.ex",
               "apps/cyfr/lib/aqua/runner/**/*.ex",
               "apps/cyfr/lib/aqua/loop.ex",
               "apps/cyfr/lib/aqua/loop/**/*.ex"
             ],
             @storage
           ) == []
  end

  test "the runner names neither the catalog nor a root run" do
    assert offenders(
             ["apps/cyfr/lib/aqua/runner.ex", "apps/cyfr/lib/aqua/runner/**/*.ex"],
             @catalog
           ) == []

    assert offenders(
             ["apps/cyfr/lib/aqua/runner.ex", "apps/cyfr/lib/aqua/runner/**/*.ex"],
             @root_run
           ) == []
  end

  test "the scanner reads sources: the tape itself names storage" do
    refute offenders(["apps/cyfr/lib/aqua/tape.ex"], @storage) == []
  end

  test "the tape and the launch dispatcher are below the runner and the loop" do
    assert offenders(
             ["apps/cyfr/lib/aqua/tape.ex", "apps/cyfr/lib/aqua/launch.ex"],
             ~r/\bAqua\.(Runner|Loop)\b/
           ) == []
  end

  test "nothing in aqua touches the machine directly" do
    assert offenders(["apps/cyfr/lib/aqua/**/*.ex"], @machine) == []
  end
end
