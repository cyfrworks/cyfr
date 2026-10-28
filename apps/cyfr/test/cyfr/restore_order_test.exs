# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RestoreOrderTest do
  @moduledoc """
  Direct global mutations belong in Prima.Test.Env or an on_exit callback.

  The exact per-slice roster holds sites awaiting conversion. Suite boot files
  configure their VM once and are excluded. Strings and comments are not code;
  mutations in a try/after or before on_exit are still direct mutations.
  """

  use ExUnit.Case, async: true

  alias Prima.Test.SourceTree

  @mutations %{
    "Application" => [:put_env, :delete_env, :put_all_env],
    "System" => [:put_env, :delete_env],
    ":persistent_term" => [:put, :erase],
    "Logger" => [:configure],
    ":application" => [:set_env, :unset_env]
  }
  @helper "apps/prima/test/support/env.ex"
  @rosters Path.join(__DIR__, "restore_order_roster/*.tsv")

  test "every direct global mutation has its exact roster entry" do
    violations = check(tree_sources(), roster())

    assert violations == [],
           "direct global mutations must use Prima.Test.Env:\n" <>
             Enum.map_join(violations, "\n", fn v ->
               "#{v.path}: expected #{v.expected}, found #{v.calls}: #{inspect(v.sites)}"
             end)
  end

  test "the three refused shapes remain direct mutations" do
    plants = [
      {"mutate_first",
       "Application.put_env(:plant, :key, 1)\non_exit(fn -> Application.delete_env(:plant, :key) end)"},
      {"after_only",
       "try do\nSystem.put_env(\"PLANT\", \"1\")\nafter\nSystem.delete_env(\"PLANT\")\nend"},
      {"async", "use ExUnit.Case, async: true\n:persistent_term.put(:plant, 1)"}
    ]

    for {name, body} <- plants do
      path = "apps/plant/test/#{name}_test.exs"
      assert [%{path: ^path, calls: calls, expected: 0}] = check([{path, body}], %{})
      assert calls == if(name == "after_only", do: 2, else: 1)
    end
  end

  test "an empty roster refuses every file with a direct mutation" do
    sources = tree_sources()
    actual = sites(sources)
    assert Map.has_key?(actual, "apps/cyfr/test/cyfr/runtime_config_wiring_test.exs")
    assert Map.has_key?(actual, "apps/arca/test/support/s3_test_env.ex")
    violations = check(sources, %{})
    assert Enum.map(violations, & &1.path) == Enum.sort(Map.keys(actual))
    assert Enum.all?(violations, &(&1.expected == 0 and &1.calls > 0))
  end

  test "the roster refuses changed counts, missing files, duplicates and empty reasons" do
    source = {"apps/plant/test/one_test.exs", "Logger.configure(level: :debug)"}
    path = elem(source, 0)
    assert check([source], %{path => 1}) == []
    assert [%{calls: 1, expected: 2}] = check([source], %{path => 2})
    assert [%{calls: 0, expected: 1}] = check([], %{path => 1})

    assert_raise ArgumentError, ~r/duplicate/, fn ->
      parse_roster([{"plant.tsv", "#{path}\t1\tpending\n#{path}\t1\tpending\n"}])
    end

    assert_raise ArgumentError, ~r/invalid/, fn ->
      parse_roster([{"plant.tsv", "#{path}\t1\t\n"}])
    end
  end

  test "all mutation APIs, aliases, imports and captures count as code" do
    source = """
    alias Application, as: App
    alias System, as: Sys
    alias Logger, as: Log
    import Application, only: [put_env: 3]
    App.put_env(:plant, :key, nil)
    App.delete_env(:plant, :key)
    App.put_all_env(plant: [key: 1])
    Sys.put_env("PLANT", "1")
    Sys.delete_env("PLANT")
    :persistent_term.put(:plant, nil)
    :persistent_term.erase(:plant)
    Log.configure(level: :debug)
    :application.set_env(:plant, :key, 1)
    :application.unset_env(:plant, :key)
    put_env(:plant, :key, 1)
    &App.put_env/3
    &put_env/3
    """

    assert length(sites([{"plant.ex", source}])["plant.ex"]) == 13
  end

  test "only callback bodies, the helper and suite setup are exceptions" do
    source = """
    alias ExUnit.Callbacks, as: Callbacks
    # Application.put_env(:plant, :comment, 1)
    "System.put_env(only text)"
    on_exit(fn -> Application.delete_env(:plant, :key) end)
    Callbacks.on_exit(:restore, &System.delete_env("PLANT"))
    on_exit(Application.put_env(:plant, :not_a_callback, 1), fn -> :ok end)
    Other.on_exit(fn -> :persistent_term.erase(:plant) end)
    """

    assert [%{call: "Application.put_env"}, %{call: ":persistent_term.erase"}] =
             sites([{"plant.ex", source}])["plant.ex"]

    assert sites([{@helper, source}, {"apps/plant/test/test_helper.exs", source}]) == %{}
  end

  test "aliases and imports stay inside their lexical scope" do
    source = """
    defmodule One do
      alias Application, as: App
      import System, only: [put_env: 2]
      App.put_env(:plant, :one, 1)
      put_env("PLANT", "1")
      put_env(:plant, :not_imported, 1)
    end
    defmodule Two do
      App.put_env(:plant, :not_the_alias, 1)
      put_env("PLANT", "not imported")
    end
    """

    assert [%{line: 4}, %{line: 5}] = sites([{"plant.ex", source}])["plant.ex"]
  end

  def tree_sources do
    root = Path.expand("../../../..", __DIR__)
    tests = SourceTree.files!(Path.join(root, "apps/*/test/**/*_test.exs"))
    support = SourceTree.files!(Path.join(root, "apps/*/test/**/support/**/*.{ex,exs}"))

    for path <- Enum.sort(Enum.uniq(tests ++ support)) do
      {Path.relative_to(path, root), SourceTree.read(path)}
    end
  end

  def roster do
    @rosters
    |> SourceTree.files!()
    |> Enum.map(&{&1, SourceTree.read(&1)})
    |> parse_roster()
  end

  def parse_roster(sources) do
    Enum.reduce(sources, %{}, fn {file, source}, acc ->
      source
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce(acc, fn {line, number}, entries ->
        if line == "" or String.starts_with?(line, "#") do
          entries
        else
          case String.split(line, "\t") do
            [path, count, reason] when path != "" and reason != "" ->
              unless Regex.match?(~r/^[1-9][0-9]*$/, count),
                do: raise(ArgumentError, "invalid count at #{file}:#{number}")

              if Map.has_key?(entries, path),
                do: raise(ArgumentError, "duplicate roster path #{path}")

              Map.put(entries, path, String.to_integer(count))

            _ ->
              raise ArgumentError, "invalid roster line at #{file}:#{number}"
          end
        end
      end)
    end)
  end

  def check(sources, roster) do
    actual = sites(sources)

    (Map.keys(actual) ++ Map.keys(roster))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      calls = Map.get(actual, path, [])
      expected = Map.get(roster, path, 0)

      if length(calls) == expected,
        do: [],
        else: [%{path: path, calls: length(calls), expected: expected, sites: calls}]
    end)
  end

  def sites(sources) do
    for {path, source} <- sources,
        path != @helper,
        Path.basename(path) != "test_helper.exs",
        reduce: %{} do
      acc ->
        ast = Code.string_to_quoted!(source, file: path)
        {_, calls} = walk(ast, %{aliases: %{}, imports: %{}}, [])
        if calls == [], do: acc, else: Map.put(acc, path, Enum.reverse(calls))
    end
  end

  defp walk({:__block__, _, nodes}, ctx, calls), do: walk(nodes, ctx, calls)

  defp walk({:alias, _, [{{:., _, [base, :{}]}, _, children}]}, ctx, calls) do
    prefix = module_name(base, ctx)

    aliases =
      Enum.reduce(children, ctx.aliases, fn {:__aliases__, _, parts}, aliases ->
        Map.put(aliases, List.last(parts), prefix <> "." <> Enum.join(parts, "."))
      end)

    {%{ctx | aliases: aliases}, calls}
  end

  defp walk({:alias, _, [target | rest]}, ctx, calls) do
    name = module_name(target, ctx)
    opts = List.first(rest) || []
    as = Keyword.get(opts, :as, target)
    {:__aliases__, _, parts} = as
    {%{ctx | aliases: Map.put(ctx.aliases, List.last(parts), name)}, calls}
  end

  defp walk({:import, _, [target | rest]}, ctx, calls) do
    name = module_name(target, ctx)
    opts = List.first(rest) || []
    functions = Map.get(@mutations, name, [])
    functions = if name == "ExUnit.Callbacks", do: [:on_exit | functions], else: functions
    imports = Enum.reduce(functions, ctx.imports, &Map.put(&2, &1, {name, opts}))
    {%{ctx | imports: imports}, calls}
  end

  defp walk({:&, _, [{:/, _, [target, arity]}]}, ctx, calls) do
    {ctx, record(target, arity, ctx, calls)}
  end

  defp walk({name, _, args} = node, ctx, calls) when is_list(args) do
    calls = record(node, length(args), ctx, calls)

    args =
      if callback?(name, length(args), ctx),
        do: Enum.reject(args, &match?({kind, _, _} when kind in [:fn, :&], &1)),
        else: args

    {_, calls} = walk(args, ctx, calls)
    {ctx, calls}
  end

  defp walk(list, ctx, calls) when is_list(list) do
    Enum.reduce(list, {ctx, calls}, fn node, {ctx, calls} -> walk(node, ctx, calls) end)
  end

  defp walk(tuple, ctx, calls) when is_tuple(tuple) do
    {_, calls} = walk(Tuple.to_list(tuple), ctx, calls)
    {ctx, calls}
  end

  defp walk(_literal, ctx, calls), do: {ctx, calls}

  defp record({{:., _, [target, fun]}, meta, _args}, _arity, ctx, calls) do
    record_call(module_name(target, ctx), fun, meta[:line], calls)
  end

  defp record({fun, meta, _args}, arity, ctx, calls) when is_atom(fun) do
    case imported(fun, arity, ctx) do
      nil -> calls
      name -> record_call(name, fun, meta[:line], calls)
    end
  end

  defp record(_node, _arity, _ctx, calls), do: calls

  defp record_call(name, fun, line, calls) do
    if fun in Map.get(@mutations, name, []),
      do: [%{line: line, call: "#{name}.#{fun}"} | calls],
      else: calls
  end

  defp imported(fun, arity, ctx) do
    case ctx.imports[fun] do
      {name, opts} ->
        allowed =
          case Keyword.get(opts, :only) do
            nil -> true
            :functions -> true
            :macros -> false
            functions -> {fun, arity} in functions
          end

        if allowed and {fun, arity} not in Keyword.get(opts, :except, []), do: name

      nil ->
        nil
    end
  end

  defp callback?(:on_exit, arity, ctx),
    do: imported(:on_exit, arity, ctx) in [nil, "ExUnit.Callbacks"]

  defp callback?({:., _, [target, :on_exit]}, _arity, ctx),
    do: module_name(target, ctx) == "ExUnit.Callbacks"

  defp callback?(_name, _arity, _ctx), do: false

  defp module_name({:__aliases__, _, [:"Elixir" | parts]}, _ctx), do: Enum.join(parts, ".")

  defp module_name({:__aliases__, _, [first | rest]}, ctx) do
    first = Map.get(ctx.aliases, first, segment(first))
    Enum.join([first | Enum.map(rest, &segment/1)], ".")
  end

  defp module_name(name, _ctx) when is_atom(name), do: ":#{name}"
  defp module_name(_dynamic, _ctx), do: nil

  defp segment(part) when is_atom(part), do: Atom.to_string(part)
  defp segment(part), do: Macro.to_string(part)
end
