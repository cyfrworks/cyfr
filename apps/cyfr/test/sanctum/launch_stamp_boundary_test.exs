# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.LaunchStampBoundaryTest do
  @moduledoc """
  An approved launch's stamp (`Sanctum.Context`'s `launch`) seeds a root
  and names the classes its tree may send anywhere, so it is written by
  one function, `Sanctum.Context.stamp_launch/2`, called from
  `Aqua.Launch` alone. Mechanically, over every code line of every app's
  `lib`: the setter is called in one place, and no other line gives the
  field a value — a map or struct update naming `launch:` with anything
  but `nil` (admission's clear) appears only in the setter itself, a
  function or clause head's pattern being a read.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @context "apps/sanctum/lib/sanctum/context.ex"

  defp lib_files do
    for dir <- Prima.Test.SourceTree.app_libs(@root),
        file <- Prima.Test.SourceTree.files!(Path.join([@root, dir, "**/*.ex"])),
        do:
          {Path.relative_to(file, @root),
           Prima.Test.CodeLines.lines(Prima.Test.SourceTree.read(file))}
  end

  test "stamp_launch/2 has one call site, in Aqua.Launch" do
    calls =
      for {rel, lines} <- lib_files(),
          line <- lines,
          line =~ ~r/\bstamp_launch\(/,
          not (rel == @context and line =~ ~r/^\s*(def|@spec)\s/),
          do: rel

    assert calls == ["apps/cyfr/lib/aqua/launch.ex"],
           "stamp_launch/2 is Aqua.Launch's alone, called once: #{inspect(calls)}"
  end

  test "no line but the setter's gives the launch field a value" do
    writes =
      for {rel, lines} <- lib_files(),
          line <- lines,
          line =~ ~r/(\|\s*|%[A-Za-z.]*Context\{[^}]*)\blaunch:\s*(?!nil\b)/,
          # A function head or a clause head matches the field; it writes
          # nothing.
          not (line =~ ~r/^\s*defp?\s/ or line =~ ~r/->\s*$/),
          do: {rel, String.trim(line)}

    assert writes == [
             {@context,
              "%{ctx | launch: Map.take(launch, [:sources, :classes, :consent_id, :execution_id])}"}
           ],
           "only Sanctum.Context.stamp_launch/2 writes the launch stamp: #{inspect(writes)}"
  end

  test "the setter refuses a stamp of another shape" do
    ctx = Sanctum.TestContext.local()

    stamp = %{
      sources: [Prima.Source.new(:filed)],
      classes: [:filed],
      consent_id: nil,
      execution_id: "exec_x"
    }

    assert %{launch: ^stamp} = Sanctum.Context.stamp_launch(ctx, stamp)

    assert_raise ArgumentError, fn ->
      Sanctum.Context.stamp_launch(ctx, %{stamp | classes: [:unsettled]})
    end

    # Through `apply/3`: a stamp missing its root's id is refused as it
    # runs, which the compiler's type check would otherwise refuse first.
    assert_raise FunctionClauseError, fn ->
      apply(Sanctum.Context, :stamp_launch, [ctx, Map.delete(stamp, :execution_id)])
    end
  end
end
