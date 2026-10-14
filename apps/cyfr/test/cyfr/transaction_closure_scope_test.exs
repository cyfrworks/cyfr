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
      the function it calls, whose whole body is read.

  From there it follows every call to a function defined in the same
  module, written plain or qualified (`f(x)`, `__MODULE__.f(x)`, `Mod.f(x)`
  in `Mod`), and every capture of a function the tree defines,
  transitively. It refuses a call to `Req`, `Finch`, `Mint`, `:httpc`,
  `:gen_tcp`, `:ssl`, `:inet`, `Sanctum.Egress`, `Sanctum.Network`,
  `Phoenix.PubSub`, `Sanctum.Notify` or `Task`, or to a function `Cyfr.Bus`
  publishes with (`broadcast*`), written through an `alias` or plain
  through an `import`. A capture it cannot resolve is refused too, so a closure
  the scan cannot read never passes for one it read. A call the tree does
  not define (`args["verify"]` is `Access.get/2`) is no closure the scan
  can read, and is not counted.

  The scan reads code, not text: a comment, a documentation string or a
  string literal that names a refused call is no call.

  Its blind spots: a closure bound to a variable (`also: also`) is not
  followed, and neither is a call from a closure into another module's
  function. Those reach the transaction through code this scan does not
  read, so they stay the reviewer's.
  """

  use ExUnit.Case, async: true

  alias Prima.Test.SourceTree

  @keys [:verify, :also, :reserve]

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
          {key, line, form, root} <- closures(module.body),
          readable?(form, root, module, index),
          do: {module.path, line, key, form, module.name, root}

    refused =
      for {path, line, key, _form, name, root} <- read,
          what <- walk([{name, root}], index, MapSet.new(), []),
          do: {path, line, key, what}

    %{
      read: length(read),
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

  # Every module a source defines: its full name, its body without the
  # modules nested in it, its definitions, and the aliases and imports in
  # scope there, its enclosing modules' included.
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
          module = Map.merge(scope, %{path: path, body: own, defs: defs(own)})
          {nil, [module | defmodules(body, path, scope)] ++ acc}

        node, acc ->
          {node, acc}
      end)

    found
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

  # `alias A.B`, `alias A.B, as: C` and `alias A.{B, C}` in `body`, with
  # or without options such as `warn: false`, as short name to full name,
  # over the aliases of `scope`.
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
          short =
            case opts do
              [kw] when is_list(kw) ->
                case Keyword.get(kw, :as) do
                  {:__aliases__, _, [as]} -> as
                  _none -> List.last(parts)
                end

              [] ->
                List.last(parts)
            end

          {node, Map.put(acc, short, resolve(target, %{scope | aliases: acc}))}

        node, acc ->
          {node, acc}
      end)

    acc
  end

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
    module = if is_binary(target), do: Module.concat([target]), else: target

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
  # form, root}`. A variable, a literal or a type is none.
  defp closures(body) do
    {_ast, acc} =
      Macro.prewalk(body, [], fn
        {key, value} = node, acc when key in @keys ->
          case closure(value) do
            nil -> {node, acc}
            {line, form, root} -> {node, [{key, line, form, root} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    acc
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

  # Walks `pending` (`{module, root}`) and answers what it refused: a
  # forbidden call or an unresolved capture, as text with its line.
  defp walk([], _index, _seen, refused), do: refused

  defp walk([{module, root} | pending], index, seen, refused) do
    case root do
      {:remote, target, name, arity} ->
        target = resolve(target, index[module])

        cond do
          forbidden?(target, name) ->
            walk(pending, index, seen, ["calls #{label(target)}.#{name}/#{arity}" | refused])

          Map.has_key?(index, target) ->
            walk([{target, {:local, name, arity}} | pending], index, seen, refused)

          true ->
            unresolved =
              "captures #{label(target)}.#{name}/#{arity}, which the tree does not define"

            walk(pending, index, seen, [unresolved | refused])
        end

      {:roots, roots} ->
        walk(Enum.map(roots, &{module, &1}) ++ pending, index, seen, refused)

      {:local, name, arity} ->
        cond do
          MapSet.member?(seen, {module, name, arity}) ->
            walk(pending, index, seen, refused)

          bodies = Map.get(index[module].defs, {name, arity}) ->
            more = Enum.map(bodies, &{module, {:ast, &1}})
            walk(more ++ pending, index, MapSet.put(seen, {module, name, arity}), refused)

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
        {more, found} = calls(ast, index[module], index)
        walk(Enum.map(more, &{module, &1}) ++ pending, index, seen, found ++ refused)
    end
  end

  # The definitions `ast` calls or captures that the walk follows, and the
  # forbidden calls it makes. A node a clause below handles is still walked
  # into, so a piped or captured call is also seen as written: the same
  # refusal twice is one, and a lookup at the written arity finds nothing
  # or what the walk has already seen.
  defp calls(ast, module, index) do
    {_ast, acc} =
      Macro.prewalk(ast, {[], []}, fn
        # A piped call takes one argument more than it is written with.
        {:|>, _, [_lhs, {{:., _, [target, name]}, meta, args}]} = node, acc
        when is_atom(name) and is_list(args) ->
          {node, qualified(acc, target, name, length(args) + 1, meta, module)}

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
          {node, qualified(acc, target, name, length(args), meta, module)}

        {name, meta, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, unqualified(acc, name, length(args), meta, module)}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # `Mod.name(...)`: refused, or followed when `Mod` is the module itself,
  # by its name, an alias of it or `__MODULE__`.
  defp qualified({more, found}, target, name, arity, meta, module) do
    target = resolve(target, module)

    cond do
      forbidden?(target, name) ->
        {more, ["calls #{label(target)}.#{name} (#{module.name}, line #{meta[:line]})" | found]}

      target == module.name and Map.has_key?(module.defs, {name, arity}) ->
        {[{:local, name, arity} | more], found}

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
      %{read: read, forms: forms, refused: refused} = scan(tree())

      # 43 closures are read at the plan's base; the other sites bind their
      # closure to a variable. A count alone could be met with a whole form
      # unread, so each form is asserted read too.
      assert read >= 43, "the scan read #{read} closures — it is not reading the tree"

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
