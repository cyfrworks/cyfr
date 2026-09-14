# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.WithElseScopeTest do
  @moduledoc """
  `with` does not export its pattern bindings to `else`.

  A clause that rebinds a name the failure arm then reads looks like it
  hands that arm the updated value. It hands it the *outer* one, silently,
  and the compiler says nothing because the name is bound either way.

  This shipped twice, both times defeating credential masking:

    * `Opus.Executor.do_run/7` rebound the execution pipeline through five
      stages; every failure arm masked with the pre-pipeline struct, whose
      `preloaded_fields` is empty — so an execution's unsealed vault
      material went unmasked onto the row, the terminal SSE event, and the
      error handed back to MCP clients and parent formulas.
    * `Emissary.MCP.ExternalServer.do_initialize/1` rebound the state with
      resolved headers; the failure arm masked with the struct's empty
      `headers`, so an upstream that echoed the Authorization header into
      its error body carried the credential out through `state.error`.

  Names bound by a with expression must not be read by its own else
  unless that arm independently binds them.
  """

  use ExUnit.Case, async: true

  defp root, do: Path.expand("../../../..", __DIR__)

  defp source_files do
    Cyfr.Test.SourceTree.files!(Path.join(root(), "apps/*/lib/**/*.ex"))
  end

  # Every variable name appearing anywhere in an AST fragment. `_`-prefixed
  # names and the compile-time pseudo-variables are not bindings a reader
  # could confuse.
  defp vars(ast) do
    {_, acc} =
      Macro.prewalk(ast, MapSet.new(), fn
        {name, _meta, ctx} = node, acc when is_atom(name) and is_atom(ctx) ->
          skip? =
            String.starts_with?(Atom.to_string(name), "_") or
              name in [:__MODULE__, :__DIR__, :__ENV__, :__CALLER__, :__STACKTRACE__]

          {node, if(skip?, do: acc, else: MapSet.put(acc, name))}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # What the else body binds for itself: clause patterns (case/cond/fn/try
  # arms), `=` left sides, and nested `<-` patterns. Those shadow the outer
  # value, so reading them is not the trap.
  defp shadowed_in(body) do
    {_, acc} =
      Macro.prewalk(body, MapSet.new(), fn
        {:->, _, [pats, _]} = node, acc ->
          {node, Enum.reduce(pats, acc, &MapSet.union(&2, vars(&1)))}

        {op, _, [lhs, _]} = node, acc when op in [:=, :<-] ->
          {node, MapSet.union(acc, vars(lhs))}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp offenders_in(args, meta, path) do
    {clauses, opts} =
      case List.last(args) do
        kw when is_list(kw) ->
          if Keyword.keyword?(kw) and Keyword.has_key?(kw, :do),
            do: {Enum.drop(args, -1), kw},
            else: {args, []}

        _ ->
          {args, []}
      end

    case Keyword.get(opts, :else) do
      nil ->
        []

      else_clauses ->
        bound_by_with =
          clauses
          |> Enum.flat_map(fn
            {:<-, _, [pattern, _expr]} -> [pattern]
            _ -> []
          end)
          |> Enum.reduce(MapSet.new(), &MapSet.union(&2, vars(&1)))

        Enum.flat_map(else_clauses, fn
          {:->, _, [patterns, body]} ->
            bound_here =
              patterns
              |> Enum.reduce(MapSet.new(), &MapSet.union(&2, vars(&1)))
              |> MapSet.union(shadowed_in(body))

            stale =
              bound_by_with
              |> MapSet.intersection(vars(body))
              |> MapSet.difference(bound_here)

            if Enum.empty?(stale),
              do: [],
              else: [{Path.relative_to(path, root()), meta[:line], Enum.sort(stale)}]

          _ ->
            []
        end)
    end
  end

  defp offenders(path) do
    ast =
      path
      |> Cyfr.Test.SourceTree.read()
      |> Code.string_to_quoted!(columns: true)

    {_, found} =
      Macro.prewalk(ast, [], fn
        {:with, meta, args} = node, acc when is_list(args) ->
          {node, offenders_in(args, meta, path) ++ acc}

        node, acc ->
          {node, acc}
      end)

    found
  end

  test "no `else` arm reads a name its own `with` rebinds" do
    found =
      source_files()
      |> Enum.flat_map(&offenders/1)
      |> Enum.uniq()
      |> Enum.sort()

    assert found == [], """
    A `with` rebinds these names and its own `else` reads them — the arm
    receives the OUTER value, not the rebound one:

    #{Enum.map_join(found, "\n", fn {path, line, names} -> "  #{path}:#{line} — #{Enum.map_join(names, ", ", &to_string/1)}" end)}

    If the arm wants the updated value, have the clause answer with it and
    bind it in the else pattern (`{:error, p, reason}`). If it wants the
    outer one, bind the clause result under its own name so the choice is
    visible. See this module's doc for the two credential leaks this shape
    produced.
    """
  end
end
