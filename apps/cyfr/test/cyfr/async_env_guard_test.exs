# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.AsyncEnvGuardTest do
  @moduledoc """
  An async test module never writes application environment, and neither
  does a helper one calls. `Application.put_env` and `delete_env` are global
  to the VM, so an async test that writes them races every other suite.

  The scan parses every `*_test.exs` and every support file of every
  umbrella application (`Prima.Test.SourceTree`) as code. It attributes each
  write to the function that holds it and to the module that defines that
  function: `put_env`, `put_all_env` and `delete_env` of `Application`, however
  the call names it (qualified, through an alias, or through an import), and
  `:application.set_env` and `unset_env`. A comment or a string that names a
  write is no write.

  A module is async when its own `use` says `async: true`, or when it `use`s a
  case whose quoted `use` does. A write is a violation when it is unguarded and
  sits in an async module, or when an async module calls a function that
  writes unguarded: a function of another module the tree defines, reached
  through an alias, an import or a qualified name, or the `__using__` of a case
  the module `use`s. A call resolves by name, so a function of the same name at
  another arity counts; that can only add a violation, never hide one.

  A write is admitted when it is guarded on the test's async tag inside a
  `setup` or `setup_all` callback, as `apps/cyfr/test/support/conn_case.ex`
  guards its own: `unless tags[:async]` runs its body only in a sync test, and
  so does `if not tags[:async]`, and the `else` of `if tags[:async]` does too.
  A guard anywhere else admits nothing, since a helper's `tags` may be any map.
  `async:` given as anything but a literal boolean is read as async.

  Its blind spots, which stay the reviewer's: a function value called through a
  variable (`f.(x)`, `apply/3`), a call the scan cannot resolve to a module of
  the tree, and a module nested in another, which does not inherit the outer
  module's aliases or imports.
  """

  use ExUnit.Case, async: true

  alias Prima.Test.SourceTree

  @app_writes [:put_env, :delete_env, :put_all_env]
  @erl_writes [:set_env, :unset_env]

  defp root, do: Path.expand("../../../..", __DIR__)

  test "no async module writes application environment, directly or through a helper it calls" do
    %{violations: violations} = scan(tree_sources())

    assert violations == [],
           "async tests write application env, which is global to the VM:\n" <>
             Enum.map_join(violations, "\n", & &1.message)
  end

  test "the walk reads test files and support files, and admits conn_case's guarded writes" do
    sources = tree_sources()

    assert Enum.any?(sources, fn {path, _} -> String.ends_with?(path, "_test.exs") end)
    assert Enum.any?(sources, fn {path, _} -> path == "apps/cyfr/test/support/conn_case.ex" end)

    assert %{admitted: admitted} = scan(sources)
    assert Enum.any?(admitted, &(&1.file == "apps/cyfr/test/support/conn_case.ex"))
  end

  describe "the positive control" do
    test "an unguarded write in an async module is found, at its line" do
      source = """
      defmodule Plant.AsyncWriteTest do
        use ExUnit.Case, async: true

        test "writes" do
          Application.put_env(:plant, :key, 1)
        end
      end
      """

      assert [%{file: "plant/async_write_test.exs", line: 5, module: "Plant.AsyncWriteTest"}] =
               scan([{"plant/async_write_test.exs", source}]).violations
    end

    test "an async module that calls a helper which writes is found, at the call" do
      helper = """
      defmodule Plant.Helper do
        def clear, do: Application.delete_env(:plant, :key)
      end
      """

      caller = """
      defmodule Plant.CallerTest do
        use ExUnit.Case, async: true

        test "calls" do
          Plant.Helper.clear()
        end
      end
      """

      assert [%{file: "plant/caller_test.exs", line: 5, module: "Plant.CallerTest"}] =
               scan([{"plant/helper.ex", helper}, {"plant/caller_test.exs", caller}]).violations
    end

    test "an async module that uses a case whose setup writes is found, at the use" do
      case_module = """
      defmodule Plant.Case do
        defmacro __using__(_opts) do
          quote do
            setup do
              Application.put_env(:plant, :key, 1)
              :ok
            end
          end
        end
      end
      """

      user = """
      defmodule Plant.UserTest do
        use Plant.Case, async: true

        test "uses" do
          assert true
        end
      end
      """

      assert [%{file: "plant/user_test.exs", line: 2, module: "Plant.UserTest"}] =
               scan([{"plant/case.ex", case_module}, {"plant/user_test.exs", user}]).violations
    end

    test "a write through an alias or an import of Application is found" do
      source = """
      defmodule Plant.AliasTest do
        use ExUnit.Case, async: true
        alias Application, as: Env
        import Application, only: [delete_env: 2]

        test "writes" do
          Env.put_env(:plant, :key, 1)
          delete_env(:plant, :key)
        end
      end
      """

      assert [%{line: 7, module: "Plant.AliasTest"}, %{line: 8, module: "Plant.AliasTest"}] =
               scan([{"plant/alias_test.exs", source}]).violations
    end

    test "a guard outside a setup admits nothing: a helper's tags may be any map" do
      helper = """
      defmodule Plant.GuardedHelper do
        def set(tags) do
          unless tags[:async] do
            Application.put_env(:plant, :helper, 1)
          end
        end
      end
      """

      caller = """
      defmodule Plant.HelperCallerTest do
        use ExUnit.Case, async: true

        test "calls with a constant map" do
          Plant.GuardedHelper.set(%{})
        end
      end
      """

      result =
        scan([{"plant/guarded_helper.ex", helper}, {"plant/helper_caller_test.exs", caller}])

      assert [%{file: "plant/helper_caller_test.exs", line: 5}] = result.violations
      assert result.admitted == []
    end

    test "a case whose quoted use says async: true makes the modules using it async" do
      case_module = """
      defmodule Plant.AsyncCase do
        defmacro __using__(_opts) do
          quote do
            use ExUnit.Case, async: true
          end
        end
      end
      """

      user = """
      defmodule Plant.CaseUserTest do
        use Plant.AsyncCase

        test "writes" do
          Application.put_env(:plant, :key, 1)
        end
      end
      """

      assert [%{file: "plant/case_user_test.exs", line: 5, module: "Plant.CaseUserTest"}] =
               scan([{"plant/async_case.ex", case_module}, {"plant/case_user_test.exs", user}]).violations
    end

    test "a guarded write inside a setup is admitted; a comment, a string and a sync module are not violations" do
      source = """
      defmodule Plant.OkTest do
        use ExUnit.Case, async: true

        # Application.put_env(:plant, :comment, 1) is only text here.
        @note "Application.delete_env(:plant, :string)"

        setup tags do
          unless tags[:async] do
            Application.put_env(:plant, :guarded, 1)
          end

          :ok
        end
      end

      defmodule Plant.SyncTest do
        use ExUnit.Case, async: false

        test "writes synchronously" do
          Application.put_env(:plant, :sync, 1)
        end
      end
      """

      assert %{violations: [], admitted: [%{file: "plant/ok_test.exs", line: 9}]} =
               scan([{"plant/ok_test.exs", source}])
    end
  end

  # Every test and support source of the umbrella, read once, as `{path, source}`.
  defp tree_sources do
    tests = SourceTree.files!(Path.join(root(), "apps/*/test/**/*_test.exs"))

    support =
      SourceTree.files!(Path.join(root(), "apps/*/test/**/support/**/*.{ex,exs}"))

    for path <- Enum.sort(Enum.uniq(tests ++ support)) do
      {Path.relative_to(path, root()), SourceTree.read(path)}
    end
  end

  # The pure scan: sources in, the violations and the admitted writes out.
  defp scan(sources) do
    modules = Enum.flat_map(sources, fn {path, source} -> modules_of(path, source) end)

    index =
      Enum.reduce(modules, %{}, fn m, acc -> Map.update(acc, m.name, m, &merge(&1, m)) end)

    async = Enum.filter(modules, &async?(index, &1))

    direct =
      for m <- async, {fun, f} <- m.funcs, write <- f.writes, not write.guarded? do
        violation(m, write.line, "#{write.what} in #{m.name}.#{fun}, an async module")
      end

    through =
      for m <- async,
          {fun, f} <- m.funcs,
          call <- f.calls,
          {target, target_fun} <- resolve(index, m, call),
          target != m.name,
          writes?(index, target, target_fun, []) do
        violation(
          m,
          call_line(call),
          "#{m.name}.#{fun} calls #{target}.#{target_fun}, which writes application env"
        )
      end

    admitted =
      for m <- modules, {_fun, f} <- m.funcs, write <- f.writes, write.guarded? do
        %{file: m.file, line: write.line, what: write.what}
      end

    %{violations: Enum.sort_by(direct ++ through, &{&1.file, &1.line}), admitted: admitted}
  end

  # A module is async when its own `use` says so, or when a case it `use`s says
  # so in its quoted `use`: the users of such a case run async with it.
  defp async?(index, m) do
    m.async or
      Enum.any?(m.funcs, fn {_fun, f} ->
        Enum.any?(f.calls, &quote_async_use?(index, m, &1))
      end)
  end

  defp quote_async_use?(index, m, {:use, parts, _line}) do
    case index[expand(m.aliases, parts)] do
      %{quote_async: quote_async} -> quote_async
      nil -> false
    end
  end

  defp quote_async_use?(_index, _m, _call), do: false

  defp violation(m, line, reason) do
    %{file: m.file, line: line, module: m.name, message: "#{m.file}:#{line} #{reason}"}
  end

  # Whether `fun` of `module` writes unguarded, directly or through a call it
  # resolves. `seen` breaks cycles.
  defp writes?(index, module, fun, seen) do
    key = {module, fun}

    with false <- key in seen,
         %{funcs: funcs} = mod <- index[module],
         %{} = f <- funcs[fun] do
      Enum.any?(f.writes, &(not &1.guarded?)) or
        Enum.any?(f.calls, fn call ->
          Enum.any?(resolve(index, mod, call), fn {target, target_fun} ->
            writes?(index, target, target_fun, [key | seen])
          end)
        end)
    else
      _no_function -> false
    end
  end

  # The tree's functions a call names, as `{module, fun}`.
  defp resolve(index, mod, {:remote, parts, fun, _arity, _line}) do
    name = expand(mod.aliases, parts)
    if Map.has_key?(index, name), do: [{name, fun}], else: []
  end

  defp resolve(_index, mod, {:self, fun, _arity, _line}), do: [{mod.name, fun}]

  defp resolve(index, mod, {:local, fun, _arity, _line}) do
    if Map.has_key?(mod.funcs, fun) do
      [{mod.name, fun}]
    else
      for i <- mod.imports,
          Map.has_key?(index, i) and Map.has_key?(index[i].funcs, fun),
          do: {i, fun}
    end
  end

  defp resolve(index, mod, {:use, parts, _line}) do
    name = expand(mod.aliases, parts)
    if Map.has_key?(index, name), do: [{name, :__using__}], else: []
  end

  defp call_line({:remote, _, _, _, line}), do: line
  defp call_line({:self, _, _, line}), do: line
  defp call_line({:local, _, _, line}), do: line
  defp call_line({:use, _, line}), do: line

  # A module reference as the dotted name it spells, with its first part
  # resolved through the aliases in force. A leading `Elixir` is the root.
  defp expand(aliases, parts), do: Enum.join(expand_parts(aliases, parts), ".")

  defp expand_parts(aliases, parts) do
    case strip_elixir(parts) do
      [head | rest] ->
        case Map.fetch(aliases, head) do
          {:ok, full} -> Enum.map(full ++ rest, &part_name/1)
          :error -> Enum.map([head | rest], &part_name/1)
        end

      [] ->
        []
    end
  end

  defp strip_elixir([:"Elixir" | rest]), do: rest
  defp strip_elixir(parts), do: parts

  defp part_name(part) when is_atom(part), do: Atom.to_string(part)
  defp part_name(_other), do: "?"

  # One umbrella module per `defmodule` in the file, nested ones included.
  defp modules_of(path, source) do
    ast = Code.string_to_quoted!(source, file: path, columns: false)

    for {name, body, line} <- find_modules(ast) do
      info = collect_module(body)

      %{
        name: name,
        file: path,
        line: line,
        async: info.async,
        quote_async: info.quote_async,
        aliases: info.aliases,
        imports: info.imports,
        funcs: info.funcs
      }
    end
  end

  defp find_modules(ast) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [alias, [do: body]]} = node, acc ->
          {node, [{module_name(alias), body, meta[:line]} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp module_name({:__aliases__, _, parts}), do: expand(%{}, parts)
  defp module_name(other), do: Macro.to_string(other)

  defp collect_module(body) do
    acc =
      collect(body, %{guarded?: false, fun: :module, in_quote?: false, in_setup?: false}, %{
        async: nil,
        quote_async: false,
        aliases: %{},
        imports: [],
        funcs: %{}
      })

    %{acc | async: acc.async not in [nil, false]}
  end

  defp collect({:defmodule, _, _}, _ctx, acc), do: acc
  defp collect({:__aliases__, _, _}, _ctx, acc), do: acc

  defp collect({:quote, _, args}, ctx, acc), do: collect(args, %{ctx | in_quote?: true}, acc)

  defp collect({:if, _, [condition, opts]}, ctx, acc) when is_list(opts) do
    {do_guard, else_guard} = branch(:if, condition, ctx)
    acc = collect(condition, ctx, acc)
    acc = collect(Keyword.get(opts, :do), %{ctx | guarded?: do_guard}, acc)
    collect(Keyword.get(opts, :else), %{ctx | guarded?: else_guard}, acc)
  end

  defp collect({:unless, _, [condition, opts]}, ctx, acc) when is_list(opts) do
    {do_guard, else_guard} = branch(:unless, condition, ctx)
    acc = collect(condition, ctx, acc)
    acc = collect(Keyword.get(opts, :do), %{ctx | guarded?: do_guard}, acc)
    collect(Keyword.get(opts, :else), %{ctx | guarded?: else_guard}, acc)
  end

  defp collect({setup, meta, args}, ctx, acc)
       when setup in [:setup, :setup_all] and is_list(args) do
    acc = add_call(acc, ctx, {:local, setup, length(args), meta[:line]})
    collect(args, %{ctx | in_setup?: true}, acc)
  end

  defp collect({kind, _, [head, opts]}, ctx, acc)
       when kind in [:def, :defp, :defmacro, :defmacrop] and is_list(opts) do
    fun = head_name(head)
    acc = update_in(acc.funcs, &Map.put_new(&1, fun, %{writes: [], calls: []}))
    collect(Keyword.get(opts, :do), %{ctx | fun: fun, guarded?: false, in_setup?: false}, acc)
  end

  defp collect({:use, meta, [{:__aliases__, _, parts} | rest]}, ctx, acc) do
    acc = add_call(acc, ctx, {:use, parts, meta[:line]})
    acc = collect(rest, ctx, acc)
    option = async_option(rest)

    cond do
      is_nil(option) -> acc
      ctx.in_quote? -> %{acc | quote_async: acc.quote_async or option != false}
      acc.async == nil -> %{acc | async: option}
      true -> acc
    end
  end

  defp collect({:alias, _, [{:__aliases__, _, parts}]}, _ctx, acc) do
    %{acc | aliases: Map.put(acc.aliases, List.last(parts), strip_elixir(parts))}
  end

  defp collect({:alias, _, [{:__aliases__, _, parts}, opts]}, _ctx, acc) when is_list(opts) do
    as =
      case Keyword.get(opts, :as) do
        {:__aliases__, _, as_parts} -> List.last(as_parts)
        _ -> List.last(parts)
      end

    %{acc | aliases: Map.put(acc.aliases, as, strip_elixir(parts))}
  end

  defp collect({:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]}, _ctx, acc) do
    Enum.reduce(children, acc, fn
      {:__aliases__, _, child}, a ->
        %{a | aliases: Map.put(a.aliases, List.last(child), strip_elixir(base) ++ child)}

      _other, a ->
        a
    end)
  end

  defp collect({:import, _, [{:__aliases__, _, parts} | _]}, _ctx, acc) do
    %{acc | imports: acc.imports ++ [expand(acc.aliases, parts)]}
  end

  defp collect({{:., _, [{:__aliases__, _, parts}, fun]}, meta, args}, ctx, acc)
       when is_atom(fun) do
    acc =
      if fun in @app_writes and expand_parts(acc.aliases, parts) == ["Application"] do
        add_write(acc, ctx, "Application.#{fun}", meta[:line])
      else
        add_call(acc, ctx, {:remote, parts, fun, length(args), meta[:line]})
      end

    collect(args, ctx, acc)
  end

  defp collect({{:., _, [:application, fun]}, meta, args}, ctx, acc) when fun in @erl_writes do
    acc = add_write(acc, ctx, ":application.#{fun}", meta[:line])
    collect(args, ctx, acc)
  end

  defp collect({{:., _, [{:__MODULE__, _, _}, fun]}, meta, args}, ctx, acc) when is_atom(fun) do
    acc = add_call(acc, ctx, {:self, fun, length(args), meta[:line]})
    collect(args, ctx, acc)
  end

  defp collect({{:., _, [target, _fun]}, _meta, args}, ctx, acc) do
    acc = collect(target, ctx, acc)
    collect(args, ctx, acc)
  end

  defp collect({fun, meta, args}, ctx, acc) when is_atom(fun) and is_list(args) do
    acc =
      if fun in @app_writes and "Application" in acc.imports do
        add_write(acc, ctx, "Application.#{fun}", meta[:line])
      else
        add_call(acc, ctx, {:local, fun, length(args), meta[:line]})
      end

    collect(args, ctx, acc)
  end

  defp collect({left, right}, ctx, acc), do: collect([left, right], ctx, acc)
  defp collect({_name, _meta, _context}, _ctx, acc), do: acc

  defp collect(list, ctx, acc) when is_list(list) do
    Enum.reduce(list, acc, fn node, a -> collect(node, ctx, a) end)
  end

  defp collect(_literal, _ctx, acc), do: acc

  # The guard state of each branch: whether the body runs only where the test
  # is sync. Only a `setup` or `setup_all` callback admits the guard.
  defp branch(:if, condition, ctx) do
    cond do
      ctx.in_setup? and async_tag?(condition) -> {ctx.guarded?, true}
      ctx.in_setup? and negated_async_tag?(condition) -> {true, ctx.guarded?}
      true -> {ctx.guarded?, ctx.guarded?}
    end
  end

  defp branch(:unless, condition, ctx) do
    cond do
      ctx.in_setup? and async_tag?(condition) -> {true, ctx.guarded?}
      ctx.in_setup? and negated_async_tag?(condition) -> {ctx.guarded?, true}
      true -> {ctx.guarded?, ctx.guarded?}
    end
  end

  defp async_tag?({{:., _, [Access, :get]}, _, [{tags, _, context}, :async]})
       when is_atom(tags) and is_atom(context),
       do: true

  defp async_tag?(_other), do: false

  defp negated_async_tag?({:not, _, [tag]}), do: async_tag?(tag)
  defp negated_async_tag?({:!, _, [tag]}), do: async_tag?(tag)
  defp negated_async_tag?(_other), do: false

  # `async:` as the `use` names it: a literal boolean, else `:unknown`.
  defp async_option(rest) do
    Enum.find_value(rest, fn
      opts when is_list(opts) ->
        case Keyword.fetch(opts, :async) do
          {:ok, value} when is_boolean(value) -> value
          {:ok, _unreadable} -> :unknown
          :error -> nil
        end

      _other ->
        nil
    end)
  end

  defp head_name({:when, _, [head | _]}), do: head_name(head)
  defp head_name({name, _, args}) when is_atom(name) and is_list(args), do: name
  defp head_name({name, _, _context}) when is_atom(name), do: name

  defp add_write(acc, ctx, what, line) do
    entry = %{what: what, line: line, guarded?: ctx.guarded?}
    update_fun(acc, ctx.fun, &%{&1 | writes: [entry | &1.writes]})
  end

  defp add_call(acc, ctx, call) do
    update_fun(acc, ctx.fun, &%{&1 | calls: [call | &1.calls]})
  end

  defp update_fun(acc, fun, change) do
    funcs = Map.update(acc.funcs, fun, change.(%{writes: [], calls: []}), change)
    %{acc | funcs: funcs}
  end

  defp merge(old, m) do
    funcs =
      Map.merge(old.funcs, m.funcs, fn _fun, a, b ->
        %{writes: a.writes ++ b.writes, calls: a.calls ++ b.calls}
      end)

    %{
      old
      | funcs: funcs,
        async: old.async or m.async,
        quote_async: old.quote_async or m.quote_async
    }
  end
end
