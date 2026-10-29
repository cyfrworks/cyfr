# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RestoreOrderTest do
  @moduledoc """
  Direct global mutations belong in Prima.Test.Env or an on_exit callback.

  The exact per-slice roster holds sites awaiting conversion. Suite boot files
  configure their VM once and are excluded. Strings and comments are not code;
  mutations in a try/after or before on_exit are still direct mutations.

  A case macro contributes imports from its returned quote. Imports in the
  macro implementation and discarded quotes do not enter the caller.
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
       "import ExUnit.Callbacks\nApplication.put_env(:plant, :key, 1)\non_exit(fn -> Application.delete_env(:plant, :key) end)"},
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
    import ExUnit.Callbacks
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

  test "a locally defined on_exit is not ExUnit cleanup, even when defined after its call" do
    source = """
    defmodule Plant.LocalCallback do
      def run, do: on_exit(fn -> Application.put_env(:elixir, :plant_local, :changed) end)
      defp on_exit(fun), do: fun.()
    end
    """

    assert [%{calls: 1}] = check([{"plant.ex", source}], %{})
  end

  test "cleanup imports follow cases, qualified calls and explicit exclusions" do
    sources = [
      {"case.ex", "defmodule Plant.Case do\nuse ExUnit.CaseTemplate\nend"},
      {"plant_test.exs",
       """
       defmodule Plant.Cleanup do
         use Plant.Case
         on_exit(fn -> Application.delete_env(:plant, :key) end)
         ExUnit.Callbacks.on_exit(fn -> System.delete_env("PLANT") end)
         :"Elixir.ExUnit.Callbacks".on_exit(fn -> :persistent_term.erase(:plant) end)
       end
       defmodule Plant.NoCleanupImport do
         use ExUnit.Case
         import ExUnit.Callbacks, except: [on_exit: 1]
         on_exit(fn -> Application.put_env(:plant, :key, 1) end)
       end
       """}
    ]

    assert [%{path: "plant_test.exs", calls: 1}] = check(sources, %{})
  end

  @tag :case_provenance
  test "a case user receives its macro's imports rather than the provider's own imports" do
    for injected <- [
          "import Plant.Immediate, only: [on_exit: 1]",
          "use ExUnit.Case\nimport ExUnit.Callbacks, except: [on_exit: 1]\nimport Plant.Immediate"
        ] do
      source = """
      defmodule Plant.Immediate do
        def on_exit(fun), do: fun.()
      end
      defmodule Plant.Provider do
        use ExUnit.Case
        defmacro __using__(_) do
          quote do
            #{injected}
          end
        end
      end
      defmodule Plant.User do
        use Plant.Provider
        def run, do: on_exit(fn -> Application.put_env(:plant, :key, :changed) end)
      end
      """

      assert [%{calls: 1}] = check([{"plant.ex", source}], %{})
    end
  end

  @tag :macro_implementation
  test "macro-local imports and discarded quotes are not emitted into the caller" do
    for implementation <- [
          "import ExUnit.Callbacks, only: [on_exit: 1]",
          "quote do\nimport ExUnit.Callbacks, only: [on_exit: 1]\nend"
        ] do
      source = """
      defmodule Astra.MacroImmediate do
        def on_exit(fun), do: fun.()
      end
      defmodule Astra.MacroProvider do
        defmacro __using__(_) do
          #{implementation}
          quote do
            :ok
          end
        end
      end
      defmodule Astra.MacroUser do
        import Astra.MacroImmediate, only: [on_exit: 1]
        use Astra.MacroProvider
        def run, do: on_exit(fn -> Application.put_env(:elixir, :astra_macro_body, :changed) end)
      end
      Astra.MacroUser.run()
      """

      assert [%{calls: 1, expected: 0}] = check([{"plant.ex", source}], %{})
    end
  end

  test "a returned quote emits its imports with the macro's lexical aliases" do
    source = """
    defmodule Plant.Immediate do
      def on_exit(fun), do: fun.()
    end
    defmodule Plant.QuotedProvider do
      defmacro __using__(_) do
        alias ExUnit.Callbacks, as: Cleanup
        import Plant.Immediate, only: [on_exit: 1]
        quote do
          import Cleanup, only: [on_exit: 1]
        end
      end
    end
    defmodule Plant.QuotedUser do
      use Plant.QuotedProvider
      def run, do: on_exit(fn -> Application.put_env(:plant, :key, :changed) end)
    end
    """

    assert check([{"plant.ex", source}], %{}) == []
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

  for {name, source} <- [
        {"imports of the same name at different arities",
         """
         defmodule Plant.ImportArities do
           import Application, only: [put_env: 3]
           import System, only: [put_env: 2]
           def run, do: put_env(:elixir, :plant_import_arity, :changed)
         end
         Plant.ImportArities.run()
         """},
        {"a piped argument in an imported call",
         """
         defmodule Plant.ImportPipe do
           import Application, only: [put_env: 3]
           def run, do: :elixir |> put_env(:plant_import_pipe, :changed)
         end
         Plant.ImportPipe.run()
         """},
        {"an imported on_exit that executes immediately",
         """
         defmodule Plant.Immediate do
           def on_exit(fun), do: fun.()
         end
         defmodule Plant.ForeignCallback do
           import Plant.Immediate, only: [on_exit: 1]
           def run, do: on_exit(fn -> Application.put_env(:elixir, :plant_foreign, :changed) end)
         end
         Plant.ForeignCallback.run()
         """},
        {"a literal Elixir module atom",
         ~S[:"Elixir.Application".put_env(:elixir, :plant_literal, :changed)]}
      ] do
    test "the scan refuses #{name}" do
      assert [%{calls: 1, expected: 0}] = check([{"plant.ex", unquote(source)}], %{})
    end
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
    parsed =
      for {path, source} <- sources,
          path != @helper,
          Path.basename(path) != "test_helper.exs",
          do: {path, Code.string_to_quoted!(source, file: path)}

    modules = module_catalog(parsed)

    for {path, ast} <- parsed, reduce: %{} do
      acc ->
        ctx = %{aliases: %{}, imports: %{}, locals: MapSet.new(), modules: modules}
        {_, calls} = walk(ast, ctx, [])
        if calls == [], do: acc, else: Map.put(acc, path, Enum.reverse(calls))
    end
  end

  defp walk({:__block__, _, nodes}, ctx, calls), do: walk(nodes, ctx, calls)

  defp walk({:defmodule, _, [_name, [do: body]]}, ctx, calls) do
    facts = module_facts(body)
    {_, calls} = walk(body, %{ctx | locals: facts.locals}, calls)
    {ctx, calls}
  end

  defp walk({:use, _, [target | args]}, ctx, calls) do
    ctx = apply_use(module_name(target, ctx), ctx, [])
    {_, calls} = walk(args, ctx, calls)
    {ctx, calls}
  end

  defp walk({:|>, _, [left, right]}, ctx, calls) do
    walk(Macro.pipe(left, right, 0), ctx, calls)
  end

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
    {import_functions(name, opts, ctx), calls}
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
    unless MapSet.member?(ctx.locals, {fun, arity}), do: ctx.imports[{fun, arity}]
  end

  defp callback?(:on_exit, arity, ctx),
    do: imported(:on_exit, arity, ctx) == "ExUnit.Callbacks"

  defp callback?({:., _, [target, :on_exit]}, _arity, ctx),
    do: module_name(target, ctx) == "ExUnit.Callbacks"

  defp callback?(_name, _arity, _ctx), do: false

  defp module_name({:__aliases__, _, [:"Elixir" | parts]}, _ctx), do: Enum.join(parts, ".")

  defp module_name({:__aliases__, _, [first | rest]}, ctx) do
    first = Map.get(ctx.aliases, first, segment(first))
    Enum.join([first | Enum.map(rest, &segment/1)], ".")
  end

  defp module_name(name, _ctx) when is_atom(name) do
    case Atom.to_string(name) do
      "Elixir." <> name -> name
      name -> ":" <> name
    end
  end

  defp module_name(_dynamic, _ctx), do: nil

  defp segment(part) when is_atom(part), do: Atom.to_string(part)
  defp segment(part), do: Macro.to_string(part)

  defp import_functions(name, opts, ctx) do
    exports =
      case Keyword.get(opts, :only) do
        functions when is_list(functions) -> functions
        :macros -> []
        _ -> module_exports(name, ctx.modules)
      end

    imports = Map.reject(ctx.imports, fn {_signature, module} -> module == name end)

    imports =
      for signature <- exports,
          signature not in Keyword.get(opts, :except, []),
          reduce: imports do
        imports -> Map.put(imports, signature, name)
      end

    %{ctx | imports: imports}
  end

  defp module_exports(name, modules) do
    case modules[name] do
      %{exports: exports} -> MapSet.to_list(exports)
      nil -> beam_exports(name)
    end
  end

  defp beam_exports(nil), do: []

  defp beam_exports(name) do
    file =
      case name do
        ":" <> name -> name <> ".beam"
        name -> "Elixir." <> name <> ".beam"
      end

    with path when path != :non_existing <- :code.where_is_file(String.to_charlist(file)),
         {:ok, {_module, [exports: exports]}} <- :beam_lib.chunks(path, [:exports]) do
      exports
    else
      _ -> []
    end
  end

  defp module_catalog(parsed) do
    Enum.reduce(parsed, %{}, fn {_path, ast}, catalog ->
      {_, catalog} =
        Macro.prewalk(ast, catalog, fn
          {:defmodule, _, [name, [do: body]]} = node, catalog ->
            case module_name(name, %{aliases: %{}}) do
              nil -> {node, catalog}
              name -> {node, Map.put(catalog, name, module_facts(body))}
            end

          node, catalog ->
            {node, catalog}
        end)

      catalog
    end)
  end

  defp module_facts(body) do
    initial = %{locals: MapSet.new(), exports: MapSet.new(), injection: [], template?: false}
    ctx = %{aliases: %{}, injecting?: false, in_function?: false}
    {_, facts} = facts(body, ctx, initial)

    %{
      facts
      | injection: Enum.reverse(facts.injection),
        template?: facts.template? and not MapSet.member?(facts.locals, {:__using__, 1})
    }
  end

  defp facts({:defmodule, _, _}, ctx, facts), do: {ctx, facts}
  defp facts({:__block__, _, nodes}, ctx, facts), do: facts(nodes, ctx, facts)

  defp facts({:quote, _, args}, ctx, facts) do
    if ctx.injecting? do
      {_, facts} = facts(Keyword.get(List.last(args), :do), ctx, facts)
      {ctx, facts}
    else
      {ctx, facts}
    end
  end

  defp facts({:alias, _, _} = node, ctx, facts) do
    {updated, []} = walk(node, ctx, [])
    aliases = Map.reject(updated.aliases, fn {name, target} -> ctx.aliases[name] == target end)
    {updated, inject(facts, ctx, {:alias, aliases})}
  end

  defp facts({:use, _, [target | _]}, ctx, facts) do
    target = module_name(target, ctx)

    facts =
      if not ctx.in_function? and not ctx.injecting? and target == "ExUnit.CaseTemplate",
        do: %{facts | template?: true},
        else: inject(facts, ctx, {:use, target})

    {ctx, facts}
  end

  defp facts({:import, _, [target | rest]}, ctx, facts),
    do: {ctx, inject(facts, ctx, {:import, module_name(target, ctx), List.first(rest) || []})}

  defp facts({:using, _, [[do: body]]}, ctx, facts) do
    {_, facts} = returned_quote(body, ctx, facts)
    {ctx, facts}
  end

  defp facts({kind, _, [head | args]}, ctx, facts)
       when kind in [:def, :defp, :defmacro, :defmacrop, :defdelegate] do
    signatures = signatures(head)

    facts =
      if ctx.injecting? do
        inject(facts, ctx, {:local, signatures})
      else
        exports =
          if kind in [:def, :defmacro, :defdelegate],
            do: MapSet.union(facts.exports, signatures),
            else: facts.exports

        %{facts | locals: MapSet.union(facts.locals, signatures), exports: exports}
      end

    {_, facts} =
      if kind in [:defmacro, :defmacrop] and MapSet.member?(signatures, {:__using__, 1}) do
        returned_quote(Keyword.get(List.first(args) || [], :do), ctx, facts)
      else
        facts(args, %{ctx | injecting?: false, in_function?: true}, facts)
      end

    {ctx, facts}
  end

  defp facts(nodes, ctx, facts) when is_list(nodes),
    do: Enum.reduce(nodes, {ctx, facts}, fn node, {ctx, facts} -> facts(node, ctx, facts) end)

  defp facts(node, ctx, facts) when is_tuple(node) do
    {_, facts} = facts(Tuple.to_list(node), ctx, facts)
    {ctx, facts}
  end

  defp facts(_literal, ctx, facts), do: {ctx, facts}

  defp returned_quote({:__block__, _, []}, ctx, facts), do: {ctx, facts}

  defp returned_quote({:__block__, _, nodes}, ctx, facts) do
    {implementation, [returned]} = Enum.split(nodes, -1)
    {local, facts} = facts(implementation, %{ctx | injecting?: false, in_function?: true}, facts)
    {_, facts} = returned_quote(returned, local, facts)
    {ctx, facts}
  end

  defp returned_quote({:quote, _, _} = quoted, ctx, facts) do
    {_, facts} = facts(quoted, %{ctx | injecting?: true, in_function?: true}, facts)
    {ctx, facts}
  end

  defp returned_quote(other, ctx, facts) do
    {_, facts} = facts(other, %{ctx | injecting?: false, in_function?: true}, facts)
    {ctx, facts}
  end

  defp signatures({:when, _, [head | _]}), do: signatures(head)

  defp signatures({name, _, args}) when is_atom(name) and is_list(args) do
    required = length(args) - Enum.count(args, &match?({:\\, _, _}, &1))
    MapSet.new(for arity <- required..length(args), do: {name, arity})
  end

  defp signatures({name, _, nil}) when is_atom(name), do: MapSet.new([{name, 0}])
  defp signatures(_dynamic), do: MapSet.new()

  defp inject(facts, %{injecting?: true}, action),
    do: %{facts | injection: [action | facts.injection]}

  defp inject(facts, _ctx, _action), do: facts

  defp apply_use(name, ctx, _seen)
       when name in ["ExUnit.Case", "ExUnit.CaseTemplate", "ExUnit.Callbacks"],
       do: import_functions("ExUnit.Callbacks", [], ctx)

  defp apply_use(name, ctx, seen) do
    case {name in seen, ctx.modules[name]} do
      {false, %{template?: template?, injection: injection}} ->
        ctx = if template?, do: apply_use("ExUnit.Case", ctx, seen), else: ctx

        Enum.reduce(injection, ctx, fn
          {:use, target}, ctx -> apply_use(target, ctx, [name | seen])
          {:import, target, opts}, ctx -> import_functions(target, opts, ctx)
          {:alias, aliases}, ctx -> %{ctx | aliases: Map.merge(ctx.aliases, aliases)}
          {:local, signatures}, ctx -> %{ctx | locals: MapSet.union(ctx.locals, signatures)}
        end)

      _ ->
        ctx
    end
  end
end
