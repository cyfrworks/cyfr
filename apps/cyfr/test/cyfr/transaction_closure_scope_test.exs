# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.TransactionClosureScopeTest do
  @moduledoc """
  A transaction closure makes no network call and publishes nothing
  (`ARCHITECTURE.md` §4.4).

  The higher owner's part of a two-owner write enters Arca's transaction as
  a `verify:`, `also:` or `reserve:` closure, and runs with Arca's locks
  held. A network call there holds those locks for as long as a remote
  answers, and a broadcast there announces a write the transaction may
  still roll back: broadcast follows the commit, by the caller.

  The scan parses every `lib` source of every umbrella application and
  finds each `verify:`, `also:` or `reserve:` whose value is a closure it
  can read:

    * an `fn`, read where it is written;
    * a capture of a local function, `&name/n` or `&name(...)`, resolved
      to that function's definitions in its module;
    * a capture of another module's function, `&Mod.name/n` or
      `&Mod.name(...)`, resolved to that module's definitions in the tree;
    * a call that returns the closure, `verify(expectation)` or
      `Sanctum.Issuance.verify(expectation)`, resolved like a capture of
      the function it calls, whose whole body is read;
    * a variable bound once to one of these in the clause that passes it,
      before it is passed (`verify = fn -> … end` then `verify: verify`),
      read as that form at the line it is passed.

  From there it follows every call to a function defined in the same
  module, written plain or qualified (`f(x)`, `__MODULE__.f(x)`, `Mod.f(x)`
  in `Mod`), and every capture of a function the tree defines,
  transitively. A qualified call from there into another module of the
  same application (`Authz.consume(ctx, claim)` in Sanctum) is followed
  one module deep: into that module's function and the calls and captures
  it makes within its own module, but not into a third.

  It refuses a call to `Req`, `Finch`, `Mint`, `:httpc`, `:gen_tcp`,
  `:ssl`, `:inet`, `Sanctum.Egress`, `Sanctum.Network`, `Phoenix.PubSub`,
  `Sanctum.Notify` or `Task`, or to a function `Cyfr.Bus` publishes with
  (`broadcast*`), written through an `alias` or plain through an
  `import`, wherever the walk reaches it. A capture it cannot resolve is refused too, so a closure
  the scan cannot read never passes for one it read. A call the tree does
  not define (`args["verify"]` is `Access.get/2`) is no closure the scan
  can read, and is not counted.

  The scan reads code, not text: a comment, a documentation string or a
  string literal that names a refused call is no call.

  Those three names are every closure an Arca function takes, and that is
  derived from Arca's code rather than assumed: every option an Arca
  function reads out of its keyword list and treats as a function —
  defaults to an `fn`, applies (`also.(row)`), checks with `is_function/2`,
  hands to `Enum` as the function, iterates applying each element, or
  passes to a local function that does any of these — is one of them, or
  one of `@not_in_transaction`, the closures Arca applies with no
  transaction open, each with its reason. A closure under any other name
  would reach a transaction the scan does not read, so it fails here.

  Its blind spots: a variable bound more than once in its clause, or bound
  by a parameter, a clause head, a generator or a pattern (`also: also`
  passed through from a caller), is not followed; neither is a qualified
  call two modules away from the closure, nor one into another
  application. Those reach the transaction through code this scan does
  not read, so they stay the reviewer's.
  """

  use ExUnit.Case, async: true

  alias Prima.Test.SourceTree

  @keys [:verify, :also, :reserve]

  # The closures an Arca function takes that run with no transaction open,
  # by the function that applies them. Exact: an entry the derivation no
  # longer finds fails as one a closure under another name does.
  @not_in_transaction %{
    {"Arca", :copy_tree, :exclude} =>
      "a filter on the relative paths of a tree being listed, applied before any write",
    {"Arca", :copy_tree, :transform} =>
      "a file's bytes rewritten between their read and their write, each `put/4` its own write",
    {"Arca.Overlay", :entries, :exclude} => "a filter on the relative paths of a listing, a read"
  }

  # The modules a closure may not call, each with its submodules, and the
  # Erlang modules that open a connection or resolve a name.
  @refused_modules ~w(Req Finch Mint Sanctum.Egress Sanctum.Network Phoenix.PubSub Sanctum.Notify Task)
  @refused_erlang [:httpc, :gen_tcp, :ssl, :inet]

  # Every form a closure takes in the tree, each read at least once there.
  @forms [:fn, :local_capture, :local_call_capture, :remote_capture, :call]

  defp root, do: Path.expand("../../../..", __DIR__)

  defp tree do
    for lib <- SourceTree.app_libs(root()),
        path <- SourceTree.files!(Path.join([root(), lib, "**/*.ex"])),
        do: {Path.relative_to(path, root()), SourceTree.read(path)}
  end

  # Scans `sources` (`[{path, source}]`) as one tree: a remote capture or
  # call resolves to a module defined anywhere in it. Answers how many
  # closures it read, the forms they took, and what it refused in them.
  defp scan(sources) do
    modules = Enum.flat_map(sources, fn {path, source} -> modules(path, source) end)
    index = Map.new(modules, &{&1.name, &1})

    read =
      for module <- modules,
          {key, line, form, root, via} <- closures(module.body),
          readable?(form, root, module, index),
          do: {module.path, line, key, form, via, module.name, root}

    refused =
      for {path, line, key, _form, _via, name, root} <- read,
          what <- walk([{name, root, 0}], index, %{}, []),
          do: {path, line, key, what}

    %{
      read: length(read),
      bound: Enum.count(read, &(elem(&1, 4) == :bound)),
      forms: read |> Enum.map(&elem(&1, 3)) |> Enum.frequencies(),
      refused: refused |> Enum.uniq() |> Enum.sort()
    }
  end

  # A call is a closure the scan reads when the tree defines what it calls,
  # or when it is itself a refused call. Every other form is read, and an
  # unresolved capture is refused by the walk.
  defp readable?(:call, {:local, name, arity}, module, _index),
    do: Map.has_key?(module.defs, {name, arity}) or imported(module, name, arity) != nil

  defp readable?(:call, {:remote, target, name, arity}, module, index),
    do:
      defined?(resolve(target, module), name, arity, index) or
        forbidden?(resolve(target, module), name)

  defp readable?(_form, _root, _module, _index), do: true

  defp defined?(target, name, arity, index),
    do: is_map_key(index, target) and is_map_key(index[target].defs, {name, arity})

  # Every module a source defines: its full name, its application, its body
  # without the modules nested in it, its definitions, and the aliases and
  # imports in scope there, its enclosing modules' included.
  defp modules(path, source) do
    source
    |> Code.string_to_quoted!(columns: true, file: path)
    |> defmodules(path, %{name: nil, aliases: %{}, imports: []})
  end

  defp defmodules(ast, path, outer) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [{:__aliases__, _, parts}, [do: body]]}, acc ->
          name = name(parts, outer)
          own = strip_modules(body)
          scope = %{name: name, aliases: aliases(own, %{name: name, aliases: outer.aliases})}
          scope = Map.put(scope, :imports, imports(own, scope) ++ outer.imports)
          module = Map.merge(scope, %{path: path, app: app(path), body: own, defs: defs(own)})
          {nil, [module | defmodules(body, path, scope)] ++ acc}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # The application `apps/<app>/…` is in; every other path is one
  # application, the planted sources'.
  defp app(path) do
    case Path.split(path) do
      ["apps", app | _rest] -> app
      _other -> nil
    end
  end

  # A nested `defmodule B` inside `A` is `A.B`.
  defp name([{:__MODULE__, _, _} | rest], %{name: outer}), do: dotted([outer | rest])
  defp name(parts, %{name: nil}), do: dotted(parts)
  defp name(parts, %{name: outer}), do: dotted([outer | parts])

  defp strip_modules(body) do
    Macro.prewalk(body, fn
      {:defmodule, _meta, _args} -> nil
      node -> node
    end)
  end

  # `{name, arity}` to the bodies of its clauses, `def` and `defp` alike,
  # under every arity its default arguments give it.
  defp defs(body) do
    {_ast, acc} =
      Macro.prewalk(body, %{}, fn
        {kind, _meta, [head, opts]} = node, acc when kind in [:def, :defp] and is_list(opts) ->
          acc =
            for key <- heads(head),
                reduce: acc,
                do: (acc -> Map.update(acc, key, [opts], &[opts | &1]))

          {node, acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp heads({:when, _meta, [head | _guards]}), do: heads(head)

  defp heads({name, _meta, args}) when is_atom(name) and is_list(args) do
    defaults = Enum.count(args, &match?({:\\, _, _}, &1))
    for arity <- (length(args) - defaults)..length(args), do: {name, arity}
  end

  defp heads({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: [{name, 0}]
  defp heads(_other), do: []

  # `alias A.B`, `alias A.B, as: C`, `alias A.{B, C}` and `alias
  # __MODULE__` in `body`, with or without options such as `warn: false`,
  # as short name to full name, over the aliases of `scope`.
  defp aliases(body, scope) do
    {_ast, acc} =
      Macro.prewalk(body, scope.aliases, fn
        {:alias, _, [{{:., _, [base, :{}]}, _, members} | _]} = node, acc ->
          base = resolve(base, %{scope | aliases: acc})

          acc =
            for {:__aliases__, _, parts} <- members,
                into: acc,
                do: {List.last(parts), dotted([base | parts])}

          {node, acc}

        {:alias, _, [{:__aliases__, _, parts} = target | opts]} = node, acc ->
          short = short_name(opts, List.last(parts))
          {node, Map.put(acc, short, resolve(target, %{scope | aliases: acc}))}

        # `alias __MODULE__, as: Me` names the module itself.
        {:alias, _, [{:__MODULE__, _, _} = target | opts]} = node, acc ->
          short =
            short_name(
              opts,
              scope.name |> String.split(".") |> List.last() |> String.to_existing_atom()
            )

          {node, Map.put(acc, short, resolve(target, scope))}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # The name an alias is written under: its `as:`, or else `default`.
  defp short_name([kw], default) when is_list(kw) do
    case Keyword.get(kw, :as) do
      {:__aliases__, _, [as]} -> as
      _none -> default
    end
  end

  defp short_name([], default), do: default

  # `import A.B` and `import :mod` in `body`, with their `only:` and
  # `except:` lists, as `{module, only, except}`.
  defp imports(body, scope) do
    {_ast, acc} =
      Macro.prewalk(body, [], fn
        {:import, _, [target | opts]} = node, acc ->
          kw =
            case opts do
              [kw] when is_list(kw) -> kw
              _none -> []
            end

          {node, [{resolve(target, scope), kw[:only], kw[:except]} | acc]}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # The refused module `module` imports `name/arity` from, or `nil`. The
  # import supplies only what its module exports, so `=` or `case` beside a
  # bare `import Task` is not Task's; every refused module is loaded in the
  # host's test build, which is what answers.
  defp imported(module, name, arity) do
    Enum.find_value(module.imports, fn {target, only, except} ->
      if forbidden?(target, name) and listed?(only, name, arity, true) and
           not listed?(except, name, arity, false) and exports?(target, name, arity),
         do: target
    end)
  end

  defp exports?(target, name, arity) do
    module = if is_binary(target), do: Module.safe_concat([target]), else: target

    Code.ensure_loaded?(module) and
      (function_exported?(module, name, arity) or macro_exported?(module, name, arity))
  end

  defp listed?(list, name, arity, _default) when is_list(list), do: {name, arity} in list
  defp listed?(_absent, _name, _arity, default), do: default

  defp dotted(parts), do: Enum.map_join(parts, ".", &to_string/1)

  # The module a call or a capture names, as its full name, or the atom of
  # an Erlang module. `nil` when it is computed.
  defp resolve({:__aliases__, _meta, [{:__MODULE__, _, _} | tail]}, scope),
    do: dotted([scope.name | tail])

  defp resolve({:__aliases__, _meta, [head | tail]}, scope) when is_atom(head),
    do: dotted([Map.get(scope.aliases, head, head) | tail])

  defp resolve({:__MODULE__, _meta, _ctx}, scope), do: scope.name
  defp resolve(atom, _scope) when is_atom(atom), do: atom
  defp resolve(_other, _scope), do: nil

  # Each `key: closure` in `body` that may be a closure, as `{key, line,
  # form, root, via}`: written where it is passed (`:written`), or a
  # variable the definition's clause binds once, before it is passed, to a
  # form `closure/1` reads (`:bound`). A literal, a type or any other
  # variable is none.
  defp closures(body), do: passed(body, nil)

  # `bound` is the bindings of the clause `ast` lies in, or `nil` outside
  # every definition.
  defp passed(ast, bound) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [_head, opts]} = clause, acc
        when kind in [:def, :defp] and is_list(opts) and is_nil(bound) ->
          {nil, passed(clause, bindings(clause)) ++ acc}

        {key, value} = node, acc when key in @keys ->
          {node, entry(key, value, bound || %{}) ++ acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp entry(key, value, bound) do
    case closure(value) do
      {line, form, root} -> [{key, line, form, root, :written}]
      nil -> bound_entry(key, value, bound)
    end
  end

  # `key: name` where the clause binds `name` once, by `name = value` on a
  # line at or before this one, to a closure: read at the line it is passed.
  defp bound_entry(key, {name, meta, ctx}, bound) when is_atom(name) and is_atom(ctx) do
    with {line, value} <- Map.get(bound, name),
         true <- line <= meta[:line],
         {_line, form, root} <- closure(value) do
      [{key, meta[:line], form, root, :bound}]
    else
      _none -> []
    end
  end

  defp bound_entry(_key, _value, _bound), do: []

  # The variables a definition's clause binds exactly once, by `name =
  # value`, as name to `{line, value}`. A variable it binds anywhere else
  # as well (a parameter, a clause head, a generator, a pattern or a second
  # match) is none: which binding a use reads is then the reviewer's.
  defp bindings({_kind, _meta, [head, opts]}) do
    {_ast, {sites, plain}} =
      Macro.prewalk(opts, {pattern_vars(head, %{}), %{}}, fn
        {:=, meta, [lhs, value]} = node, {sites, plain} ->
          plain =
            case lhs do
              {name, _, ctx} when is_atom(name) and is_atom(ctx) ->
                Map.put(plain, name, {meta[:line], value})

              _pattern ->
                plain
            end

          {node, {pattern_vars(lhs, sites), plain}}

        {op, _, [lhs, _rhs]} = node, {sites, plain} when op in [:<-, :->] ->
          {node, {pattern_vars(lhs, sites), plain}}

        node, acc ->
          {node, acc}
      end)

    for {name, binding} <- plain, sites[name] == 1, into: %{}, do: {name, binding}
  end

  # `sites` with one more for each variable `pattern` binds; a pinned one
  # binds nothing.
  defp pattern_vars(pattern, sites) do
    {_ast, sites} =
      Macro.prewalk(pattern, sites, fn
        {:^, _, _}, sites ->
          {nil, sites}

        {name, _, ctx} = node, sites when is_atom(name) and is_atom(ctx) ->
          {node, Map.update(sites, name, 1, &(&1 + 1))}

        node, sites ->
          {node, sites}
      end)

    sites
  end

  defp closure({:fn, meta, clauses}), do: {meta[:line], :fn, {:ast, clauses}}

  defp closure({:&, meta, [{:/, _, [{{:., _, [module, name]}, _, []}, arity]}]})
       when is_atom(name) and is_integer(arity),
       do: {meta[:line], :remote_capture, {:remote, module, name, arity}}

  defp closure({:&, meta, [{:/, _, [{name, _, ctx}, arity]}]})
       when is_atom(name) and is_atom(ctx) and is_integer(arity),
       do: {meta[:line], :local_capture, {:local, name, arity}}

  defp closure({:&, meta, [{{:., _, [module, name]}, _, args}]})
       when is_atom(name) and is_list(args),
       do:
         {meta[:line], :remote_capture,
          {:roots, [{:remote, module, name, length(args)}, {:ast, args}]}}

  defp closure({:&, meta, [{name, _, args} = body]}) when is_atom(name) and is_list(args),
    do: {meta[:line], :local_call_capture, {:ast, body}}

  defp closure({:&, meta, [body]}), do: {meta[:line], :capture, {:ast, body}}

  defp closure({{:., _, [module, name]}, meta, args}) when is_atom(name) and is_list(args),
    do: {meta[:line], :call, {:remote, module, name, length(args)}}

  defp closure({name, meta, args}) when is_atom(name) and is_list(args),
    do: {meta[:line], :call, {:local, name, length(args)}}

  defp closure(_other), do: nil

  # Walks `pending` (`{module, root, depth}`) and answers what it refused:
  # a forbidden call or an unresolved capture, as text with its line.
  # `depth` counts the qualified calls into another module the walk has
  # followed to reach `root`; it follows one (`calls/4`). `seen` holds the
  # least depth each definition was walked at, since a definition walked
  # deeper followed less.
  defp walk([], _index, _seen, refused), do: refused

  defp walk([{module, root, depth} | pending], index, seen, refused) do
    case root do
      {:remote, target, name, arity} ->
        target = resolve(target, index[module])

        cond do
          forbidden?(target, name) ->
            walk(pending, index, seen, ["calls #{label(target)}.#{name}/#{arity}" | refused])

          Map.has_key?(index, target) ->
            walk([{target, {:local, name, arity}, depth} | pending], index, seen, refused)

          true ->
            unresolved =
              "captures #{label(target)}.#{name}/#{arity}, which the tree does not define"

            walk(pending, index, seen, [unresolved | refused])
        end

      {:roots, roots} ->
        walk(Enum.map(roots, &{module, &1, depth}) ++ pending, index, seen, refused)

      {:across, target, name, arity} ->
        walk([{target, {:local, name, arity}, depth + 1} | pending], index, seen, refused)

      {:local, name, arity} ->
        cond do
          Map.get(seen, {module, name, arity}, depth + 1) <= depth ->
            walk(pending, index, seen, refused)

          bodies = Map.get(index[module].defs, {name, arity}) ->
            more = Enum.map(bodies, &{module, {:ast, &1}, depth})
            walk(more ++ pending, index, Map.put(seen, {module, name, arity}, depth), refused)

          target = imported(index[module], name, arity) ->
            walk(pending, index, seen, [
              "calls #{label(target)}.#{name}/#{arity} (imported into #{module})" | refused
            ])

          true ->
            walk(pending, index, seen, [
              "captures #{name}/#{arity}, which #{module} does not define" | refused
            ])
        end

      {:ast, ast} ->
        {more, found} = calls(ast, index[module], index, depth)
        walk(Enum.map(more, &{module, &1, depth}) ++ pending, index, seen, found ++ refused)
    end
  end

  # The definitions `ast` calls or captures that the walk follows, and the
  # forbidden calls it makes. A node a clause below handles is still walked
  # into, so a piped or captured call is also seen as written: the same
  # refusal twice is one, and a lookup at the written arity finds nothing
  # or what the walk has already seen. At `depth` 0 a qualified call into
  # another module of the same application is followed too.
  defp calls(ast, module, index, depth) do
    {_ast, acc} =
      Macro.prewalk(ast, {[], []}, fn
        # A piped call takes one argument more than it is written with.
        {:|>, _, [_lhs, {{:., _, [target, name]}, meta, args}]} = node, acc
        when is_atom(name) and is_list(args) ->
          {node, qualified(acc, {target, name, length(args) + 1, meta}, module, index, depth)}

        {:|>, _, [_lhs, {name, meta, args}]} = node, acc when is_atom(name) and is_list(args) ->
          {node, unqualified(acc, name, length(args) + 1, meta, module)}

        # A capture of a function another module of the tree defines, whole
        # or partial, is a closure too; one outside the tree is not followed.
        {:&, _, [{:/, _, [{{:., _, [target, name]}, _, []}, arity]}]} = node, acc
        when is_atom(name) and is_integer(arity) ->
          {node, captured(acc, target, name, arity, module, index)}

        {:&, _, [{{:., _, [target, name]}, _, args}]} = node, acc
        when is_atom(name) and is_list(args) ->
          {node, captured(acc, target, name, length(args), module, index)}

        {:&, _, [{:/, _, [{name, meta, ctx}, arity]}]} = node, acc
        when is_atom(name) and is_atom(ctx) and is_integer(arity) ->
          {node, unqualified(acc, name, arity, meta, module)}

        {{:., _, [target, name]}, meta, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, qualified(acc, {target, name, length(args), meta}, module, index, depth)}

        {name, meta, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, unqualified(acc, name, length(args), meta, module)}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # `Mod.name(...)`: refused, or followed when `Mod` is the module itself,
  # by its name, an alias of it or `__MODULE__`, or, at `depth` 0, another
  # module of the same application that defines it.
  defp qualified({more, found}, {target, name, arity, meta}, module, index, depth) do
    target = resolve(target, module)

    cond do
      forbidden?(target, name) ->
        {more, ["calls #{label(target)}.#{name} (#{module.name}, line #{meta[:line]})" | found]}

      target == module.name and Map.has_key?(module.defs, {name, arity}) ->
        {[{:local, name, arity} | more], found}

      depth == 0 and defined?(target, name, arity, index) and index[target].app == module.app ->
        {[{:across, target, name, arity} | more], found}

      true ->
        {more, found}
    end
  end

  # `name(...)` or `&name/n`: followed when the module defines it, refused
  # when a refused module's import supplies it. Any other, `is_binary/1`
  # for one, is Kernel's or an import's that refuses nothing.
  defp unqualified({more, found}, name, arity, meta, module) do
    cond do
      Map.has_key?(module.defs, {name, arity}) ->
        {[{:local, name, arity} | more], found}

      target = imported(module, name, arity) ->
        refusal =
          "calls #{label(target)}.#{name} (imported into #{module.name}, line #{meta[:line]})"

        {more, [refusal | found]}

      true ->
        {more, found}
    end
  end

  defp captured({more, found}, target, name, arity, module, index) do
    if defined?(resolve(target, module), name, arity, index),
      do: {[{:remote, target, name, arity} | more], found},
      else: {more, found}
  end

  defp label(atom) when is_atom(atom), do: inspect(atom)
  defp label(name), do: name

  defp forbidden?(module, _name) when module in @refused_erlang, do: true

  defp forbidden?(module, name) when is_binary(module) do
    Enum.any?(@refused_modules, &(module == &1 or String.starts_with?(module, &1 <> "."))) or
      (module == "Cyfr.Bus" and String.starts_with?(Atom.to_string(name), "broadcast"))
  end

  defp forbidden?(_module, _name), do: false

  describe "the tree" do
    test "no transaction closure makes a network call or publishes" do
      %{read: read, bound: bound, forms: forms, refused: refused} = scan(tree())

      # The tree passes 53 closures or more, 10 or more of them bound to a
      # variable before they are passed. A count alone could be met with a
      # whole form unread, so each form is asserted read too, and the bound
      # ones are counted apart.
      assert read >= 53, "the scan read #{read} closures — it is not reading the tree"
      assert bound >= 10, "the scan read #{bound} bound closures — it is not reading bindings"

      for form <- @forms,
          do:
            assert(forms[form], "the scan read no closure of the form #{form}: #{inspect(forms)}")

      assert refused == [], """
      These transaction closures make a network call, publish, or capture a
      function the scan cannot find (`ARCHITECTURE.md` §4.4):

      #{Enum.map_join(refused, "\n", fn {path, line, key, what} -> "  #{path}:#{line} #{key}: #{what}" end)}

      A closure runs inside Arca's transaction with its locks held: make the
      call before the transaction opens, or broadcast after it commits.
      """
    end
  end

  describe "every closure an Arca function takes" do
    test "is verify:, also: or reserve:, or applied with no transaction open" do
      derived = arca_closure_options(arca_tree())

      # The derivation reads code before its answer is believed: each of
      # the three is taken somewhere, and a reader that found none of them
      # would pass by finding nothing.
      for key <- @keys,
          do:
            assert(
              Enum.any?(derived, &match?({_, _, ^key}, &1)),
              "no Arca function takes #{key}:"
            )

      named =
        for {module, function, key} <- derived,
            key not in @keys,
            uniq: true,
            do: {module, function, key}

      assert Enum.sort(named) == Enum.sort(Map.keys(@not_in_transaction)), """
      Arca functions take closures under names the transaction scan does not
      read, or `@not_in_transaction` names one Arca does not take:

      #{Enum.map_join(Enum.sort(named -- Map.keys(@not_in_transaction)), "\n", &"  taken: #{inspect(&1)}")}
      #{Enum.map_join(Enum.sort(Map.keys(@not_in_transaction) -- named), "\n", &"  stale: #{inspect(&1)}")}

      A closure an Arca transaction runs is verify:, also: or reserve:
      (`ARCHITECTURE.md` §4.4).
      """
    end

    test "is found under any name, however the function reaches it" do
      source = """
      defmodule Arca.Planted do
        def mint(actor, opts) do
          guards = Keyword.get(opts, :guards, [])
          attrs = Keyword.fetch!(opts, :attrs)
          seats = Keyword.get(opts, :seats, fn _row -> :ok end)
          hold = Keyword.get(opts, :hold, [])
          Arca.Repo.transaction(fn -> held(hold) && run(guards) && attrs.() && seats.(actor) end)
        end

        def seat(opts), do: reserve!(opts).()

        defp reserve!(opts) do
          case Keyword.get(opts, :reserve) do
            reserve when is_function(reserve, 0) -> reserve
          end
        end

        defp run(guards), do: Enum.reduce_while(guards, :ok, fn guard, :ok -> {:cont, guard.()} end)
        defp held(ids), do: ids |> Enum.sort() |> Enum.each(&IO.inspect/1)
      end
      """

      assert Enum.sort(arca_closure_options([{"planted.ex", source}])) == [
               {"Arca.Planted", :mint, :attrs},
               {"Arca.Planted", :mint, :guards},
               {"Arca.Planted", :mint, :seats},
               {"Arca.Planted", :reserve!, :reserve}
             ]
    end
  end

  # ---- the closures Arca takes -----------------------------------------------

  defp arca_tree do
    for path <- SourceTree.files!(Path.join(root(), "apps/arca/lib/**/*.ex")),
        do: {Path.relative_to(path, root()), SourceTree.read(path)}
  end

  # `{module, function, key}` for each option a function of `sources` reads
  # out of a keyword list and treats as a function.
  defp arca_closure_options(sources) do
    for {path, source} <- sources,
        {module, defs} <- option_modules(path, source),
        {{name, _arity}, clauses} <- defs,
        {_params, body} <- clauses,
        {key, evidence} <- option_reads(body),
        closure_evidence?(evidence, body, defs),
        uniq: true,
        do: {module, name, key}
  end

  defp option_modules(path, source) do
    {_ast, found} =
      source
      |> Code.string_to_quoted!(file: path)
      |> Macro.prewalk([], fn
        {:defmodule, _meta, [{:__aliases__, _, parts}, [do: body]]} = node, acc ->
          {node, [{Enum.map_join(parts, ".", &Atom.to_string/1), option_defs(body)} | acc]}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp option_defs(body) do
    {_ast, defs} =
      Macro.prewalk(body, %{}, fn
        {:defmodule, _meta, _args}, acc ->
          {:skip, acc}

        {kind, _meta, [head, [do: fbody]]} = node, acc when kind in [:def, :defp] ->
          {name, params} = option_head(head)

          {node,
           Map.update(acc, {name, length(params)}, [{params, fbody}], &(&1 ++ [{params, fbody}]))}

        node, acc ->
          {node, acc}
      end)

    defs
  end

  defp option_head({:when, _meta, [head | _guards]}), do: option_head(head)
  defp option_head({name, _meta, params}) when is_atom(name), do: {name, List.wrap(params)}

  # Every read of an option in `body`: the variables it is bound to (a match
  # or a `case` on it) and the arguments after the key (a default), or a
  # read applied where it is made.
  defp option_reads(body) do
    {_ast, reads} =
      Macro.prewalk(body, [], fn
        {:=, _meta, [lhs, rhs]} = node, acc ->
          {node, with_read(acc, rhs, &{&1, {:bound, pattern_names(lhs), &2}})}

        {:case, _meta, [subject, [do: clauses]]} = node, acc ->
          names =
            Enum.flat_map(clauses, fn {:->, _, [[pattern], _]} -> pattern_names(pattern) end)

          {node, with_read(acc, subject, &{&1, {:bound, names, &2}})}

        {{:., _meta, [applied]}, _, _args} = node, acc ->
          {node, with_read(acc, applied, fn key, _rest -> {key, :applied} end)}

        node, acc ->
          {node, with_read(acc, node, &{&1, {:bound, [], &2}})}
      end)

    reads
  end

  defp with_read(acc, node, entry) do
    case option_read(node) do
      {key, rest} -> [entry.(key, rest) | acc]
      nil -> acc
    end
  end

  # A lazy default is a default's thunk, never the option.
  defp option_read({{:., _, [{:__aliases__, _, [:Keyword]}, :get_lazy]}, _, [_, key | _]})
       when is_atom(key),
       do: {key, []}

  defp option_read({{:., _, [{:__aliases__, _, [:Keyword]}, reader]}, _, [_, key | rest]})
       when reader in [:get, :fetch!, :fetch, :pop] and is_atom(key),
       do: {key, rest}

  defp option_read({{:., _, [Access, :get]}, _, [_, key]}) when is_atom(key), do: {key, []}
  defp option_read(_node), do: nil

  defp pattern_names(pattern) do
    {_ast, names} =
      Macro.prewalk(pattern, [], fn
        {name, _meta, ctx} = node, acc when is_atom(name) and is_atom(ctx) ->
          if String.starts_with?(Atom.to_string(name), "_"),
            do: {node, acc},
            else: {node, [name | acc]}

        node, acc ->
          {node, acc}
      end)

    names
  end

  defp closure_evidence?(:applied, _body, _defs), do: true

  defp closure_evidence?({:bound, names, rest}, body, defs),
    do:
      Enum.any?(rest, &function_form?/1) or
        Enum.any?(names, &applied?(&1, body, defs, MapSet.new()))

  defp function_form?({:fn, _, _}), do: true
  defp function_form?({:&, _, _}), do: true
  defp function_form?(_other), do: false

  # The `Enum` and `Stream` functions whose last argument is the function
  # they apply.
  @applying ~w(all? any? count each filter find find_value flat_map group_by map map_reduce
               max_by min_by reduce reduce_while reject sort_by split_with take_while
               drop_while uniq_by)a

  # Whether `body` treats the variable `name` as a function: applies it,
  # checks it with `is_function`, hands it to `Enum` as the function,
  # iterates it applying each element, or passes it to a local function
  # whose parameter in that place is so treated.
  defp applied?(name, body, defs, seen) do
    {_ast, found} =
      Macro.prewalk(body, false, fn
        node, true ->
          {node, true}

        {{:., _, [{^name, _, ctx}]}, _, _} = node, _ when is_atom(ctx) ->
          {node, true}

        {:is_function, _, [{^name, _, ctx} | _]} = node, _ when is_atom(ctx) ->
          {node, true}

        {:|>, _, [lhs, {{:., _, [{:__aliases__, _, [m]}, f]}, _, args}]} = node, _
        when m in [:Enum, :Stream] and f in @applying ->
          {node, enum_applies?(name, lhs, args)}

        {{:., _, [{:__aliases__, _, [m]}, f]}, _, [first | args]} = node, _
        when m in [:Enum, :Stream] and f in @applying ->
          {node, enum_applies?(name, first, args)}

        {local, _, args} = node, _ when is_atom(local) and is_list(args) ->
          places = for {arg, place} <- Enum.with_index(args), variable?(arg, name), do: place
          {node, Enum.any?(places, &parameter_applied?({local, length(args)}, &1, defs, seen))}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp enum_applies?(name, enumerable, args) do
    (args != [] and variable?(List.last(args), name)) or
      (variable?(enumerable, name) and Enum.any?(args, &applies_element?/1))
  end

  defp applies_element?({:fn, _, [{:->, _, [[element | _], fbody]}]}),
    do: Enum.any?(pattern_names(element), &applied?(&1, fbody, %{}, MapSet.new()))

  defp applies_element?(_other), do: false

  defp parameter_applied?(function, place, defs, seen) do
    if MapSet.member?(seen, {function, place}) or not Map.has_key?(defs, function) do
      false
    else
      seen = MapSet.put(seen, {function, place})

      Enum.any?(defs[function], fn {params, body} ->
        params |> Enum.at(place) |> pattern_names() |> Enum.any?(&applied?(&1, body, defs, seen))
      end)
    end
  end

  defp variable?({name, _meta, ctx}, name) when is_atom(ctx), do: true
  defp variable?(_node, _name), do: false

  describe "a planted closure" do
    @refusals [
      {"Req.post!(url, json: body)", "calls Req.post!"},
      {"Finch.request(request, MyFinch)", "calls Finch.request"},
      {"Mint.HTTP.connect(:https, host, 443)", "calls Mint.HTTP.connect"},
      {":httpc.request(url)", "calls :httpc.request"},
      {"Sanctum.Egress.pinned_request(:get, url)", "calls Sanctum.Egress.pinned_request"},
      {"Phoenix.PubSub.broadcast(Cyfr.PubSub, topic, row)", "calls Phoenix.PubSub.broadcast"},
      {"Cyfr.Bus.broadcast(actor, topic, row)", "calls Cyfr.Bus.broadcast"},
      {"Sanctum.Notify.member_changed(athanor_id)", "calls Sanctum.Notify.member_changed"},
      {"Sanctum.Network.resolve_and_validate(url, [])",
       "calls Sanctum.Network.resolve_and_validate"},
      {":gen_tcp.connect(host, 443, [])", "calls :gen_tcp.connect"},
      {":ssl.connect(host, 443, [])", "calls :ssl.connect"},
      {":inet.getaddr(host, :inet)", "calls :inet.getaddr"},
      {"Task.start(fn -> row end)", "calls Task.start"},
      {"Task.Supervisor.start_child(Cyfr.TaskSupervisor, fn -> row end)",
       "calls Task.Supervisor.start_child"},
      {"Enum.each([row], &Req.get!/1)", "calls Req.get!"}
    ]

    for {call, refusal} <- @refusals do
      test "that calls #{call} is refused" do
        source = """
        defmodule Planted do
          def write(actor, row) do
            Arca.Users.mint(actor, row, also: fn row -> #{unquote(call)} end)
          end
        end
        """

        assert [{"planted.ex", 3, :also, what}] = scan([{"planted.ex", source}]).refused
        assert what =~ unquote(refusal)
      end
    end

    test "is refused through an alias, a local capture and the local calls it makes, piped or defaulted" do
      source = """
      defmodule Planted do
        alias Cyfr.Bus, as: Events
        alias Sanctum.{Egress, Notify}

        def write(actor, row) do
          Arca.Users.mint(actor, row, verify: &check/1)
          Arca.Members.seat(actor, row, reserve: &reserve(actor, &1))
          Arca.Users.link_identity(actor, row, also: fn row -> announce(row) end)
        end

        defp check(row), do: Egress.pinned_request(:get, row.url)
        defp reserve(actor, row), do: Notify.broadcast(actor.athanor_id, :seat, row)
        defp announce(row), do: row |> tell()
        defp tell(row, topic \\\\ "rows"), do: Events.broadcast_global(topic, row)
      end
      """

      assert [
               {"planted.ex", 6, :verify,
                "calls Sanctum.Egress.pinned_request (Planted, line 11)"},
               {"planted.ex", 7, :reserve, "calls Sanctum.Notify.broadcast (Planted, line 12)"},
               {"planted.ex", 8, :also, "calls Cyfr.Bus.broadcast_global (Planted, line 14)"}
             ] = scan([{"planted.ex", source}]).refused
    end

    test "is refused through a capture of another module's function" do
      planted = """
      defmodule Planted do
        def write(actor, row), do: Arca.Users.mint(actor, row, verify: &Planted.Policy.check/1)
      end
      """

      policy = """
      defmodule Planted.Policy do
        def check(row), do: publish(row)
        defp publish(row), do: Phoenix.PubSub.broadcast(Cyfr.PubSub, "rows", row)
      end
      """

      assert [
               {"planted.ex", 2, :verify,
                "calls Phoenix.PubSub.broadcast (Planted.Policy, line 3)"}
             ] =
               scan([{"planted.ex", planted}, {"policy.ex", policy}]).refused
    end

    test "returned by a call is read through the function it calls" do
      planted = """
      defmodule Planted do
        def write(actor, row) do
          Arca.Users.mint(actor, row, also: record(row))
          Arca.Users.mint(actor, row, verify: Planted.Policy.check(row))
        end

        defp record(row), do: fn _user -> Task.start(fn -> row end) end
      end
      """

      policy = """
      defmodule Planted.Policy do
        def check(_row), do: &Planted.Policy.Wire.send/1
      end

      defmodule Planted.Policy.Wire do
        def send(row), do: :gen_tcp.send(row.socket, "row")
      end
      """

      assert %{
               read: 2,
               forms: %{call: 2},
               refused: [
                 {"planted.ex", 3, :also, "calls Task.start (Planted, line 7)"},
                 {"planted.ex", 4, :verify, "calls :gen_tcp.send (Planted.Policy.Wire, line 6)"}
               ]
             } = scan([{"planted.ex", planted}, {"policy.ex", policy}])
    end

    test "naming a refused call only in prose is not refused" do
      source = ~S"""
      defmodule Planted do
        @moduledoc "Never calls Req.get!/1 or Task.start/1 from a closure."

        def write(actor, row), do: Arca.Users.mint(actor, row, also: fn row -> record(row) end)

        @doc "Records the row; Phoenix.PubSub.broadcast/3 follows the commit."
        def record(row) do
          # Task.start(fn -> Req.get!(row.url) end) would outlive the lock.
          Arca.Receipts.put(row, "Req.get!(url) and Task.start/1 are only named here")
        end
      end
      """

      assert %{read: 1, refused: []} = scan([{"planted.ex", source}])
    end

    test "whose calls only resemble a refused one is not refused" do
      source = """
      defmodule Planted do
        alias Cyfr.Bus.Notify

        def write(actor, req) do
          Arca.Users.mint(actor, req, also: fn row -> record(actor, row, req) end)
        end

        defp record(actor, row, req) do
          Arca.FencedPublication.publish(actor, row, req)
          _topic = Cyfr.Bus.notify(actor)
          task(%Notify{kind: :row})
        end

        defp task(notify), do: {:ok, notify}
      end
      """

      assert %{read: 1, refused: []} = scan([{"planted.ex", source}])
    end

    test "is refused through a qualified call to its own module" do
      source = """
      defmodule Planted do
        def write(actor, row), do: Arca.Users.mint(actor, row, also: fn row -> __MODULE__.announce(row) end)
        def announce(row), do: row |> Planted.tell()
        def tell(row), do: Phoenix.PubSub.broadcast(Cyfr.PubSub, "rows", row)
      end
      """

      assert [{"planted.ex", 2, :also, "calls Phoenix.PubSub.broadcast (Planted, line 4)"}] =
               scan([{"planted.ex", source}]).refused
    end

    test "is refused through a call to its own module by an alias of it" do
      source = """
      defmodule Planted do
        alias __MODULE__, as: Me
        def write(actor, row), do: Arca.Users.mint(actor, row, also: fn row -> Me.announce(row) end)
        def announce(row), do: :ssl.connect(row.host, 443, [])
      end
      """

      assert [{"planted.ex", 3, :also, "calls :ssl.connect (Planted, line 4)"}] =
               scan([{"planted.ex", source}]).refused
    end

    test "is refused through a partial capture of another module's function" do
      planted = """
      defmodule Planted do
        def write(actor, row) do
          Arca.Users.mint(actor, row, verify: &Planted.Policy.check(&1, :strict))
          Arca.Users.mint(actor, row, also: fn row -> Enum.map([row], &Planted.Policy.note(&1, :row)) end)
        end
      end
      """

      policy = """
      defmodule Planted.Policy do
        def check(_row, _mode), do: Task.start(fn -> :ok end)
        def note(row, _kind), do: :inet.gethostname() && row
      end
      """

      assert %{
               forms: %{remote_capture: 1, fn: 1},
               refused: [
                 {"planted.ex", 3, :verify, "calls Task.start (Planted.Policy, line 2)"},
                 {"planted.ex", 4, :also, "calls :inet.gethostname (Planted.Policy, line 3)"}
               ]
             } = scan([{"planted.ex", planted}, {"policy.ex", policy}])
    end

    test "is refused through an alias written with options" do
      source = """
      defmodule Planted do
        alias Sanctum.Notify, warn: false
        alias Phoenix.PubSub, as: Bus, warn: false

        def write(actor, row) do
          Arca.Users.mint(actor, row, also: fn row -> Notify.member_changed(row.athanor_id) end)
          Arca.Users.mint(actor, row, verify: fn row -> Bus.broadcast(Cyfr.PubSub, "rows", row) end)
        end
      end
      """

      assert [
               {"planted.ex", 6, :also, "calls Sanctum.Notify.member_changed (Planted, line 6)"},
               {"planted.ex", 7, :verify, "calls Phoenix.PubSub.broadcast (Planted, line 7)"}
             ] = scan([{"planted.ex", source}]).refused
    end

    test "is refused through an imported refused function, and only that" do
      source = """
      defmodule Planted do
        import Task, only: [start: 1]
        import :gen_tcp, except: [send: 2]
        import Enum

        def write(actor, row) do
          Arca.Users.mint(actor, row, also: fn row -> start(fn -> row end) end)
          Arca.Users.mint(actor, row, verify: &connect(&1, 443, []))
          Arca.Users.mint(actor, row, reserve: fn -> map([row], & &1) && send(row, "row") end)
          Arca.Users.mint(actor, row, also: &start/1)
        end

        defp send(row, _data), do: row
      end
      """

      bare = """
      defmodule Bare do
        import Task

        def write(actor, row) do
          Arca.Users.mint(actor, row, also: fn row ->
            held = row
            case held do
              _held -> async(fn -> held end)
            end
          end)
        end
      end
      """

      assert [
               {"bare.ex", 5, :also, "calls Task.async (imported into Bare, line 8)"},
               {"planted.ex", 7, :also, "calls Task.start (imported into Planted, line 7)"},
               {"planted.ex", 8, :verify,
                "calls :gen_tcp.connect (imported into Planted, line 8)"},
               {"planted.ex", 10, :also, "calls Task.start/1 (imported into Planted)"}
             ] = scan([{"planted.ex", source}, {"bare.ex", bare}]).refused
    end

    test "whose capture names no definition is refused" do
      source = """
      defmodule Planted do
        def write(actor, row) do
          Arca.Users.mint(actor, row, also: &missing/1)
          Arca.Users.mint(actor, row, verify: &Planted.Gone.check/1)
        end
      end
      """

      assert [
               {"planted.ex", 3, :also, "captures missing/1, which Planted does not define"},
               {"planted.ex", 4, :verify,
                "captures Planted.Gone.check/1, which the tree does not define"}
             ] = scan([{"planted.ex", source}]).refused
    end

    test "bound to a variable once in its clause is read where it is passed" do
      # The consent commit's shape: one `verify` handed to either write.
      source = """
      defmodule Planted do
        def commit(ctx, attrs) do
          verify = fn -> verify_binding_liveness(ctx) end

          if attrs.profile_id do
            Arca.ConsentStorage.insert_revision(attrs, [], "head",
              verify: verify,
              reactivate: true
            )
          else
            Arca.ConsentStorage.mint_profile_with_revision(attrs, [], verify: verify)
          end
        end

        defp verify_binding_liveness(ctx), do: Cyfr.Bus.broadcast(ctx.actor, "rows", ctx)
      end
      """

      assert %{
               read: 2,
               bound: 2,
               forms: %{fn: 2},
               refused: [
                 {"planted.ex", 7, :verify, "calls Cyfr.Bus.broadcast (Planted, line 15)"},
                 {"planted.ex", 11, :verify, "calls Cyfr.Bus.broadcast (Planted, line 15)"}
               ]
             } = scan([{"planted.ex", source}])
    end

    test "bound to a variable is refused through a qualified call into its own app" do
      # The recovery enrollment's shape: `also` calls another module of
      # the same application, which publishes.
      recovery = """
      defmodule Planted.Recovery do
        alias Planted.Authz

        def enroll(ctx, attrs, change) do
          also = fn _attempt -> Authz.consume(ctx, {:recovery_material, change}) end

          case Arca.IdentityAttempts.open(ctx.actor, attrs, also: also) do
            {:ok, attempt} -> attempt
            error -> error
          end
        end
      end
      """

      authz = """
      defmodule Planted.Authz do
        def consume(ctx, claim), do: ctx |> spend(claim)
        defp spend(ctx, claim), do: Cyfr.Bus.broadcast_global("rows", {ctx, claim})
      end
      """

      assert %{
               read: 1,
               bound: 1,
               refused: [
                 {"apps/planted/lib/recovery.ex", 7, :also,
                  "calls Cyfr.Bus.broadcast_global (Planted.Authz, line 3)"}
               ]
             } =
               scan([
                 {"apps/planted/lib/recovery.ex", recovery},
                 {"apps/planted/lib/authz.ex", authz}
               ])
    end

    test "is followed one module deep into its own app, and no further" do
      planted = """
      defmodule Planted do
        def write(actor, row) do
          Arca.Users.mint(actor, row, also: fn row -> Planted.Policy.check(row) end)
          Arca.Users.mint(actor, row, verify: fn row -> Other.Policy.check(row) end)
        end
      end
      """

      policy = """
      defmodule Planted.Policy do
        def check(row), do: Planted.Wire.send(row) && Planted.Policy.note(row)
        def note(row), do: :inet.gethostname() && row
      end

      defmodule Planted.Wire do
        def send(row), do: :gen_tcp.send(row.socket, "row")
      end
      """

      other = """
      defmodule Other.Policy do
        def check(row), do: Req.get!(row.url)
      end
      """

      # `Planted.Wire.send/1` is two modules away, and `Other.Policy` is
      # another application's: both stay the reviewer's.
      assert [
               {"apps/planted/lib/planted.ex", 3, :also,
                "calls :inet.gethostname (Planted.Policy, line 3)"}
             ] =
               scan([
                 {"apps/planted/lib/planted.ex", planted},
                 {"apps/planted/lib/policy.ex", policy},
                 {"apps/other/lib/policy.ex", other}
               ]).refused
    end

    test "bound twice, through a pattern or as a parameter, is not read" do
      source = """
      defmodule Planted do
        def write(actor, row, also) do
          Arca.Users.mint(actor, row, also: also)

          verify = fn _row -> :ok end
          verify = if row.strict, do: fn _row -> Req.get!(row.url) end, else: verify
          Arca.Users.mint(actor, row, verify: verify)

          {:ok, reserve} = {:ok, fn -> Task.start(fn -> row end) end}
          Arca.Users.mint(actor, row, reserve: reserve)
        end
      end
      """

      assert %{read: 0, bound: 0, refused: []} = scan([{"planted.ex", source}])
    end

    test "that reads and writes through Arca alone passes" do
      source = """
      defmodule Planted do
        def write(actor, row) do
          Arca.Users.mint(actor, row, also: fn row -> record(actor, row) end, verify: &standing/1)
        end

        defp record(actor, row), do: Arca.Receipts.put(actor, row)
        defp standing(%{state: "active"}), do: :ok
        defp standing(_row), do: {:error, :not_active}
      end
      """

      assert %{read: 2, refused: []} = scan([{"planted.ex", source}])
    end
  end
end
