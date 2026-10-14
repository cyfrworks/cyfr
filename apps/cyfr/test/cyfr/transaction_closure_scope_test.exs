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
    * a capture of another module's function, `&Mod.name/n`, resolved to
      that module's definitions in the tree.

  From there it follows every call to a function defined in the same
  module, transitively, and refuses a call to `Req`, `Finch`, `Mint`,
  `:httpc`, `Sanctum.Egress`, `Phoenix.PubSub`, `Sanctum.Notify` or `Task`,
  or to a function `Cyfr.Bus` publishes with (`broadcast*`). A capture it
  cannot resolve is refused too, so a closure the scan cannot read never
  passes for one it read.

  The scan reads code, not text: a comment or a documentation string that
  mentions a closure and the network names no call.

  Its blind spots: a closure bound to a variable (`also: also`) or built by
  a call (`verify: verify(expectation)`) is not followed, and neither is a
  call from a closure into another module's function. Those reach the
  transaction through code this scan does not read, so they stay the
  reviewer's.
  """

  use ExUnit.Case, async: true

  alias Prima.Test.SourceTree

  @keys [:verify, :also, :reserve]

  # The modules a closure may not call, each with its submodules.
  @refused_modules ~w(Req Finch Mint Sanctum.Egress Phoenix.PubSub Sanctum.Notify Task)

  defp root, do: Path.expand("../../../..", __DIR__)

  defp tree do
    for lib <- SourceTree.app_libs(root()),
        path <- SourceTree.files!(Path.join([root(), lib, "**/*.ex"])),
        do: {Path.relative_to(path, root()), SourceTree.read(path)}
  end

  # Scans `sources` (`[{path, source}]`) as one tree: a remote capture
  # resolves to a module defined anywhere in it. Answers the closures it
  # read and what it refused in them.
  defp scan(sources) do
    modules = Enum.flat_map(sources, fn {path, source} -> modules(path, source) end)
    index = Map.new(modules, &{&1.name, &1})

    read =
      for module <- modules,
          {key, line, root} <- closures(module.body),
          do: {module.path, line, key, module.name, root}

    refused =
      for {path, line, key, name, root} <- read,
          what <- walk([{name, root}], index, MapSet.new(), []),
          do: {path, line, key, what}

    %{read: length(read), refused: refused |> Enum.uniq() |> Enum.sort()}
  end

  # Every module a source defines: its full name, its body without the
  # modules nested in it, its definitions, and the aliases in scope there,
  # its enclosing modules' included.
  defp modules(path, source) do
    source
    |> Code.string_to_quoted!(columns: true, file: path)
    |> defmodules(path, %{name: nil, aliases: %{}})
  end

  defp defmodules(ast, path, outer) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [{:__aliases__, _, parts}, [do: body]]}, acc ->
          name = name(parts, outer)
          own = strip_modules(body)
          scope = %{name: name, aliases: aliases(own, %{name: name, aliases: outer.aliases})}
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

  # `alias A.B`, `alias A.B, as: C` and `alias A.{B, C}` in `body`, as
  # short name to full name, over the aliases of `scope`.
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

        {:alias, _, [target, [as: {:__aliases__, _, [as]}]]} = node, acc ->
          {node, Map.put(acc, as, resolve(target, %{scope | aliases: acc}))}

        {:alias, _, [{:__aliases__, _, parts} = target]} = node, acc ->
          {node, Map.put(acc, List.last(parts), resolve(target, %{scope | aliases: acc}))}

        node, acc ->
          {node, acc}
      end)

    acc
  end

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

  # Each `key: closure` in `body` the scan can read, as `{key, line, root}`.
  # A value that is no closure, or one bound elsewhere, is not one.
  defp closures(body) do
    {_ast, acc} =
      Macro.prewalk(body, [], fn
        {key, value} = node, acc when key in @keys ->
          case closure(value) do
            nil -> {node, acc}
            {line, root} -> {node, [{key, line, root} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp closure({:fn, meta, clauses}), do: {meta[:line], {:ast, clauses}}

  defp closure({:&, meta, [{:/, _, [{{:., _, [module, name]}, _, []}, arity]}]})
       when is_atom(name) and is_integer(arity),
       do: {meta[:line], {:remote, module, name, arity}}

  defp closure({:&, meta, [{:/, _, [{name, _, ctx}, arity]}]})
       when is_atom(name) and is_atom(ctx) and is_integer(arity),
       do: {meta[:line], {:local, name, arity}}

  defp closure({:&, meta, [body]}), do: {meta[:line], {:ast, body}}
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

      {:local, name, arity} ->
        cond do
          MapSet.member?(seen, {module, name, arity}) ->
            walk(pending, index, seen, refused)

          bodies = Map.get(index[module].defs, {name, arity}) ->
            more = Enum.map(bodies, &{module, {:ast, &1}})
            walk(more ++ pending, index, MapSet.put(seen, {module, name, arity}), refused)

          true ->
            walk(pending, index, seen, [
              "captures #{name}/#{arity}, which #{module} does not define" | refused
            ])
        end

      {:ast, ast} ->
        {more, found} = calls(ast, index[module])
        walk(Enum.map(more, &{module, &1}) ++ pending, index, seen, found ++ refused)
    end
  end

  # The local definitions `ast` calls or captures, and the forbidden calls
  # it makes.
  defp calls(ast, module) do
    {_ast, acc} =
      Macro.prewalk(ast, {[], []}, fn
        {{:., _, [target, name]}, meta, _args} = node, {more, found} when is_atom(name) ->
          target = resolve(target, module)

          if forbidden?(target, name),
            do:
              {node,
               {more,
                ["calls #{label(target)}.#{name} (#{module.name}, line #{meta[:line]})" | found]}},
            else: {node, {more, found}}

        # A piped call takes one argument more than it is written with.
        {:|>, _, [_lhs, {name, _, args}]} = node, {more, found}
        when is_atom(name) and is_list(args) ->
          if Map.has_key?(module.defs, {name, length(args) + 1}),
            do: {node, {[{:local, name, length(args) + 1} | more], found}},
            else: {node, {more, found}}

        # A capture of an imported function (`&is_binary/1`) is no local one.
        {:&, _, [{:/, _, [{name, _, ctx}, arity]}]} = node, {more, found}
        when is_atom(name) and is_atom(ctx) and is_integer(arity) ->
          if Map.has_key?(module.defs, {name, arity}),
            do: {node, {[{:local, name, arity} | more], found}},
            else: {node, {more, found}}

        {name, _, args} = node, {more, found} when is_atom(name) and is_list(args) ->
          if Map.has_key?(module.defs, {name, length(args)}),
            do: {node, {[{:local, name, length(args)} | more], found}},
            else: {node, {more, found}}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp label(atom) when is_atom(atom), do: inspect(atom)
  defp label(name), do: name

  defp forbidden?(:httpc, _name), do: true

  defp forbidden?(module, name) when is_binary(module) do
    Enum.any?(@refused_modules, &(module == &1 or String.starts_with?(module, &1 <> "."))) or
      (module == "Cyfr.Bus" and String.starts_with?(Atom.to_string(name), "broadcast"))
  end

  defp forbidden?(_module, _name), do: false

  describe "the tree" do
    test "no transaction closure makes a network call or publishes" do
      %{read: read, refused: refused} = scan(tree())

      # 36 closures are read at the plan's base; the rest of the sites bind
      # their closure to a variable or build it by a call.
      assert read > 30, "the scan read #{read} closures — it is not reading the tree"

      assert refused == [], """
      These transaction closures make a network call, publish, or capture a
      function the scan cannot find (`ARCHITECTURE.md` §4.4):

      #{Enum.map_join(refused, "\n", fn {path, line, key, what} -> "  #{path}:#{line} #{key}: #{what}" end)}

      A closure runs inside Arca's transaction with its locks held: make the
      call before the transaction opens, or broadcast after it commits.
      """
    end

    test "a comment or a documentation string that mentions a closure and the network is not a closure" do
      sources = Map.new(tree())

      # Each line a text search for closures and the network finds.
      for {path, text} <- [
            {"apps/cyfr/lib/compendium/provisioning.ex",
             "published it, is what makes an interrupted closure heal on the next"},
            {"apps/sanctum/lib/sanctum/provisioning.ex",
             "closure over the network, and no request path may hold a page open for"}
          ] do
        assert sources[path] =~ text, "#{path} no longer says #{inspect(text)}"
        assert scan([{path, sources[path]}]).refused == []
      end
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
      {"Task.start(fn -> row end)", "calls Task.start"}
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
