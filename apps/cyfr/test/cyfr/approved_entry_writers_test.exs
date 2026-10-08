# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ApprovedEntryWritersTest do
  @moduledoc """
  Pins who names `Sanctum.Context`'s `approved_entry`, and who gives it a
  value.

  The field is the account an approved launch's card showed, and the
  run's root admission refuses unless its binding holds it. Only
  `Aqua.Launch.dispatch/2` may set it, for the one call it dispatches; a
  second setter could name an expectation no person approved. This is a
  tripwire for that rule, not a proof over all Elixir: every `.ex` file
  under `apps/*/lib` is read with `Code.string_to_quoted/2`, and the walk
  judges the nodes it can see.

  **What it sees.** The atom `:approved_entry` as a node: a key in a
  struct, a map or a keyword list; a literal atom (`Map.put/3`,
  `Map.update/4`, `Access.key/2`, `struct/2`); a dotted field
  (`ctx.approved_entry`, the path `put_in/2` and `update_in/2` take); in
  any code the files hold as written, a `quote` block or a macro body
  among it. A call's or a type's local name is another node and is not
  the field; a reference to the type through its module
  (`Sanctum.Context.approved_entry()`) names the atom and counts, as a
  declaration, so a new one fails the roster, which errs toward failing.

  **What it cannot see.** An atom built at runtime or by a sigil
  (`~w(approved_entry)a`), a field written through `Kernel.binding/0`
  over a variable named `approved_entry`, code in `~H` sigils and `.heex`
  templates (and `.eex` templates, `~E` and `~L` sigils, and source
  evaluated with `Code.eval_string/3`), what a macro does with its
  arguments, and a piece of a `quote` taken out and evaluated at runtime
  (`Code.eval_quoted/3`): the walk neither expands macros nor runs code,
  so code evaluated from where it is written as a pattern or a
  declaration is judged by where it is written. This walk does not see
  them.

  **How it judges what it sees.** The roster names each file with its
  exact count, so a new occurrence fails and a removed one shrinks the
  count here. Beside it, the occurrences that give the field a value are
  exactly the one in `Aqua.Launch`, so an occurrence changed in place into
  a setter fails although the counts hold. An occurrence gives it no
  value only when its node, as written, says so (an `unquote` or
  `unquote_splicing` argument runs when its `quote` is built, and is a
  body wherever it is written):

    * a pattern: a function head's parameters and guard (a default's
      expression is a body); a `->` head in a `case`, a `fn`, `receive`'s
      message clauses, `with`'s `else`, or `try`'s `rescue`, `catch` and
      `else`; the left of `=` and of `<-`. A `cond` clause's condition and
      `receive`'s `after` timeout are evaluated, and are a body;
    * the field's declaration: a bare `:approved_entry` or
      `approved_entry: nil` in `defstruct` (any other default is a write),
      and a type attribute;
    * the clear: the key with the literal `nil` directly in a map or
      struct update, `%{ctx | approved_entry: nil}`.

  Every other occurrence it sees is judged a write, a read in a body
  included: a new reader of the approved account is rostered with its
  reason as a writer is.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  # Every occurrence, by file and exact count.
  @rostered %{
    # `dispatch/2`'s expectation on the approver's context: the one setter.
    "apps/cyfr/lib/aqua/launch.ex" => 1,
    # `admit/4`'s clear to `nil` on the context the run carries on, and
    # `approved_root/2`'s two function heads, which read it.
    "apps/cyfr/lib/crucible/admission.ex" => 3,
    # The field's declaration in the struct and its key in `t:t/0`.
    "apps/sanctum/lib/sanctum/context.ex" => 2
  }

  # The one setter.
  @setter "apps/cyfr/lib/aqua/launch.ex"

  @defs [:def, :defp, :defmacro, :defmacrop]
  @type_attributes [:type, :typep, :opaque, :spec, :callback, :macrocallback]

  # Every occurrence in every library file: `{file, line, kind}`, where
  # `kind` is `:pattern`, `:declaration`, `:clear` or `:write`.
  defp occurrences do
    for path <- Prima.Test.SourceTree.files!(Path.join(@root, "apps/*/lib/**/*.ex")),
        rel = Path.relative_to(path, @root),
        {line, kind} <- path |> File.read!() |> quoted!(rel) |> walk(:body, 0, []) do
      {rel, line, kind}
    end
  end

  defp quoted!(source, rel) do
    case Code.string_to_quoted(source, file: rel) do
      {:ok, ast} -> ast
      {:error, reason} -> flunk("#{rel} does not parse: #{inspect(reason)}")
    end
  end

  # The walk carries the mode the node sits in (`:body`, `:pattern` or
  # `:declaration`) and the nearest line, since an atom carries none.
  defp walk(:approved_entry, mode, line, acc), do: [{line, kind_of(mode)} | acc]

  # An `unquote`'s argument runs when its `quote` is built: a body,
  # whatever position it is written in.
  defp walk({unquote, meta, [arg]}, _mode, line, acc)
       when unquote in [:unquote, :unquote_splicing],
       do: walk(arg, :body, meta[:line] || line, acc)

  # A function's head is a pattern; a default's expression in it, and the
  # body, are not.
  defp walk({def, meta, [head | body]}, _mode, _line, acc) when def in @defs do
    line = meta[:line] || 0
    acc = head(head, line, acc)
    walk(body, :body, line, acc)
  end

  # In `defstruct`, a bare field or a `nil` default is the declaration;
  # any other default gives every struct a value, and is a write.
  defp walk({:defstruct, meta, [fields]}, _mode, _line, acc) when is_list(fields) do
    line = meta[:line] || 0

    Enum.reduce(fields, acc, fn
      :approved_entry, acc -> [{line, :declaration} | acc]
      {:approved_entry, nil}, acc -> [{line, :declaration} | acc]
      {:approved_entry, default}, acc -> walk(default, :body, line, [{line, :write} | acc])
      {field, default}, acc when is_atom(field) -> walk(default, :body, line, acc)
      {field, default}, acc -> walk(default, :body, line, walk(field, :body, line, acc))
      other, acc -> walk(other, :body, line, acc)
    end)
  end

  defp walk({:defstruct, meta, args}, _mode, _line, acc),
    do: walk(args, :body, meta[:line] || 0, acc)

  defp walk({:@, meta, [{attribute, _, args}]}, _mode, _line, acc)
       when attribute in @type_attributes,
       do: walk(args, :declaration, meta[:line] || 0, acc)

  # A `->` head is a pattern only in the clauses that match: a `case`'s, a
  # `fn`'s, `receive`'s message clauses, `with`'s `else`, and `try`'s
  # `rescue`, `catch` and `else`. Anywhere else it is judged as a body: a
  # `cond` condition and `receive`'s `after` timeout, which are evaluated,
  # and a `for … reduce:` head, a function's implicit `rescue`, `catch`
  # and `else` and a piped `case`'s, which match, so those err toward
  # failing.
  defp walk({:case, meta, [expr, blocks]}, mode, line, acc) when is_list(blocks) do
    line = meta[:line] || line
    blocks(blocks, [:do], mode, line, walk(expr, mode, line, acc))
  end

  defp walk({:fn, meta, clauses}, mode, line, acc) when is_list(clauses),
    do: matching(clauses, mode, meta[:line] || line, acc)

  defp walk({:receive, meta, [blocks]}, mode, line, acc) when is_list(blocks),
    do: blocks(blocks, [:do], mode, meta[:line] || line, acc)

  defp walk({:with, meta, args}, mode, line, acc) when is_list(args) do
    line = meta[:line] || line
    {clauses, blocks} = Enum.split(args, -1)

    case blocks do
      [blocks] when is_list(blocks) ->
        blocks(blocks, [:else], mode, line, walk(clauses, mode, line, acc))

      _ ->
        walk(args, mode, line, acc)
    end
  end

  defp walk({:try, meta, [blocks]}, mode, line, acc) when is_list(blocks),
    do: blocks(blocks, [:rescue, :catch, :else], mode, meta[:line] || line, acc)

  defp walk({:->, meta, [args, body]}, mode, line, acc) do
    line = meta[:line] || line
    walk(body, mode, line, walk(args, mode, line, acc))
  end

  defp walk({op, meta, [left, right]}, mode, line, acc) when op in [:=, :<-] do
    line = meta[:line] || line
    walk(right, mode, line, walk(left, pattern(mode), line, acc))
  end

  # A map or struct update: the key with the literal `nil` is the clear.
  defp walk({:%{}, meta, [{:|, _, [base, pairs]}]}, mode, line, acc) when is_list(pairs) do
    line = meta[:line] || line

    Enum.reduce(pairs, walk(base, mode, line, acc), fn
      {:approved_entry, nil}, acc when mode == :body -> [{line, :clear} | acc]
      pair, acc -> walk(pair, mode, line, acc)
    end)
  end

  # A call or a variable: its name is not a node of the field.
  defp walk({name, meta, args}, mode, line, acc) when is_list(meta) do
    line = meta[:line] || line
    acc = if is_atom(name), do: acc, else: walk(name, mode, line, acc)
    if is_list(args), do: walk(args, mode, line, acc), else: acc
  end

  defp walk({left, right}, mode, line, acc),
    do: walk(right, mode, line, walk(left, mode, line, acc))

  defp walk(list, mode, line, acc) when is_list(list),
    do: Enum.reduce(list, acc, &walk(&1, mode, line, &2))

  defp walk(_leaf, _mode, _line, acc), do: acc

  # A head's parameters and guard are patterns, but a default's expression
  # is evaluated, and is a body.
  defp head({:when, meta, [call | guards]}, line, acc),
    do: head(call, meta[:line] || line, walk(guards, :pattern, line, acc))

  # A name computed in the head (`def unquote(name)(...)`) is evaluated.
  defp head({name, meta, params}, line, acc)
       when is_list(params) and name not in [:unquote, :unquote_splicing] do
    line = meta[:line] || line
    acc = if is_atom(name), do: acc, else: walk(name, :body, line, acc)

    Enum.reduce(params, acc, fn
      {:\\, _, [param, default]}, acc ->
        walk(default, :body, line, walk(param, :pattern, line, acc))

      param, acc ->
        walk(param, :pattern, line, acc)
    end)
  end

  defp head(other, line, acc), do: walk(other, :pattern, line, acc)

  # A construct's `do:`/`else:`/... blocks: the named ones hold matching
  # clauses, every other is walked as it is.
  defp blocks(blocks, matching_keys, mode, line, acc) do
    Enum.reduce(blocks, acc, fn
      {key, clauses}, acc when is_list(clauses) ->
        if key in matching_keys,
          do: matching(clauses, mode, line, acc),
          else: walk(clauses, mode, line, acc)

      other, acc ->
        walk(other, mode, line, acc)
    end)
  end

  defp matching(clauses, mode, line, acc) do
    Enum.reduce(clauses, acc, fn
      {:->, meta, [args, body]}, acc ->
        line = meta[:line] || line
        walk(body, mode, line, walk(args, pattern(mode), line, acc))

      other, acc ->
        walk(other, mode, line, acc)
    end)
  end

  defp pattern(:declaration), do: :declaration
  defp pattern(_mode), do: :pattern

  defp kind_of(:body), do: :write
  defp kind_of(mode), do: mode

  test "the field is named only where the roster says, as often as it says" do
    occurrences = occurrences()
    counts = occurrences |> Enum.map(&elem(&1, 0)) |> Enum.frequencies()

    unrostered =
      for {rel, line, kind} <- occurrences, not Map.has_key?(@rostered, rel) do
        "  #{rel}:#{line} (#{kind})"
      end

    assert unrostered == [],
           """
           These name `Sanctum.Context`'s `approved_entry` in a file the
           roster does not hold:

           #{Enum.join(unrostered, "\n")}

           Only `Aqua.Launch` sets the account an approval bound, and only
           the root's admission reads and clears it. A new writer of it is a
           change to that rule, made in `ARCHITECTURE.md` and here with its
           reason, never added to pass this check.
           """

    for {rel, expected} <- @rostered do
      found = Map.get(counts, rel, 0)

      assert found == expected,
             """
             `#{rel}` names `approved_entry` #{found} times where the roster
             expects #{expected}. A new occurrence is a reader or a writer of
             the approved account and is rostered with its reason; a removed
             one shrinks the count here, so the roster stays honest.
             """
    end
  end

  test "the one occurrence giving the field a value is Aqua.Launch's" do
    writes = for {rel, line, :write} <- occurrences(), do: {rel, line}

    assert match?([{@setter, _line}], writes),
           """
           Exactly one occurrence may give `approved_entry` a value, outside
           a pattern, the field's declaration and the clear in an update:
           `Aqua.Launch.dispatch/2`'s, on the approver's context for the one
           call it dispatches. Found:

           #{Enum.map_join(writes, "\n", fn {rel, line} -> "  #{rel}:#{line}" end)}

           Any other is an expectation no person approved: the root's
           admission would compare against it as if a card had shown it.
           """
  end
end
