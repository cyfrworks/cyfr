# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.LoggerRosterTest do
  @moduledoc """
  The log's metadata roster is one list, `config/config.exs`'s: the JSON
  format `config/runtime.exs` selects and `Prima.JsonFormatter` read it,
  and neither holds a copy of its own.

  Config files run before application code is loaded, so the roster cannot
  literally be one expression. It can be one *checked* expression: the keys
  `Prima.LoggerContext` sets must be the keys the formatter is configured to
  print, or the metadata is written and silently dropped.
  """

  use ExUnit.Case, async: true

  # The one module that formats an exception for every application
  # (`Prima.LogFilter`).
  @formatter Prima.LogFilter

  # Every `Exception` function that writes a frame's or a call's arguments
  # into text: a stacktrace, an exit naming its call, an MFA, or a
  # function-clause error blamed with its arguments.
  @formatters [
    :blame,
    :blame_mfa,
    :format,
    :format_banner,
    :format_exit,
    :format_stacktrace,
    :format_stacktrace_entry,
    :format_mfa,
    :format_fa
  ]

  # `{path, "function/arity"} => reason` for a function the reason check
  # neither reads nor follows a reason into, each with why nothing it
  # writes or returns of a reason carries a frame, a call or an argument.
  @inspected_reasons %{
    {"apps/cyfr/lib/aqua/loop.ex", "describe/1"} =>
      "renders a reason through Sanctum.Refusals.render/1; it inspects only the account " <>
        "a setup_required refusal names",
    {"apps/cyfr/lib/opus/attempt.ex", "reason_shape/1"} =>
      "keeps a reason's atom, its tag or its exception's module, and redacts the rest"
  }

  defp root, do: Path.expand("../../../..", __DIR__)

  test "the configured roster carries every key LoggerContext sets" do
    configured = Application.get_env(:logger, :default_formatter, [])[:metadata]

    assert is_list(configured),
           "config/config.exs must set :logger, :default_formatter, metadata: [...]"

    missing = Prima.LoggerContext.keys() -- configured

    assert missing == [],
           """
           `Prima.LoggerContext` sets metadata the log roster does not print:

             #{inspect(missing)}

           Add them to `metadata:` in config/config.exs, or stop setting them.
           """
  end

  test "no application formats an exception but through Prima.LogFilter" do
    calls =
      for app <- applications(),
          {module, beam} <- lib_beams(app),
          module != @formatter,
          call <- exception_formatters(beam),
          do: {module, call}

    assert calls == [],
           """
           These write a frame's or a call's arguments into text:

             #{Enum.map_join(calls, "\n  ", &inspect/1)}

           Use Prima.LogFilter.format_exception/3 or format_stacktrace/1.
           """

    assert {Exception, :format, 3} in imports(beam!(@formatter))
  end

  test "a planted Exception.format is refused" do
    on_exit(fn ->
      :code.purge(Cyfr.LoggerRosterTest.Plant)
      :code.delete(Cyfr.LoggerRosterTest.Plant)
    end)

    [{_module, beam}] =
      Code.compile_string("""
      defmodule Cyfr.LoggerRosterTest.Plant do
        def text(error, stacktrace), do: Exception.format(:error, error, stacktrace)
      end
      """)

    assert exception_formatters(beam) == [{Exception, :format, 3}]
  end

  test "no application writes a caught reason or a rescued message but through Prima.LogFilter" do
    sites =
      for path <- Path.wildcard(Path.join(root(), "apps/*/lib/**/*.ex")),
          relative = Path.relative_to(path, root()),
          {function, line, call} <- inspected_reasons(File.read!(path), listed(relative)),
          do: "#{relative}:#{line} #{function} #{call}"

    assert sites == [],
           """
           These write a reason a clause binds as caught, rescued or exited,
           or a rescued exception's message, frames, calls and arguments
           whole:

             #{Enum.join(sites, "\n  ")}

           Use Prima.LogFilter.inspect_reason/2 or exception_message/1.
           """

    for {{relative, function}, reason} <- @inspected_reasons do
      path = Path.join(root(), relative)

      assert File.exists?(path) and function in defined(File.read!(path)) and reason != "",
             "#{relative} defines no #{function}: delete its entry"
    end
  end

  test "each shape that binds and writes a reason is found" do
    source = """
    defmodule Plant do
      alias Kernel, as: K

      def caught do
        run()
      catch
        kind, reason -> log(kind, inspect(reason))
      end

      def rescued do
        run()
      rescue
        e in [ArgumentError] -> log(Kernel.inspect(e, limit: 5))
      end

      def down({:DOWN, _ref, :process, _pid, reason}), do: log("\#{inspect(reason)}")

      def exited(task) do
        case Task.yield(task) do
          {:exit, reason} -> log(inspect(reason))
          {:ok, value} -> log(inspect(value))
        end
      end

      def linked do
        receive do
          {:EXIT, _pid, why} -> log(inspect(why))
        end
      end

      def terminate(reason, _state), do: log(inspect(reason))

      def piped do
        run()
      catch
        :exit, reason -> reason |> mask() |> inspect() |> log()
      end

      def guarded do
        run()
      catch
        :exit, reason when reason != :normal -> log(inspect(reason))
      end

      def destructured do
        run()
      catch
        :exit, {why, _call} -> log(inspect({:exited, why}))
      end

      def rebound do
        run()
      catch
        :exit, reason ->
          held = reason
          log(inspect(held))
      end

      def cased do
        run()
      catch
        :exit, reason ->
          case reason do
            {:shutdown, inner} -> log(inspect(inner))
          end
      end

      def printed do
        run()
      catch
        :exit, reason -> IO.inspect(reason)
      end

      def formatted do
        run()
      catch
        :exit, reason -> log(:io_lib.format(~c"~p", [reason]))
      end

      def handed do
        run()
      catch
        :exit, reason -> log_it(reason)
      end

      def handed_on({:DOWN, _ref, :process, _pid, reason}), do: relay(:down, reason)

      def messaged do
        run()
      rescue
        e -> log(Exception.message(e))
      end

      def messaged_piped do
        run()
      rescue
        e -> e |> Exception.message() |> log()
      end

      def thrown do
        run()
      catch
        {:failed, reason} -> log(inspect(reason))
      end

      def thrown_whole do
        run()
      catch
        value when value != :ok -> log(inspect(value))
      end

      def reduced do
        run()
      catch
        :exit, reason -> log(Prima.LogFilter.inspect_reason(reason))
      end

      def typed do
        run()
      rescue
        e in [ArgumentError] -> log(Exception.message(e))
      end

      def named do
        run()
      catch
        :error, %module{} = e -> log(inspect(module) <> inspect(e.__struct__))
      end

      def shaped do
        run()
      catch
        :exit, reason -> log(inspect(shape(reason)))
      end

      def named_down({:DOWN, _ref, :process, _pid, reason}) when is_atom(reason),
        do: log(inspect(reason))

      def named_exit do
        run()
      catch
        :exit, reason -> log(named(reason))
      end

      def named_thrown do
        run()
      catch
        value when is_atom(value) -> log(inspect(value))
      end

      # Read by no rule: the forms the check's comment names.
      def captured do
        run()
      catch
        :exit, reason -> log(Enum.map_join([reason], &inspect/1))
      end

      def applied do
        run()
      catch
        :exit, reason -> log(apply(Kernel, :inspect, [reason]))
      end

      def aliased do
        run()
      catch
        :exit, reason -> log(K.inspect(reason))
      end

      defp log_it(reason), do: log(inspect(reason))
      defp relay(_tag, term), do: log_it(term)
      defp shape(reason), do: elem(reason, 0)
      defp named(reason) when is_atom(reason) and reason != nil, do: inspect(reason)
      defp named(_reason), do: "a term"
    end
    """

    assert inspected_reasons(source, ["shape/1"])
           |> Enum.map(&elem(&1, 0))
           |> Enum.uniq()
           |> Enum.sort() ==
             ~w(cased/0 caught/0 destructured/0 down/1 exited/1 formatted/0 guarded/0
                handed/0 handed_on/1 linked/0 messaged/0 messaged_piped/0 piped/0
                printed/0 rebound/0 rescued/0 terminate/2 thrown/0 thrown_whole/0)
  end

  test "runtime.exs overrides only the format, never the roster" do
    runtime = File.read!(Path.join(root(), "config/runtime.exs"))

    lines = String.split(runtime, "\n")

    # The call and any continuation lines its keyword list spills onto.
    json_branch =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, _i} ->
        String.contains?(line, "config :logger, :default_formatter")
      end)
      |> Enum.flat_map(fn {_line, i} -> Enum.slice(lines, i, 4) end)

    assert json_branch != [], "the JSON log format branch went missing"

    refute Enum.any?(json_branch, &String.contains?(&1, "metadata")),
           """
           config/runtime.exs re-declares the metadata roster. `Config`
           deep-merges keyword values, so config.exs's roster already carries
           through; a second copy only supplies something to go stale.
           """
  end

  # Every Mix application of the umbrella, by its directory's name; the Go
  # programs have none.
  defp applications do
    apps =
      for mix <- Path.wildcard(Path.join(root(), "apps/*/mix.exs")),
          do: mix |> Path.dirname() |> Path.basename()

    assert "prima" in apps and "cyfr" in apps and "locus" in apps
    apps
  end

  # Every module of `app` compiled from this checkout's apps/<app>/lib,
  # with its beam. The applications share one build, read from disk, so an
  # application this one does not depend on is read too; an application
  # that yields none was built elsewhere, and the check would read nothing.
  defp lib_beams(app) do
    ebin = Path.join([Mix.Project.build_path(), "lib", app, "ebin"])
    lib = Path.join([root(), "apps", app, "lib"]) <> "/"

    beams =
      for path <- Path.wildcard(Path.join(ebin, "*.beam")),
          {:ok, {module, [compile_info: info]}} =
            :beam_lib.chunks(String.to_charlist(path), [:compile_info]),
          String.starts_with?(to_string(info[:source]), lib),
          do: {module, File.read!(path)}

    assert beams != [], "no module of #{app} under #{ebin} was compiled from #{lib}"
    beams
  end

  defp beam!(module), do: elem(:code.get_object_code(module), 1)

  defp exception_formatters(beam),
    do: for({Exception, f, _a} = call <- imports(beam), f in @formatters, do: call)

  defp imports(beam) do
    {:ok, {_module, [imports: imports]}} = :beam_lib.chunks(beam, [:imports])
    imports
  end

  # `{"function/arity", line, call}` for each write into text of a
  # reason a clause binds, but through `Prima.LogFilter`.
  #
  # A reason is what a `catch` binds as its reason or as the value thrown,
  # guarded or destructured; what a rescue binds; what a `:DOWN`, `:EXIT`
  # or `{:exit, _}` pattern binds in a clause or a function head; what
  # `terminate/2,3` is handed; and a variable matched from one, by `=` or
  # by a `case` on it. A write is `inspect/1,2`, `Kernel.inspect`,
  # `IO.inspect` or `:io_lib.format` of a reason, of a term holding one,
  # or of a call handed one first (`reason |> mask() |> inspect()`);
  # `Exception.message/1` of what a rescue of any kind binds; and a call
  # of a function of the same file whose parameter reaches a write,
  # however many such calls away. A call of `Prima.LogFilter` applies the
  # filter's rule, and a struct's module or field, or a variable a guard
  # holds to an atom, a number or a binary, is no reason.
  #
  # Not read: a captured `&inspect/1`, which is handed on as a value and
  # applied where nothing names the reason; `apply/3`, which names its
  # function as data; an aliased `Kernel`, since a call is read without
  # its module's aliases; a reason passed as a later argument of a call
  # (`inspect(Map.put(m, :why, reason))`), since only the first argument
  # is read as what a call returns, as a pipe hands it, and a later one
  # is as often a key, an option or a default; a `with` clause's binding
  # from a reason, since only `=` and a `case` on the reason are read as
  # matches; and a reason handed to another module's function or held in
  # a term read later, since a file is read alone.
  defp inspected_reasons(source, listed) do
    definitions =
      for {name, args, _scalars, _body} = definition <- definitions(source),
          "#{name}/#{length(args)}" not in listed,
          do: definition

    scope = helpers(definitions, %{listed: listed, helpers: MapSet.new()})

    for {name, args, scalars, body} <- definitions,
        {line, call} <- Enum.uniq(reasons_in(name, args, scalars, body, scope)),
        do: {"#{name}/#{length(args)}", line, call}
  end

  defp listed(relative),
    do: for({{^relative, function}, _reason} <- @inspected_reasons, do: function)

  defp defined(source),
    do: for({name, args, _scalars, _body} <- definitions(source), do: "#{name}/#{length(args)}")

  # Every `def` and `defp` clause as `{name, args, scalars, body}`, with
  # the variables its guard holds to a scalar, a pipe read as the call it
  # makes (`a |> f(b)` as `f(a, b)`).
  defp definitions(source) do
    {_ast, definitions} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk(&unpipe/1)
      |> Macro.prewalk([], fn
        {kind, _, [head, [{:do, _} | _] = body]} = node, acc when kind in [:def, :defp] ->
          {name, args, scalars} = signature(head)
          {node, [{name, args, scalars, body} | acc]}

        node, acc ->
          {node, acc}
      end)

    definitions
  end

  defp unpipe({:|>, _, [left, right]} = pipe) do
    Macro.pipe(left, right, 0)
  rescue
    ArgumentError -> pipe
  end

  defp unpipe(node), do: node

  defp signature({:when, _, [head, guard]}),
    do: head |> signature() |> put_elem(2, scalars(guard))

  defp signature({name, _, args}) when is_list(args), do: {name, args, []}
  defp signature({name, _, _context}), do: {name, [], []}

  # A clause's patterns, and the variables its guard holds to a scalar.
  defp unguarded([{:when, _, patterns_and_guard}]) do
    {patterns, [guard]} = Enum.split(patterns_and_guard, -1)
    {patterns, scalars(guard)}
  end

  defp unguarded(patterns), do: {patterns, []}

  # The variables a guard holds to an atom, a number or a binary, which
  # carry no frame or call: each `is_atom(x)` and the like the guard
  # requires, through `and` alone.
  defp scalars({:and, _, [left, right]}), do: scalars(left) ++ scalars(right)

  defp scalars({check, _, [{name, _, context}]})
       when check in [:is_atom, :is_binary, :is_bitstring, :is_boolean] and is_atom(name) and
              is_atom(context),
       do: [name]

  defp scalars({check, _, [{name, _, context}]})
       when check in [:is_float, :is_integer, :is_number] and is_atom(name) and
              is_atom(context),
       do: [name]

  defp scalars(_guard), do: []

  # The scope with `helpers`: `{name, arity, position, kind}` for each
  # parameter that reaches a write of `kind` in a clause of its function,
  # directly or through another such parameter.
  defp helpers(definitions, scope) do
    found =
      MapSet.new(
        for {name, args, scalars, body} <- definitions,
            {param, position} <- Enum.with_index(args),
            kind <- [:inspect, :message],
            writes(body, %{kind => bound(param) -- scalars}, scope) != [],
            do: {name, length(args), position, kind}
      )

    if MapSet.equal?(found, scope.helpers),
      do: scope,
      else: helpers(definitions, %{scope | helpers: found})
  end

  defp reasons_in(name, args, scalars, body, scope) do
    handed = if name == :terminate and length(args) in [2, 3], do: bound(hd(args)), else: []
    reasons = (handed ++ Enum.flat_map(args, &bound_reasons/1)) -- scalars
    from_head = writes(body, %{inspect: reasons}, scope)

    {_ast, nested} =
      Macro.prewalk(body, [], fn node, acc -> {node, clauses(node, scope) ++ acc} end)

    from_head ++ nested
  end

  defp clauses(keyword, scope) when is_list(keyword) do
    Enum.flat_map(keyword, fn
      {:catch, clauses} when is_list(clauses) -> Enum.flat_map(clauses, &caught(&1, scope))
      {:rescue, clauses} when is_list(clauses) -> Enum.flat_map(clauses, &rescued(&1, scope))
      _other -> []
    end)
  end

  defp clauses({:->, _, [patterns, body]}, scope) when is_list(patterns) do
    {patterns, scalars} = unguarded(patterns)
    writes(body, %{inspect: Enum.flat_map(patterns, &bound_reasons/1) -- scalars}, scope)
  end

  defp clauses(_node, _scope), do: []

  defp caught({:->, _, [[{:when, _, [_kind, reason, guard]}], body]}, scope),
    do: writes(body, %{inspect: bound(reason) -- scalars(guard)}, scope)

  defp caught({:->, _, [[_kind, reason], body]}, scope),
    do: writes(body, %{inspect: bound(reason)}, scope)

  defp caught({:->, _, [[{:when, _, [thrown, guard]}], body]}, scope),
    do: writes(body, %{inspect: bound(thrown) -- scalars(guard)}, scope)

  defp caught({:->, _, [[thrown], body]}, scope),
    do: writes(body, %{inspect: bound(thrown)}, scope)

  defp caught(_clause, _scope), do: []

  # A rescue of any kind can hold a `BadArityError`, whose message lists
  # the call's arguments; a typed rescue holds only the kinds it names.
  defp rescued({:->, _, [[{:in, _, [error, _modules]}], body]}, scope),
    do: writes(body, %{inspect: bound(error)}, scope)

  defp rescued({:->, _, [[error], body]}, scope),
    do: writes(body, %{inspect: bound(error), message: bound(error)}, scope)

  defp rescued(_clause, _scope), do: []

  defp bound_reasons(pattern) do
    {_ast, variables} =
      Macro.prewalk(pattern, [], fn
        {:{}, _, [:DOWN, _, _, _, reason]} = node, acc -> {node, bound(reason) ++ acc}
        {:{}, _, [:EXIT, _, reason]} = node, acc -> {node, bound(reason) ++ acc}
        {:exit, reason} = node, acc -> {node, bound(reason) ++ acc}
        node, acc -> {node, acc}
      end)

    variables
  end

  # The variables a pattern binds, a struct's module aside.
  defp bound(pattern) do
    {_ast, variables} =
      Macro.prewalk(pattern, [], fn
        {:^, _, _}, acc ->
          {:pinned, acc}

        {:@, _, _}, acc ->
          {:attribute, acc}

        {:%, meta, [_module, fields]}, acc ->
          {{:%, meta, [:module, fields]}, acc}

        {:__struct__, _module}, acc ->
          {:module, acc}

        {name, _, context} = node, acc when is_atom(name) and is_atom(context) ->
          if String.starts_with?(Atom.to_string(name), "_"),
            do: {node, acc},
            else: {node, [name | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(variables)
  end

  # `{line, "call(variable)"}` for each write in `body` of a variable
  # `tracked` holds, `%{kind => variables}`.
  defp writes(body, tracked, scope) do
    tracked =
      Map.new(tracked, fn {kind, variables} -> {kind, rebound(body, variables, scope)} end)

    if Enum.all?(tracked, fn {_kind, variables} -> variables == [] end) do
      []
    else
      {_ast, found} =
        Macro.prewalk(body, [], fn node, acc -> {node, written(node, tracked, scope) ++ acc} end)

      found
    end
  end

  defp written({:inspect, meta, [subject | _]}, tracked, scope),
    do: hit(meta, "inspect", [subject], tracked[:inspect], scope)

  defp written({{:., _, [{:__aliases__, _, [module]}, :inspect]}, meta, args}, tracked, scope)
       when module in [:Kernel, :IO] and is_list(args),
       do: hit(meta, "#{module}.inspect", args, tracked[:inspect], scope)

  defp written({{:., _, [:io_lib, :format]}, meta, [_format, args]}, tracked, scope),
    do: hit(meta, ":io_lib.format", [args], tracked[:inspect], scope)

  defp written(
         {{:., _, [{:__aliases__, _, [:Exception]}, :message]}, meta, [subject]},
         tracked,
         scope
       ),
       do: hit(meta, "Exception.message", [subject], tracked[:message], scope)

  defp written({name, meta, args}, tracked, scope) when is_atom(name) and is_list(args) do
    arity = length(args)

    for {^name, ^arity, position, kind} <- scope.helpers,
        found <- hit(meta, "#{name}", [Enum.at(args, position)], tracked[kind], scope),
        do: found
  end

  defp written(_node, _tracked, _scope), do: []

  defp hit(_meta, _call, _args, nil, _scope), do: []

  defp hit(meta, call, args, variables, scope) do
    case Enum.find_value(args, &subject(&1, variables, scope)) do
      nil -> []
      variable -> [{meta[:line], "#{call}(#{variable})"}]
    end
  end

  # The tracked variable an expression is, holds, or hands a call as its
  # first argument, as a pipe does, short of a call that reduces it.
  defp subject({name, _, context}, variables, _scope) when is_atom(name) and is_atom(context),
    do: if(name in variables, do: name)

  defp subject({{:., _, [{:__aliases__, _, [:Prima, :LogFilter]}, _]}, _, _}, _variables, _scope),
    do: nil

  defp subject({:{}, _, elements}, variables, scope),
    do: first_subject(elements, variables, scope)

  defp subject({:%{}, _, pairs}, variables, scope), do: first_subject(pairs, variables, scope)

  defp subject({:%, _, [_module, fields]}, variables, scope),
    do: subject(fields, variables, scope)

  defp subject({left, right}, variables, scope),
    do: first_subject([left, right], variables, scope)

  defp subject(list, variables, scope) when is_list(list),
    do: first_subject(list, variables, scope)

  defp subject({name, _, [first | _] = args}, variables, scope) do
    if is_atom(name) and "#{name}/#{length(args)}" in scope.listed,
      do: nil,
      else: subject(first, variables, scope)
  end

  defp subject(_other, _variables, _scope), do: nil

  defp first_subject(terms, variables, scope),
    do: Enum.find_value(terms, &subject(&1, variables, scope))

  # `variables` with each variable matched from one of them, by `=` or by
  # a `case` on it.
  defp rebound(_body, [], _scope), do: []

  defp rebound(body, variables, scope) do
    {_ast, more} =
      Macro.prewalk(body, variables, fn
        {:=, _, [left, right]} = node, acc ->
          if subject(right, acc, scope),
            do: {node, Enum.uniq(bound(left) ++ acc)},
            else: {node, acc}

        {:case, _, [{name, _, context}, [do: clauses]]} = node, acc
        when is_atom(name) and is_atom(context) and is_list(clauses) ->
          if name in acc,
            do: {node, Enum.uniq(Enum.flat_map(clauses, &clause_bound/1) ++ acc)},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    if length(more) == length(variables), do: variables, else: rebound(body, more, scope)
  end

  defp clause_bound({:->, _, [patterns, _body]}) do
    {patterns, scalars} = unguarded(patterns)
    bound(patterns) -- scalars
  end

  defp clause_bound(_other), do: []
end
