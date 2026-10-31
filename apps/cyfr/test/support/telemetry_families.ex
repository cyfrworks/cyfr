# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.TelemetryFamilies do
  @moduledoc """
  The telemetry families a producer emits with the kind as a variable,
  and the one rule that reads such a producer, for the two source scans of
  the telemetry roster (`Cyfr.TelemetryCatalogTest` and
  `Cyfr.Telemetry.EmitterDriftTest`).

  A family is an event prefix and the one list of its kinds, named by the
  function that answers it. A call passing `[prefix..., kind]` to
  `:telemetry.execute` or `:telemetry.span` emits the family's every
  event only in the canonical form: the prefix is a family's; the call
  sits in a `def` or `defp` clause whose head binds `kind` and whose guard
  is `kind in` that family's list, the list function called or a module
  attribute set to that call, alone or joined to other conditions by
  `and`; and nothing in the clause's body binds `kind` again. Any other
  variable in the kind position is an unbounded producer, which the scans
  refuse naming its file and line.
  """

  # Each family: its prefix, and the module and function that answer its
  # kinds.
  @families [{[:cyfr, :sanctum, :share], {Prima.ShareKinds, :all}}]

  @emitting [:execute, :span]

  @doc """
  The family emissions of one file's code, `source` read from `path`:
  the events of every canonical producer (`events`), and one
  `"path:line: why"` for every call that passes a variable kind outside
  the canonical form (`unbounded`).
  """
  @spec scan(String.t(), String.t()) :: %{events: [[atom()]], unbounded: [String.t()]}
  def scan(source, path) when is_binary(source) and is_binary(path) do
    ast = Code.string_to_quoted!(source)
    lists = list_attributes(ast)
    calls = family_calls(ast)

    judged = ast |> clauses() |> Enum.flat_map(&clause_calls(&1, lists)) |> Map.new()

    unbounded =
      for call <- calls,
          why = unbounded_why(Map.get(judged, call, :outside_a_clause)),
          do: "#{path}:#{line(call)}: #{why}"

    events = judged |> Map.values() |> Enum.flat_map(&verdict_events/1) |> Enum.uniq()

    %{events: events, unbounded: Enum.sort(unbounded)}
  end

  @doc """
  Whether `list`, the first argument a telemetry call passes, is a family
  emission: atoms and a variable last.
  """
  @spec family_shaped?(term()) :: boolean()
  def family_shaped?(list) when is_list(list) do
    case Enum.split(list, -1) do
      {[_ | _] = prefix, [{name, _meta, context}]} when is_atom(name) and is_atom(context) ->
        Enum.all?(prefix, &is_atom/1)

      _other ->
        false
    end
  end

  def family_shaped?(_first), do: false

  # ---------------------------------------------------------------------------

  # Every telemetry call of the file whose event is family-shaped.
  defp family_calls(ast) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _, [:telemetry, fun]}, _, [first | _]} = call, acc when fun in @emitting ->
          if family_shaped?(first), do: {call, [call | acc]}, else: {call, acc}

        node, acc ->
          {node, acc}
      end)

    calls
  end

  # The module attributes set to a family's list call, by name.
  defp list_attributes(ast) do
    {_ast, lists} =
      Macro.prewalk(ast, %{}, fn
        {:@, _, [{name, _, [value]}]} = node, acc when is_atom(name) ->
          case list_call(value) do
            {:ok, list} -> {node, Map.put(acc, name, list)}
            :error -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    lists
  end

  # A call of a family's list function, `Module.fun()`.
  defp list_call({{:., _, [{:__aliases__, _, parts}, fun]}, _, []}) when is_atom(fun) do
    names = Enum.map(parts, &Atom.to_string/1)

    case Enum.find(@families, fn {_prefix, {module, f}} ->
           {Module.split(module), f} == {names, fun}
         end) do
      {_prefix, list} -> {:ok, list}
      nil -> :error
    end
  end

  defp list_call(_value), do: :error

  # Every `def` and `defp` clause of the file, as its head, guard and body.
  defp clauses(ast) do
    {_ast, clauses} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head, body]} = node, acc when kind in [:def, :defp] ->
          {call, guard} =
            case head do
              {:when, _, [call, guard]} -> {call, guard}
              call -> {call, nil}
            end

          {node, [{call, guard, body} | acc]}

        node, acc ->
          {node, acc}
      end)

    clauses
  end

  # The family calls in one clause's body, each with its verdict.
  defp clause_calls({head, guard, body}, lists) do
    for call <- family_calls(body) do
      {{:., _, [:telemetry, _fun]}, _, [first | _]} = call
      {prefix, [{name, _, _}]} = Enum.split(first, -1)
      {call, verdict(prefix, name, head, guard, body, lists)}
    end
  end

  defp verdict(prefix, name, head, guard, body, lists) do
    with {:ok, list} <- family_of(prefix),
         :ok <- bound_by_head(name, head),
         :ok <- guarded(name, guard, list, lists),
         :ok <- not_rebound(name, body) do
      {:canonical, prefix, list}
    end
  end

  defp family_of(prefix) do
    case Enum.find(@families, &(elem(&1, 0) == prefix)) do
      {^prefix, list} -> {:ok, list}
      nil -> {:error, "no family has the prefix #{inspect(prefix)}"}
    end
  end

  defp bound_by_head(name, {_fun, _, args}) when is_list(args) do
    if Enum.any?(args, &binds?(&1, name)),
      do: :ok,
      else: {:error, "the kind #{name} is not a parameter of the clause"}
  end

  defp bound_by_head(name, _head),
    do: {:error, "the kind #{name} is not a parameter of the clause"}

  # The guard is `name in list`, alone or among conditions joined by `and`.
  defp guarded(name, guard, list, lists) do
    if membership?(guard, name, list, lists),
      do: :ok,
      else: {:error, "the kind #{name} is not guarded by membership in its family's list"}
  end

  defp membership?({:and, _, [left, right]}, name, list, lists),
    do: membership?(left, name, list, lists) or membership?(right, name, list, lists)

  defp membership?({:in, _, [{name, _, context}, expression]}, name, list, lists)
       when is_atom(context),
       do: names_list?(expression, list, lists)

  defp membership?(_guard, _name, _list, _lists), do: false

  defp names_list?({:@, _, [{attribute, _, context}]}, list, lists) when is_atom(context),
    do: Map.get(lists, attribute) == list

  defp names_list?(expression, list, _lists), do: list_call(expression) == {:ok, list}

  # Nothing in the body binds the kind again: no match, generator,
  # clause head or anonymous function argument names it.
  defp not_rebound(name, body) do
    {_ast, rebound?} =
      Macro.prewalk(body, false, fn
        {:=, _, [pattern, _value]} = node, acc -> {node, acc or binds?(pattern, name)}
        {:<-, _, [pattern, _value]} = node, acc -> {node, acc or binds?(pattern, name)}
        {:->, _, [patterns, _body]} = node, acc -> {node, acc or binds?(patterns, name)}
        node, acc -> {node, acc}
      end)

    if rebound?, do: {:error, "the kind #{name} is bound again in the clause"}, else: :ok
  end

  defp binds?(pattern, name) do
    {_ast, found?} =
      Macro.prewalk(pattern, false, fn
        {:^, _, _pinned}, acc -> {:pinned, acc}
        {^name, _, context} = node, _acc when is_atom(context) -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  defp verdict_events({:canonical, prefix, {module, fun}}),
    do: for(kind <- apply(module, fun, []), do: prefix ++ [kind])

  defp verdict_events(_unbounded), do: []

  defp unbounded_why({:canonical, _prefix, _list}), do: nil
  defp unbounded_why({:error, why}), do: "unbounded family producer: " <> why

  defp unbounded_why(:outside_a_clause),
    do: "unbounded family producer: the call sits outside a def or defp clause"

  defp line({_call, meta, _args}), do: Keyword.get(meta, :line, 0)
end
