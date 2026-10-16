# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.LaunchStampBoundaryTest do
  @moduledoc """
  An approved launch's stamp (`Sanctum.Context`'s `launch`) seeds a root
  and names the classes its tree may send anywhere, so it is written by
  one function, `Sanctum.Context.stamp_launch/2`, called from
  `Aqua.Launch` alone. Mechanically, over the code of every app's `lib`:
  the setter is called in one place, and nothing else gives the field a
  value — a map or struct update naming `launch:` with anything but `nil`
  (admission's clear), whether on one line or spread over several, a
  `Map` writer, `struct/2` or `put_in` naming it, appears only in the
  setter itself.
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

  # Every way a code line can give a map or struct the `launch` key a
  # value, read over a whole file so an update spread over lines is one
  # match: an update naming `launch:` with anything but `nil`, a `Map`
  # writer naming `:launch`, `struct/2` or `struct!/2` naming it, and
  # `put_in` reaching it.
  @writers [
    ~r/%[A-Za-z.]*\{[^{}]*?\|[^{}]*?\blaunch:(?!\s*nil\b)/s,
    ~r/\bMap\.(?:put|put_new|replace|replace!|update|update!)\([^()]*:launch\b/s,
    ~r/\bMap\.merge\([^()]*\blaunch:/s,
    ~r/\bstruct!?\([^()]*\blaunch:/s,
    ~r/\bput_in\([^()]*(?:\.launch\b|:launch\b)/s
  ]

  defp writes(text),
    do: for(re <- @writers, [found] <- Regex.scan(re, text), do: String.trim(found))

  test "no code but the setter's gives the launch field a value" do
    found =
      for {rel, lines} <- lib_files(),
          _write <- writes(Enum.join(lines, "\n")),
          do: rel

    assert found == [@context],
           "only Sanctum.Context.stamp_launch/2 writes the launch stamp: #{inspect(found)}"
  end

  test "each writer form is caught, an update spread over lines among them" do
    planted = """
    def a(ctx, stamp), do: Map.put(ctx, :launch, stamp)

    def b(approver, stamp) do
      %{
        approver
        | origin: :interactive,
          launch: stamp
      }
    end

    def c(ctx, stamp), do: struct(ctx, launch: stamp)
    def d(ctx, stamp), do: put_in(ctx.launch, stamp)
    def e(ctx, stamp), do: Map.merge(ctx, %{launch: stamp})
    def cleared(ctx), do: %{ctx | approved_entry: nil, launch: nil}
    """

    assert length(writes(planted)) == 5
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
