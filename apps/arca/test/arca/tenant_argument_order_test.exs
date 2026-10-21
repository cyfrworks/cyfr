# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.TenantArgumentOrderTest do
  @moduledoc """
  Where the tenant comes from in a storage function, and what an
  unresolved one does.

  A bare `athanor_id` and the row key beside it are both non-empty
  strings. Nothing in the type system, in dialyzer, or in
  `where_athanor/2`'s guard can tell them apart — so a call that swaps
  them is not an error, it is a query against another athanor that
  returns that athanor's rows, or none, and looks like an ordinary miss
  either way. Two functions of one module could take
  `(String.t(), String.t())` with the tenant first in one and second in
  the other, and nothing would say so.

  So the tenant is not an argument at all. Every tenant-scoped
  facade matches a `%Prima.Actor{}` in its head and reads the athanor out
  of it, so the athanor comes from the caller the identity domain
  established and no argument a caller passes can move a read or a write
  to another tenant's rows. A `%Sanctum.Context{}` or a bare id matches
  no head and raises.

  ## The empty string is refused, not matched

  A head that binds the athanor out of the actor guards
  `is_binary(athanor_id) and athanor_id != ""`. Both halves are load
  bearing. `""` is an identity that was never resolved — the same thing
  `Arca.QueryHelpers.where_tenant/2` raises on — and a guard of
  `is_binary/1` alone would admit it, filter on `athanor_id == ""`, match
  nothing and answer an ordinary empty result. That turns a refusal into
  silence, which is exactly what the tenancy rules forbid.
  `Arca.VaultStorage` spells the same pair as its own `resolved/1` guard,
  which this reads as the guard it is.

  ## The tenant is never an option

  A head can take the actor first and still not be where the tenant comes
  from: a function that reads `:athanor_id`, `:actor` or `:tenant` out of
  its options scopes to whatever the caller wrote there, and a function
  with no actor at all, such as `list(opts)` reading
  `Keyword.fetch!(opts, :athanor_id)`, is the bare-id hole again, one
  keyword further away. So a public storage function without an
  actor-first head may not read the tenant from an options argument, in
  its own body or in a private function of its module it calls. An options
  argument is a keyword list: read through `Keyword`, defaulted to a list,
  guarded `is_list/1`, or matched as one; a map an options head
  pattern-matches the tenant out of counts too. A map of row attributes a
  write stores is not an option: its tenant is a column the row carries and
  its changeset requires, which is payload, not scope.

  The functions that still read the tenant from their options are rostered
  below, each with why, and the roster only shrinks.

  The scan reads calls as written, pipes and private defaults included. A
  read hidden behind a function value (`then(opts, &Keyword.fetch!(&1,
  :athanor_id))`, `apply/3`, a captured reader passed along) escapes it:
  a named blind spot, not an admission.
  """

  use ExUnit.Case, async: true

  @storage_globs ["apps/arca/lib/arca.ex", "apps/arca/lib/arca/**/*.ex"]

  # The rule is about functions the tenant SCOPES. These are the shapes
  # where the athanor is something else:
  #
  #   * `where_athanor/2`, `where_tenant/2`,
  #     `where_tenant_unless_platform/2` and `stamp_tenant!/2` compose onto
  #     a query or a map — the subject is what is piped, and the tenant
  #     narrows or stamps it.
  #   * `update_athanor/2` writes the athanor as a VALUE onto a session
  #     found by its token hash. Swapping those looks up a session whose
  #     hash equals an athanor id, finds none, and says so; it cannot reach
  #     another tenant's row, and the two are different types besides.
  @exempt %{
    "query_helpers.ex" =>
      ~w(where_athanor where_tenant where_tenant_unless_platform stamp_tenant!),
    "session_storage.ex" => ~w(update_athanor)
  }

  # The public functions that still read the tenant from their options, by
  # `Module.function/arity`, each with why it may. The seam below fails on
  # one that is not here and on a row nothing matches any longer.
  # Each retention primitive below requires the athanor (`Keyword.fetch!/2`),
  # and its actor-first head moves with the retention path that calls it.
  @from_prune "a retention primitive called only by its kind's actor-first `prune/3` " <>
                "(`Arca.Retention.*`), which passes the athanor the actor's head bound"

  @through_execution_rows "a retention primitive called only by " <>
                            "`Arca.Retention.ExecutionRows.delete/3`, which takes the actor " <>
                            "first and is reached from the execution kinds' actor-first " <>
                            "`prune/3` with the athanor the actor's head bound"

  @keyword_tenant_readers %{
    "Arca.DecisionLog.count_before/2" => @from_prune,
    "Arca.DecisionLog.delete_before/2" => @from_prune,
    "Arca.Execution.count_older_than_days/2" => @from_prune,
    "Arca.Execution.count_stale/2" => @from_prune,
    "Arca.Execution.delete_ids/2" => @through_execution_rows,
    "Arca.Execution.ids_older_than_days/2" => @from_prune,
    "Arca.Execution.stale_ids/2" => @from_prune,
    "Arca.ExecutionAttempts.count_intents_before/2" => @from_prune,
    "Arca.ExecutionAttempts.delete_intents_before/2" => @from_prune,
    "Arca.FrameCredentials.count_revoked_before/2" => @from_prune,
    "Arca.FrameCredentials.delete_revoked_before/2" => @from_prune,
    "Arca.McpLog.count_before/2" => @from_prune,
    "Arca.McpLog.delete_before/2" => @from_prune
  }

  @tenant_keys [:athanor_id, :actor, :tenant]

  defp root, do: Path.expand("../../../..", __DIR__)

  defp sources do
    Enum.flat_map(@storage_globs, fn glob ->
      root() |> Path.join(glob) |> Prima.Test.SourceTree.files!()
    end)
  end

  # Every public head of one source, as {name, whole head text, line}. A
  # head runs from `  def ` to the ` do` or `, do:` that ends it, so a
  # guard on a continuation line is part of it; a bodiless head that only
  # declares defaults ends at the blank line under it.
  defp heads(source) do
    lines = String.split(source, "\n")

    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _n} -> line =~ ~r/^  def [a-z_]+[!?]?\(/ end)
    |> Enum.map(fn {line, n} ->
      text =
        lines
        |> Enum.drop(n - 1)
        |> Enum.reduce_while([], fn l, acc ->
          cond do
            l =~ ~r/(\bdo\b\s*$|,\s*do:)/ -> {:halt, Enum.reverse([l | acc])}
            String.trim(l) == "" -> {:halt, Enum.reverse(acc)}
            true -> {:cont, [l | acc]}
          end
        end)
        |> Enum.join("\n")

      [_, name] = Regex.run(~r/^  def ([a-z_]+[!?]?)\(/, line)
      {name, text, n}
    end)
  end

  # The heads of one file that name a tenant and do not take the actor
  # first.
  defp offending(file, source) do
    exempt = Map.get(@exempt, file, [])

    for {name, text, n} <- heads(source),
        name not in exempt,
        text =~ ~r/athanor_id|%Sanctum\.Context\{|%Context\{/,
        not (text =~ ~r/^  def [a-z_]+[!?]?\(\s*%Prima\.Actor\{/),
        do: "#{file}:#{n}: #{text |> String.split("\n") |> hd() |> String.trim()}"
  end

  # The heads that bind the athanor out of the actor without refusing the
  # empty string in the same guard.
  defp unguarded(file, source) do
    exempt = Map.get(@exempt, file, [])

    for {name, text, n} <- heads(source),
        name not in exempt,
        text =~ ~r/%Prima\.Actor\{athanor_id: athanor_id\}/,
        not (text =~ ~r/athanor_id\s*!=\s*""/ or text =~ ~r/\bresolved\(athanor_id\)/),
        do: "#{file}:#{n}: #{text |> String.split("\n") |> hd() |> String.trim()}"
  end

  # The public functions of one source that read the tenant from an options
  # argument without an actor-first head, as `{label, line}`, where label is
  # `Module.function/arity`: directly, or through a private function of the
  # same module they call. A pipe is read as the call it is, so
  # `opts |> Keyword.fetch!(:athanor_id)` reads as
  # `Keyword.fetch!(opts, :athanor_id)`.
  defp keyword_tenant_readers(source) do
    source
    |> Code.string_to_quoted!()
    |> Macro.prewalk(&unpipe/1)
    |> modules()
    |> Enum.flat_map(fn {module, clauses} -> option_readers(module, clauses) end)
  end

  defp unpipe({:|>, _, [left, {call, meta, args}]}) when is_list(args),
    do: {call, meta, [left | args]}

  defp unpipe({:|>, _, [left, {call, meta, context}]}) when is_atom(call) and is_atom(context),
    do: {call, meta, [left]}

  defp unpipe(node), do: node

  defp modules(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [name, [do: body]]} = node, acc ->
          {node, [{Macro.to_string(name), clauses(body)} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp clauses({:__block__, _, body}), do: Enum.flat_map(body, &clause/1)
  defp clauses(body), do: clause(body)

  # A clause, or a bodiless head that declares defaults (`body: nil`).
  defp clause({kind, meta, [head | body]}) when kind in [:def, :defp] and length(body) <= 1 do
    {name, args, guard} = head_parts(head)

    [
      %{
        kind: kind,
        name: name,
        arity: length(args),
        args: args,
        guard: guard,
        body: List.first(body),
        line: meta[:line]
      }
    ]
  end

  defp clause(_other), do: []

  defp head_parts({:when, _, [head, guard]}) do
    {name, args, nil} = head_parts(head)
    {name, args, guard}
  end

  defp head_parts({name, _, args}) when is_atom(name) and is_list(args), do: {name, args, nil}
  defp head_parts({name, _, _context}) when is_atom(name), do: {name, [], nil}

  # A function with defaults is every arity it generates: a call to any of
  # them reaches its clauses. The defaults are declared on a clause or on a
  # bodiless head.
  defp option_readers(module, clauses) do
    defaults =
      Enum.reduce(clauses, %{}, fn c, acc ->
        count = Enum.count(c.args, &match?({:\\, _, _}, &1))
        Map.update(acc, {c.kind, c.name, c.arity}, count, &max(&1, count))
      end)

    arities = fn c -> (c.arity - Map.fetch!(defaults, {c.kind, c.name, c.arity}))..c.arity end
    clauses = Enum.reject(clauses, &is_nil(&1.body))

    by_function =
      for c <- clauses, arity <- arities.(c), reduce: %{} do
        acc -> Map.update(acc, {c.name, arity}, [c], &(&1 ++ [c]))
      end

    private =
      for %{kind: :defp} = c <- clauses,
          arity <- arities.(c),
          into: MapSet.new(),
          do: {c.name, arity}

    reads? = fn function ->
      by_function |> Map.get(function, []) |> Enum.any?(&reads_tenant?/1)
    end

    for %{kind: :def} = c <- clauses,
        not actor_first?(c.args),
        reads_tenant?(c) or
          c.body |> local_calls(private) |> reachable(by_function, private) |> Enum.any?(reads?) do
      {"#{module}.#{c.name}/#{c.arity}", c.line}
    end
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp actor_first?([first | _]), do: actor_pattern?(without_default(first))
  defp actor_first?([]), do: false

  defp actor_pattern?({:=, _, [left, right]}), do: actor_pattern?(left) or actor_pattern?(right)
  defp actor_pattern?({:%, _, [{:__aliases__, _, [:Prima, :Actor]}, _]}), do: true
  defp actor_pattern?(_), do: false

  defp without_default({:\\, _, [arg, _default]}), do: arg
  defp without_default(arg), do: arg

  # Whether one clause reads the tenant from one of its own options
  # arguments: a head that matches it out of a map or a keyword list, a
  # `Keyword` read, or an access or a match on an argument that is a list.
  defp reads_tenant?(clause) do
    options = options_arguments(clause)

    Enum.any?(clause.args, &head_names_tenant?/1) or
      walk_any?(clause.body, fn
        {{:., _, [{:__aliases__, _, [:Keyword]}, _]}, _, [{var, _, ctx}, key | _]}
        when is_atom(var) and is_atom(ctx) ->
          var in arguments(clause) and tenant_key?(key)

        {{:., _, [Access, :get]}, _, [{var, _, ctx}, key]} when is_atom(var) and is_atom(ctx) ->
          var in options and tenant_key?(key)

        {:=, _, [pattern, {var, _, ctx}]} when is_atom(var) and is_atom(ctx) ->
          var in options and names_tenant?(pattern)

        _node ->
          false
      end)
  end

  # The variables a clause's head binds that are lists: defaulted to one,
  # guarded `is_list/1`, or read through `Keyword`.
  defp options_arguments(clause) do
    defaulted =
      for {:\\, _, [{var, _, ctx}, default]} <- clause.args,
          is_atom(var) and is_atom(ctx) and is_list(default),
          do: var

    guarded =
      collect(clause.guard, fn
        {:is_list, _, [{var, _, ctx}]} when is_atom(var) and is_atom(ctx) -> [var]
        _node -> []
      end)

    keyword =
      collect(clause.body, fn
        {{:., _, [{:__aliases__, _, [:Keyword]}, _]}, _, [{var, _, ctx} | _]}
        when is_atom(var) and is_atom(ctx) ->
          [var]

        _node ->
          []
      end)

    Enum.filter(defaulted ++ guarded ++ keyword, &(&1 in arguments(clause)))
  end

  # The variables a clause's head binds, a struct-typed argument's aside:
  # a struct is a typed value, not an options argument.
  defp arguments(clause) do
    for arg <- clause.args,
        not struct_pattern?(without_default(arg)),
        var <-
          collect(arg, fn
            {var, _, ctx} when is_atom(var) and is_atom(ctx) -> [var]
            _node -> []
          end),
        do: var
  end

  defp struct_pattern?({:=, _, [left, right]}),
    do: struct_pattern?(left) or struct_pattern?(right)

  defp struct_pattern?({:%, _, _}), do: true
  defp struct_pattern?(_), do: false

  defp head_names_tenant?(arg) do
    arg = without_default(arg)
    not struct_pattern?(arg) and walk_any?(arg, &names_tenant?/1)
  end

  defp names_tenant?({:%{}, _, pairs}), do: Enum.any?(pairs, &tenant_pair?/1)
  defp names_tenant?(pairs) when is_list(pairs), do: Enum.any?(pairs, &tenant_pair?/1)
  defp names_tenant?(_node), do: false

  defp tenant_pair?({key, _value}), do: key in @tenant_keys
  defp tenant_pair?(_element), do: false

  defp tenant_key?(key) when is_atom(key), do: key in @tenant_keys
  defp tenant_key?(keys) when is_list(keys), do: Enum.any?(keys, &tenant_key?/1)
  defp tenant_key?(_key), do: false

  defp local_calls(ast, private) do
    collect(ast, fn
      {:&, _, [{:/, _, [{name, _, _}, arity]}]} when is_atom(name) and is_integer(arity) ->
        [{name, arity}]

      {name, _, args} when is_atom(name) and is_list(args) ->
        [{name, length(args)}]

      _node ->
        []
    end)
    |> Enum.filter(&MapSet.member?(private, &1))
    |> MapSet.new()
  end

  defp reachable(found, by_function, private) do
    next =
      Enum.reduce(found, found, fn function, acc ->
        by_function
        |> Map.get(function, [])
        |> Enum.reduce(acc, &MapSet.union(&2, local_calls(&1.body, private)))
      end)

    if next == found, do: found, else: reachable(next, by_function, private)
  end

  defp walk_any?(ast, fun), do: collect(ast, &if(fun.(&1), do: [true], else: [])) != []

  defp collect(ast, fun) do
    {_ast, acc} = Macro.prewalk(ast, [], fn node, acc -> {node, fun.(node) ++ acc} end)
    acc
  end

  test "every tenant-scoped storage function takes the actor first" do
    found =
      Enum.flat_map(sources(), fn path ->
        offending(Path.basename(path), Prima.Test.SourceTree.read(path))
      end)

    assert found == [],
           """
           These storage functions name a tenant but do not take a
           %Prima.Actor{} in the first position:

           #{Enum.map_join(found, "\n", &"  #{&1}")}

           A bare athanor_id and the row key beside it are both strings, so
           a swapped call compiles, passes dialyzer, satisfies
           where_athanor/2's guard and quietly reads another athanor's
           rows; a %Sanctum.Context{} names the identity domain from below
           it. Match the actor in the head and read the athanor out of it.
           """
  end

  test "a head that binds the athanor refuses the empty string in its guard" do
    found =
      Enum.flat_map(sources(), fn path ->
        unguarded(Path.basename(path), Prima.Test.SourceTree.read(path))
      end)

    assert found == [],
           """
           These heads bind the athanor out of the actor without refusing
           the empty string:

           #{Enum.map_join(found, "\n", &"  #{&1}")}

           "" is an identity that was never resolved. is_binary/1 alone
           admits it, filters on athanor_id == "", matches nothing and
           answers an ordinary empty result — a refusal turned into
           silence. Guard is_binary(athanor_id) and athanor_id != "".
           """
  end

  test "the detector sees a tenant that is not in the first position" do
    planted = """
    defmodule Arca.Planted do
      def by_actor(%Prima.Actor{athanor_id: athanor_id}, key)
          when is_binary(athanor_id) and athanor_id != "",
          do: {athanor_id, key}

      def by_context(%Context{athanor_id: athanor_id}, key), do: {athanor_id, key}
      def by_id(athanor_id, key), do: {athanor_id, key}
      def actor_second(key, %Prima.Actor{athanor_id: athanor_id}), do: {athanor_id, key}
      def id_second(key, athanor_id), do: {athanor_id, key}
      def actor_in_a_map(%{actor: %Prima.Actor{athanor_id: athanor_id}}), do: athanor_id
    end
    """

    assert offending("planted.ex", planted) == [
             "planted.ex:6: def by_context(%Context{athanor_id: athanor_id}, key), do: {athanor_id, key}",
             "planted.ex:7: def by_id(athanor_id, key), do: {athanor_id, key}",
             "planted.ex:8: def actor_second(key, %Prima.Actor{athanor_id: athanor_id}), do: {athanor_id, key}",
             "planted.ex:9: def id_second(key, athanor_id), do: {athanor_id, key}",
             "planted.ex:10: def actor_in_a_map(%{actor: %Prima.Actor{athanor_id: athanor_id}}), do: athanor_id"
           ]
  end

  test "the detector sees a head that admits the empty athanor" do
    planted = """
    defmodule Arca.Planted do
      def guarded(%Prima.Actor{athanor_id: athanor_id}, key)
          when is_binary(athanor_id) and athanor_id != "",
          do: {athanor_id, key}

      def loose(%Prima.Actor{athanor_id: athanor_id}, key) when is_binary(athanor_id),
        do: {athanor_id, key}
    end
    """

    assert unguarded("planted.ex", planted) == [
             "planted.ex:6: def loose(%Prima.Actor{athanor_id: athanor_id}, key) when is_binary(athanor_id),"
           ]
  end

  test "no storage function reads the tenant from its options without an actor first" do
    found =
      for path <- sources(),
          {label, line} <- keyword_tenant_readers(Prima.Test.SourceTree.read(path)),
          do: {label, "#{Path.relative_to(path, root())}:#{line}"}

    assert length(sources()) > 100, "the keyword-tenant scan read no storage source"

    unrostered =
      for {label, at} <- found,
          not Map.has_key?(@keyword_tenant_readers, label),
          do: "  #{at}: #{label}"

    assert unrostered == [],
           """
           These storage functions read the tenant from an options argument
           and take no actor first:

           #{Enum.join(unrostered, "\n")}

           An option is whatever the caller wrote: a list(opts) that reads
           Keyword.fetch!(opts, :athanor_id) reads another athanor's rows for
           a caller that names it. Take the %Prima.Actor{} first and read the
           athanor out of it.
           """

    stale =
      @keyword_tenant_readers
      |> Map.keys()
      |> Enum.reject(fn label -> Enum.any?(found, &(elem(&1, 0) == label)) end)

    assert stale == [],
           "these rostered readers do not read the tenant from their options; " <>
             "remove them: #{inspect(stale)}"

    for {label, reason} <- @keyword_tenant_readers do
      assert is_binary(reason) and String.length(reason) > 40, "#{label} carries no reason"
    end
  end

  test "the keyword-tenant detector sees the direct, piped and delegated read, and no payload" do
    planted = ~S"""
    defmodule Arca.Planted do
      def by_option(opts), do: Keyword.fetch!(opts, :athanor_id)

      def through_a_helper(opts), do: {:ok, scoped(opts)}

      def by_access(id, opts \\ []), do: {id, opts[:actor]}

      def from_a_map(%{tenant: tenant}), do: tenant

      def matched(opts) when is_list(opts) do
        [athanor_id: athanor_id] = opts
        athanor_id
      end

      def by_pipe(opts), do: opts |> Keyword.fetch!(:athanor_id)

      def through_a_default(opts), do: defaulted(opts)

      def through_a_bodiless_default(opts), do: opts |> headed()

      def piped_option(opts), do: opts |> Keyword.get(:limit) |> max(1)

      def actor_first(%Prima.Actor{athanor_id: athanor_id}, opts)
          when is_binary(athanor_id) and athanor_id != "",
          do: {athanor_id, Keyword.get(opts, :limit, 20)}

      def payload(attrs) when is_map(attrs), do: Map.fetch!(attrs, :athanor_id)

      def other_option(opts), do: Keyword.get(opts, :limit, 20)

      def struct_field(%Staged{} = staged), do: staged.actor

      defp scoped(opts) do
        limit = Keyword.get(opts, :limit)
        {limit, Keyword.get(opts, :tenant)}
      end

      defp defaulted(opts, _unused \\ nil), do: Keyword.fetch!(opts, :tenant)

      defp headed(opts, extra \\ nil)
      defp headed(opts, _extra), do: Keyword.get(opts, :actor)
    end
    """

    assert Enum.map(keyword_tenant_readers(planted), &elem(&1, 0)) == [
             "Arca.Planted.by_option/1",
             "Arca.Planted.through_a_helper/1",
             "Arca.Planted.by_access/2",
             "Arca.Planted.from_a_map/1",
             "Arca.Planted.matched/1",
             "Arca.Planted.by_pipe/1",
             "Arca.Planted.through_a_default/1",
             "Arca.Planted.through_a_bodiless_default/1"
           ]
  end

  test "the keyword-tenant detector sees a tenant option read one private call below the head" do
    # A reader whose tenant is an option, fetched one private call below
    # the public head.
    planted = ~S"""
    defmodule Arca.PolicyLog do
      def list(opts) do
        Arca.Repo.Errors.with_db_rescue("PolicyLog.list", fn -> {:ok, do_list(opts)} end)
        |> Arca.Data.project()
      end

      defp do_list(opts) do
        limit = Keyword.get(opts, :limit, 20)
        athanor_id = Keyword.fetch!(opts, :athanor_id)

        from(l in Row, where: l.athanor_id == ^athanor_id, limit: ^limit)
        |> Arca.Repo.all()
      end
    end
    """

    assert keyword_tenant_readers(planted) == [{"Arca.PolicyLog.list/1", 2}]
  end
end
