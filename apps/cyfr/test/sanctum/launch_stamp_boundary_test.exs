# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.LaunchStampBoundaryTest do
  @moduledoc """
  An approved launch's stamp (`Sanctum.Context`'s `launch`) seeds a root
  and names the classes its tree may send anywhere, so it is written by
  one function, `Sanctum.Context.stamp_launch/2`, called from
  `Aqua.Launch` alone. Mechanically, over the code of every app's `lib`,
  read as Elixir's own syntax tree: the setter is called in one place,
  and nothing but the setter's own module gives the field a value — no
  map or struct literal or update names a `launch` key with anything but
  `nil` (admission's clear) outside a function head's pattern, and no
  `Map` writer, `struct/2` or `struct!/2`, or `put_in`, `update_in` or
  `get_and_update_in` names it, however deep in an expression it sits.
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

  @defs [:def, :defp, :defmacro, :defmacrop]
  @map_writers [:put, :put_new, :replace, :replace!, :update, :update!]
  @struct_writers [:struct, :struct!]
  @path_writers [:put_in, :update_in, :get_and_update_in]

  # The lines of `source` that give a `launch` key a value, read over its
  # syntax tree with each pipe undone, so a writer is matched by where its
  # arguments sit however the call is spelled or nested.
  defp writes(source) do
    source
    |> Code.string_to_quoted!(columns: false)
    |> Macro.prewalk(fn
      {:|>, _meta, [left, {call, meta, args}]} when is_list(args) -> {call, meta, [left | args]}
      node -> node
    end)
    |> walk([])
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A function head is a pattern: a key it names is matched, not written.
  defp walk({def, _meta, [_head, body]}, acc) when def in @defs, do: walk(body, acc)
  defp walk({def, _meta, [_head]}, acc) when def in @defs, do: acc

  # A map or struct literal, or an update, naming the key with a value.
  defp walk({:%{}, meta, pairs} = node, acc),
    do: children(node, mark(Enum.any?(entries(pairs), &valued?/1), meta, acc))

  defp walk({{:., _dot, [{:__aliases__, _alias, [module]}, fun]}, meta, args} = node, acc)
       when is_list(args),
       do: children(node, mark(writes?(module, fun, args), meta, acc))

  defp walk({fun, meta, args} = node, acc) when is_atom(fun) and is_list(args),
    do: children(node, mark(writes?(:Kernel, fun, args), meta, acc))

  defp walk(node, acc), do: children(node, acc)

  defp children({call, _meta, args}, acc) when is_list(args), do: walk(args, walk(call, acc))
  defp children({left, right}, acc), do: walk(right, walk(left, acc))
  defp children(list, acc) when is_list(list), do: Enum.reduce(list, acc, &walk/2)
  defp children(_leaf, acc), do: acc

  defp mark(true, meta, acc), do: [Keyword.fetch!(meta, :line) | acc]
  defp mark(false, _meta, acc), do: acc

  defp entries([{:|, _meta, [_base, pairs]}]), do: pairs
  defp entries(pairs), do: pairs

  defp valued?({:launch, value}), do: value != nil
  defp valued?(_entry), do: false

  # A `Map` writer whose key is the field, `struct/2` whose fields give
  # it a value, or a path writer whose path reaches it.
  defp writes?(:Map, fun, [_map, key | _rest]) when fun in @map_writers, do: names?(key)

  defp writes?(:Kernel, fun, [_struct, fields]) when fun in @struct_writers and is_list(fields),
    do: Enum.any?(fields, &valued?/1)

  defp writes?(:Kernel, fun, [path, _value]) when fun in @path_writers, do: names?(path)
  defp writes?(:Kernel, fun, [_data, keys, _value]) when fun in @path_writers, do: names?(keys)
  defp writes?(_module, _fun, _args), do: false

  # Whether an expression names the field: the atom itself, a key of it
  # or `.launch`; a variable or a local function of that name does not.
  defp names?(:launch), do: true
  defp names?({name, _meta, context}) when is_atom(name) and is_atom(context), do: false
  defp names?({call, _meta, args}) when is_atom(call) and is_list(args), do: names?(args)
  defp names?({call, _meta, args}) when is_list(args), do: names?(call) or names?(args)
  defp names?({left, right}), do: names?(left) or names?(right)
  defp names?(list) when is_list(list), do: Enum.any?(list, &names?/1)
  defp names?(_leaf), do: false

  test "no code but the setter's gives the launch field a value" do
    found =
      for dir <- Prima.Test.SourceTree.app_libs(@root),
          file <- Prima.Test.SourceTree.files!(Path.join([@root, dir, "**/*.ex"])),
          _line <- writes(Prima.Test.SourceTree.read(file)),
          uniq: true,
          do: Path.relative_to(file, @root)

    assert found == [@context],
           "only Sanctum.Context.stamp_launch/2 writes the launch stamp: #{inspect(found)}"
  end

  test "each writer form is caught however it is nested, and only a clear or a head's pattern passes" do
    planted = """
    def a(ctx, stamp), do: Map.put(ctx, :launch, stamp) # caught

    def b(approver, stamp) do
      %{ # caught
        approver
        | origin: :interactive,
          launch: stamp
      }
    end

    def c(ctx, stamp), do: struct(ctx, launch: stamp) # caught
    def d(ctx, stamp), do: put_in(ctx.launch, stamp) # caught
    def e(ctx, stamp), do: Map.merge(ctx, %{launch: stamp}) # caught
    def f(stamp), do: %Sanctum.Context{launch: stamp} # caught
    def g(ctx, stamp), do: Map.put(identity(ctx), :launch, stamp) # caught
    def h(ctx, stamp), do: %{ctx | actor: %{}, launch: stamp} # caught
    def i(ctx, stamp), do: ctx |> Map.put(:launch, stamp) # caught
    def j(ctx, stamp), do: put_in(ctx, [:launch], stamp) # caught
    def k(ctx, stamp), do: Kernel.struct!(ctx, launch: stamp) # caught
    def l(ctx, stamp), do: {:ok, [%{ctx | launch: stamp}]} # caught
    def cleared(ctx), do: %{ctx | approved_entry: nil, launch: nil}
    def head(%Sanctum.Context{launch: %{consent_id: id}}), do: id
    def guarded(%{launch: stamp} = ctx) when is_map(stamp), do: ctx
    def kind(call), do: Map.put(call, :kind, :launch)
    def opts(launch), do: Map.put(%{kind: :launch}, :origin, launch) |> card(launch: launch)
    """

    caught =
      for {line, number} <- Enum.with_index(String.split(planted, "\n"), 1),
          line =~ "# caught",
          do: number

    assert length(caught) == 12
    assert writes(planted) == caught
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
