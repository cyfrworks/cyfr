# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.AsyncEnvGuardTest do
  @moduledoc """
  An async test module never writes application environment, and neither
  does code it runs. `Application.put_env` and `delete_env` are global to the
  VM, so an async test that writes them races every other suite.

  The scan parses every `*_test.exs` and every support file of every
  umbrella application (`Prima.Test.SourceTree`) as code. It attributes each
  write to the function that holds it and to the module that defines that
  function: `put_env`, `put_all_env` and `delete_env` of `Application`, however
  the call names it (qualified, through an alias, or through an import), and
  `:application.set_env` and `unset_env`. A comment or a string that names a
  write is no write.

  Code a user runs is part of the user. A `use` runs the code its case carries:
  the `setup` and `setup_all` callbacks of a `use ExUnit.CaseTemplate` module,
  which ExUnit injects into every user; the body of a template's `using` block;
  and the quoted code of a `defmacro __using__`. The imports and aliases that
  code holds apply to the user as well, so an unqualified call resolves through
  them, and a case's own `use`s carry theirs on.

  A module is async when its own `use` says `async: true`, or when it `use`s a
  case whose quoted `use` does. A write is a violation when it is unguarded and
  sits in an async module, or when an async module calls a function that writes
  unguarded. The call is reported at its line, and a `use` of a case is such a
  call, so the injected code of a case is reported at the user's `use`.

  A write is admitted when it is guarded on the test's async tag inside a
  `setup` or `setup_all` callback, as `apps/cyfr/test/support/conn_case.ex`
  guards its own: `unless tags[:async]` runs its body only in a sync test, and
  so does `if not tags[:async]`, and the `else` of `if tags[:async]` does too.
  A guard anywhere else admits nothing, since a helper's `tags` may be any map.
  `async:` given as anything but a literal boolean is read as async.

  These blind spots hide a violation rather than flag one, and stay the
  reviewer's: a function value called through a variable (`f.(x)`, `apply/3`),
  a call the scan cannot resolve to a module of the tree, a module nested in
  another (which does not see the outer module's aliases or imports), and code
  a test compiles at run time from a string, which is text here. Three things
  over-flag instead: a call resolves by name, so a function of the same name at
  another arity counts; a capture of a writer (`&Application.put_env/3`)
  counts as a write where it is taken; and injected code counts whether or not
  the user calls what it defines.
  """

  use ExUnit.Case, async: true

  alias Prima.Test.SourceTree

  @app_writes [:put_env, :delete_env, :put_all_env]
  @erl_writes [:set_env, :unset_env]
  @conn_case "apps/cyfr/test/support/conn_case.ex"

  defp root, do: Path.expand("../../../..", __DIR__)

  test "no async module writes application environment, directly or through code it runs" do
    %{violations: violations} = scan(tree_sources())

    assert violations == [],
           "async tests write application env, which is global to the VM:\n" <>
             Enum.map_join(violations, "\n", & &1.message)
  end

  test "the walk reads test and support files, and conn_case holds exactly its two admitted writes" do
    sources = tree_sources()

    assert Enum.any?(sources, fn {path, _} -> String.ends_with?(path, "_test.exs") end)
    assert Enum.any?(sources, fn {path, _} -> path == @conn_case end)

    %{writes: writes} = scan(sources)
    in_file = for w <- writes, w.file == @conn_case, do: {w.line, w.what, w.guarded?}

    assert Enum.sort(in_file) == [
             {98, "Application.put_env", true},
             {99, "Application.delete_env", true}
           ],
           "conn_case.ex must hold its two admitted writes and no other: #{inspect(in_file)}"
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

    test "a CaseTemplate's setup runs in every user: an unguarded write beside a guarded pair is found, at the use" do
      template = """
      defmodule Plant.ConnCase do
        use ExUnit.CaseTemplate

        using do
          quote do
            import Plant.ConnCase
          end
        end

        setup tags do
          unless tags[:async] do
            Application.put_env(:plant, :guarded, 1)
            on_exit(fn -> Application.delete_env(:plant, :guarded) end)
          end

          Application.put_env(:plant, :leaked, 1)
          :ok
        end
      end
      """

      user = """
      defmodule Plant.ConnUserTest do
        use Plant.ConnCase, async: true

        test "ok", do: assert(true)
      end
      """

      result = scan([{"plant/conn_case.ex", template}, {"plant/conn_user_test.exs", user}])

      assert [%{file: "plant/conn_user_test.exs", line: 2, module: "Plant.ConnUserTest"}] =
               result.violations

      assert [_, _] = for(a <- result.admitted, a.file == "plant/conn_case.ex", do: a)
    end

    test "a CaseTemplate whose setup writes only under the guard leaves its users clean" do
      template = """
      defmodule Plant.GuardedCase do
        use ExUnit.CaseTemplate

        setup tags do
          unless tags[:async] do
            Application.put_env(:plant, :guarded, 1)
          end

          :ok
        end
      end
      """

      user = """
      defmodule Plant.GuardedUserTest do
        use Plant.GuardedCase, async: true

        test "ok", do: assert(true)
      end
      """

      assert %{violations: []} =
               scan([{"plant/guarded_case.ex", template}, {"plant/guarded_user_test.exs", user}])
    end

    test "an unqualified call resolves through an import in a case's quoted using, and that call writes" do
      template = """
      defmodule Plant.ImportedCase do
        use ExUnit.CaseTemplate

        using do
          quote do
            import Plant.ImportedCase
          end
        end

        def clear, do: Application.delete_env(:plant, :key)
      end
      """

      user = """
      defmodule Plant.ImportedUserTest do
        use Plant.ImportedCase, async: true

        test "calls" do
          clear()
        end
      end
      """

      assert [%{file: "plant/imported_user_test.exs", line: 5, module: "Plant.ImportedUserTest"}] =
               scan([
                 {"plant/imported_case.ex", template},
                 {"plant/imported_user_test.exs", user}
               ]).violations
    end

    test "a setup written inside a case's quoted using is injected into its users" do
      template = """
      defmodule Plant.QuotedCase do
        use ExUnit.CaseTemplate

        using do
          quote do
            setup do
              Application.put_env(:plant, :quoted, 1)
              :ok
            end
          end
        end
      end
      """

      user = """
      defmodule Plant.QuotedUserTest do
        use Plant.QuotedCase, async: true

        test "uses", do: assert(true)
      end
      """

      assert [%{file: "plant/quoted_user_test.exs", line: 2, module: "Plant.QuotedUserTest"}] =
               scan([{"plant/quoted_case.ex", template}, {"plant/quoted_user_test.exs", user}]).violations
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

  # The pure scan: sources in, the violations, every env write and the admitted
  # ones out.
  defp scan(sources) do
    modules = Enum.flat_map(sources, fn {path, source} -> modules_of(path, source) end)

    index =
      Enum.reduce(modules, %{}, fn m, acc -> Map.update(acc, m.name, m, &merge(&1, m)) end)

    views = Map.new(index, fn {name, m} -> {name, effective(index, m)} end)
    async = Enum.filter(modules, &async?(index, views, &1))

    direct =
      for m <- async, {fun, f} <- m.funcs, write <- f.writes, not write.guarded? do
        violation(m, write.line, "#{write.what} in #{m.name}.#{fun}, an async module")
      end

    through =
      for m <- async,
          {fun, f} <- m.funcs,
          call <- f.calls,
          {target, target_fun} <- resolve(index, views, m, call),
          target != m.name,
          writes?(index, views, target, target_fun, []) do
        violation(
          m,
          call_line(call),
          "#{m.name}.#{fun} calls #{target}.#{target_fun}, which writes application env"
        )
      end

    writes =
      for m <- modules, {_fun, f} <- m.funcs, write <- f.writes do
        Map.put(write, :file, m.file)
      end

    admitted =
      for write <- writes, write.guarded? do
        %{file: write.file, line: write.line, what: write.what}
      end

    %{
      violations: Enum.sort_by(direct ++ through, &{&1.file, &1.line}),
      admitted: admitted,
      writes: writes
    }
  end

  # A module is async when its own `use` says so, or when a case it `use`s says
  # so in its quoted `use`: the users of such a case run async with it.
  defp async?(index, views, m) do
    m.async or
      Enum.any?(m.funcs, fn {_fun, f} ->
        Enum.any?(f.calls, &quote_async_use?(index, views, m, &1))
      end)
  end

  defp quote_async_use?(index, views, m, {:use, parts, _line}) do
    case index[expand(view(views, m).aliases, parts)] do
      %{quote_async: quote_async} -> quote_async
      nil -> false
    end
  end

  defp quote_async_use?(_index, _views, _m, _call), do: false

  defp violation(m, line, reason) do
    %{file: m.file, line: line, module: m.name, message: "#{m.file}:#{line} #{reason}"}
  end

  # Whether `fun` of `module` writes unguarded, directly or through a call it
  # resolves. `seen` breaks cycles.
  defp writes?(index, views, module, fun, seen) do
    key = {module, fun}

    with false <- key in seen,
         %{funcs: funcs} = mod <- index[module],
         %{} = f <- funcs[fun] do
      Enum.any?(f.writes, &(not &1.guarded?)) or
        Enum.any?(f.calls, fn call ->
          Enum.any?(resolve(index, views, mod, call), fn {target, target_fun} ->
            writes?(index, views, target, target_fun, [key | seen])
          end)
        end)
    else
      _no_function -> false
    end
  end

  # The tree's functions a call names, as `{module, fun}`. Names resolve through
  # the aliases and imports in force for the module, injected ones included.
  defp resolve(index, views, mod, {:remote, parts, fun, _arity, _line}) do
    name = expand(view(views, mod).aliases, parts)
    if Map.has_key?(index, name), do: [{name, fun}], else: []
  end

  defp resolve(_index, _views, mod, {:self, fun, _arity, _line}), do: [{mod.name, fun}]

  defp resolve(index, views, mod, {:local, fun, _arity, _line}) do
    if Map.has_key?(mod.funcs, fun) do
      [{mod.name, fun}]
    else
      for i <- view(views, mod).imports,
          Map.has_key?(index, i) and Map.has_key?(index[i].funcs, fun),
          do: {i, fun}
    end
  end

  defp resolve(index, views, mod, {:use, parts, _line}) do
    name = expand(view(views, mod).aliases, parts)

    case index[name] do
      nil -> []
      used -> [{name, :__using__} | if(used.template?, do: [{name, :__setup__}], else: [])]
    end
  end

  defp view(views, m), do: Map.get(views, m.name, %{aliases: m.aliases, imports: m.imports})

  # What a module's code sees: its own aliases and imports, and those its cases
  # carry into it, through the cases they use in turn.
  defp effective(index, mod) do
    inherited = injection(index, mod, [mod.name])

    %{
      aliases: Map.merge(inherited.aliases, mod.aliases),
      imports: mod.imports ++ inherited.imports
    }
  end

  # The imports and aliases the cases a module `use`s carry into it.
  defp injection(index, mod, seen) do
    mod.funcs
    |> Enum.flat_map(fn {_fun, f} ->
      for {:use, parts, _line} <- f.calls, do: expand(mod.aliases, parts)
    end)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in seen or not Map.has_key?(index, &1)))
    |> Enum.reduce(%{imports: [], aliases: %{}}, fn name, acc ->
      used = index[name]
      deeper = injection(index, used, [name | seen])

      %{
        imports: acc.imports ++ used.inj_imports ++ deeper.imports,
        aliases: Map.merge(deeper.aliases, Map.merge(used.inj_aliases, acc.aliases))
      }
    end)
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
        template?: info.template?,
        aliases: info.aliases,
        imports: info.imports,
        inj_aliases: info.inj_aliases,
        inj_imports: info.inj_imports,
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
      collect(body, %{guarded?: false, fun: :module, injected?: false, in_setup?: false}, %{
        async: nil,
        quote_async: false,
        template?: false,
        aliases: %{},
        imports: [],
        inj_aliases: %{},
        inj_imports: [],
        funcs: %{}
      })

    %{acc | async: acc.async not in [nil, false]}
  end

  defp collect({:defmodule, _, _}, _ctx, acc), do: acc
  defp collect({:__aliases__, _, _}, _ctx, acc), do: acc

  defp collect({:quote, _, args}, ctx, acc), do: collect(args, %{ctx | injected?: true}, acc)

  # The body of a template's `using` block is code every user runs.
  defp collect({:using, _meta, [[do: body]]}, ctx, acc) do
    collect(
      body,
      %{ctx | fun: :__using__, injected?: true, guarded?: false, in_setup?: false},
      acc
    )
  end

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

  # A `setup` callback of a module that is not injected code is the module's own
  # `__setup__`: a template injects it into every user.
  defp collect({setup, meta, args}, ctx, acc)
       when setup in [:setup, :setup_all] and is_list(args) do
    acc = add_call(acc, ctx, {:local, setup, length(args), meta[:line]})
    body_fun = if ctx.injected?, do: ctx.fun, else: :__setup__
    collect(args, %{ctx | fun: body_fun, in_setup?: true}, acc)
  end

  # Injected code keeps the function it sits in: a `def` quoted into a user is
  # the case's code, not a function of its own.
  defp collect({kind, _, [head, opts]}, ctx, acc)
       when kind in [:def, :defp, :defmacro, :defmacrop] and is_list(opts) do
    fun = if ctx.injected?, do: ctx.fun, else: head_name(head)
    acc = update_in(acc.funcs, &Map.put_new(&1, fun, %{writes: [], calls: []}))
    collect(Keyword.get(opts, :do), %{ctx | fun: fun, guarded?: false, in_setup?: false}, acc)
  end

  defp collect({:use, meta, [{:__aliases__, _, parts} | rest]}, ctx, acc) do
    acc = add_call(acc, ctx, {:use, parts, meta[:line]})

    acc =
      if parts == [:ExUnit, :CaseTemplate] and not ctx.injected?,
        do: %{acc | template?: true},
        else: acc

    acc = collect(rest, ctx, acc)
    option = async_option(rest)

    cond do
      is_nil(option) -> acc
      ctx.injected? -> %{acc | quote_async: acc.quote_async or option != false}
      acc.async == nil -> %{acc | async: option}
      true -> acc
    end
  end

  defp collect({:alias, _, [{:__aliases__, _, parts}]}, ctx, acc) do
    put_alias(acc, ctx, List.last(parts), strip_elixir(parts))
  end

  defp collect({:alias, _, [{:__aliases__, _, parts}, opts]}, ctx, acc) when is_list(opts) do
    as =
      case Keyword.get(opts, :as) do
        {:__aliases__, _, as_parts} -> List.last(as_parts)
        _ -> List.last(parts)
      end

    put_alias(acc, ctx, as, strip_elixir(parts))
  end

  defp collect({:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]}, ctx, acc) do
    Enum.reduce(children, acc, fn
      {:__aliases__, _, child}, a ->
        put_alias(a, ctx, List.last(child), strip_elixir(base) ++ child)

      _other, a ->
        a
    end)
  end

  defp collect({:import, _, [{:__aliases__, _, parts} | _]}, ctx, acc) do
    put_import(acc, ctx, expand(visible_aliases(acc), parts))
  end

  defp collect({{:., _, [{:__aliases__, _, parts}, fun]}, meta, args}, ctx, acc)
       when is_atom(fun) do
    acc =
      if fun in @app_writes and expand_parts(visible_aliases(acc), parts) == ["Application"] do
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
      if fun in @app_writes and "Application" in visible_imports(acc) do
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

  # An alias or an import inside injected code is the user's; anywhere else it
  # is the module's own.
  defp put_alias(acc, %{injected?: true}, name, parts) do
    %{acc | inj_aliases: Map.put(acc.inj_aliases, name, parts)}
  end

  defp put_alias(acc, _ctx, name, parts) do
    %{acc | aliases: Map.put(acc.aliases, name, parts)}
  end

  defp put_import(acc, %{injected?: true}, name),
    do: %{acc | inj_imports: acc.inj_imports ++ [name]}

  defp put_import(acc, _ctx, name), do: %{acc | imports: acc.imports ++ [name]}

  defp visible_aliases(acc), do: Map.merge(acc.inj_aliases, acc.aliases)
  defp visible_imports(acc), do: acc.imports ++ acc.inj_imports

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
        quote_async: old.quote_async or m.quote_async,
        template?: old.template? or m.template?,
        aliases: Map.merge(old.aliases, m.aliases),
        imports: old.imports ++ m.imports,
        inj_aliases: Map.merge(old.inj_aliases, m.inj_aliases),
        inj_imports: old.inj_imports ++ m.inj_imports
    }
  end
end
