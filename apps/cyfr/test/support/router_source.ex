# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.RouterSource do
  @moduledoc """
  What a router source file declares, read from its syntax tree alone:
  the plugs of each pipeline and the verb, path and pipelines of each
  route.

  `__routes__/0` says what the compiled table holds but not which file
  declared a row or what a pipeline contains; this reads the file, so a
  route map can say both. Nothing is compiled or expanded, and no
  Phoenix internals are read.
  """

  @verbs ~w(get post put patch delete options head)a

  @doc """
  Every `pipeline :name do … end` block in `file`, mapped to its `plug`
  heads in order: a module plug as its full name (the file's `alias`
  lines applied), a function plug as `":name"`. Options are not read.
  """
  @spec pipelines(Path.t()) :: %{String.t() => [String.t()]}
  def pipelines(file) do
    {body, aliases} = module_body(file)

    for {:pipeline, _, [name, [do: block]]} <- statements(body), into: %{} do
      {Atom.to_string(name), plugs(block, aliases)}
    end
  end

  @doc """
  Every route `file` declares, as `%{verb:, path:, pipe_through:}`: the
  full path with each enclosing `scope`'s prefix applied, and the
  pipelines in effect where the route is declared — every `pipe_through`
  of the enclosing scopes, and of its own scope before it, in order. A
  `live` route is a `"GET"` and `match :*` is `"*"`. A `live_session`
  adds no prefix and opens no scope, so a `pipe_through` inside one
  stays in effect after it, as it does in Phoenix.
  """
  @spec routes(Path.t()) :: [
          %{verb: String.t(), path: String.t(), pipe_through: [String.t()]}
        ]
  def routes(file) do
    {body, _aliases} = module_body(file)
    {found, _pipes} = walk(body, {[], []})
    found
  end

  defp module_body(file) do
    ast = file |> File.read!() |> Code.string_to_quoted!(file: file)
    {:defmodule, _, [_name, [do: body]]} = ast
    {body, aliases(body)}
  end

  defp statements({:__block__, _, statements}), do: statements
  defp statements(statement), do: [statement]

  # The module-level `alias` lines, as `%{"Short" => "Full.Name"}`.
  defp aliases(body) do
    for statement <- statements(body), pair <- alias_pairs(statement), into: %{}, do: pair
  end

  defp alias_pairs({:alias, _, [{:__aliases__, _, parts}]}),
    do: [{parts |> List.last() |> Atom.to_string(), join(parts)}]

  defp alias_pairs({:alias, _, [{:__aliases__, _, parts}, opts]}) do
    case Keyword.get(opts, :as) do
      {:__aliases__, _, [as]} -> [{Atom.to_string(as), join(parts)}]
      nil -> [{parts |> List.last() |> Atom.to_string(), join(parts)}]
    end
  end

  defp alias_pairs({:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]}) do
    for {:__aliases__, _, parts} <- children,
        do: {parts |> List.last() |> Atom.to_string(), join(base ++ parts)}
  end

  defp alias_pairs(_statement), do: []

  # Every `plug` call in a pipeline's body, in source order. A plug's own
  # arguments are not descended into.
  defp plugs(block, aliases) do
    {_ast, found} =
      Macro.prewalk(block, [], fn
        {:plug, _, [head | _]}, acc -> {:ok, [render(head, aliases) | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(found)
  end

  defp render(name, _aliases) when is_atom(name), do: inspect(name)

  defp render({:__aliases__, _, [first | rest]}, aliases) when is_atom(first) do
    case Map.fetch(aliases, Atom.to_string(first)) do
      {:ok, full} -> Enum.join([full | Enum.map(rest, &Atom.to_string/1)], ".")
      :error -> join([first | rest])
    end
  end

  defp join(parts), do: Enum.map_join(parts, ".", &Atom.to_string/1)

  # `state` is `{prefix, pipes}`: the enclosing scopes' paths and the
  # pipelines in effect. Each clause answers the routes it declares and
  # the pipelines in effect after it; a scope's own `pipe_through` ends
  # with the scope.
  defp walk({:__block__, _, statements}, {prefix, pipes}) do
    Enum.flat_map_reduce(statements, pipes, fn statement, pipes ->
      walk(statement, {prefix, pipes})
    end)
  end

  defp walk({:scope, _, args}, {prefix, pipes}) do
    {found, _inner} = walk(do_block(args), {prefix ++ [scope_path(args)], pipes})
    {found, pipes}
  end

  defp walk({:live_session, _, args}, state), do: walk(do_block(args), state)

  defp walk({:pipe_through, _, [names]}, {_prefix, pipes}),
    do: {[], pipes ++ Enum.map(List.wrap(names), &Atom.to_string/1)}

  defp walk({:live, _, [path | _]}, state), do: route("GET", path, state)

  defp walk({:match, _, [verb, path | _]}, state) when is_atom(verb),
    do: route(verb |> Atom.to_string() |> String.upcase(), path, state)

  defp walk({verb, _, [path | _]}, state) when verb in @verbs and is_binary(path),
    do: route(verb |> Atom.to_string() |> String.upcase(), path, state)

  defp walk(_statement, {_prefix, pipes}), do: {[], pipes}

  defp route(verb, path, {prefix, pipes}),
    do: {[%{verb: verb, path: path(prefix, path), pipe_through: pipes}], pipes}

  # A block's `do:` is its last argument, whatever options precede it.
  defp do_block(args) do
    args |> List.last() |> Keyword.fetch!(:do)
  end

  defp scope_path([path | _]) when is_binary(path), do: path
  defp scope_path([opts | _]) when is_list(opts), do: Keyword.get(opts, :path, "/")

  defp path(prefix, path) do
    segments =
      for part <- prefix ++ [path], segment <- String.split(part, "/", trim: true), do: segment

    "/" <> Enum.join(segments, "/")
  end
end
