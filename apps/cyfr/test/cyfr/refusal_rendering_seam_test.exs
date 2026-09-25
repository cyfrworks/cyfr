# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RefusalRenderingSeamTest do
  @moduledoc """
  No `inspect/1` of a refusal reaches a stored row or a wire body.

  A reason a callee handed back is a private term: rendered with
  `inspect/1` it puts Elixir syntax, internal field names and whatever
  the term carried into `turns.error`, `executions.error_message`,
  `mcp_logs`, a schedule row, an HTTP or JSON-RPC body or a guest's
  answer. The table renders it instead (`Grimoire.render/1`,
  `Prima.Refusal.classify/1`), or the site logs it.

  The scan reads every umbrella app's `lib` as code, not text, and finds
  each `inspect/1,2` — called or piped into — whose argument mentions a
  variable this codebase names a callee's answer by (`reason`, `error`,
  `e`, `other`, `why`), however it is wrapped (`inspect(reason)`,
  `reason |> inspect()`, `inspect(Sanitizer.sanitize(reason))`,
  `inspect(elem(reason, 0))`), wherever it sits: in an `{:error, …}`
  return, a message interpolation, a map field. An `inspect` inside a
  `Logger` call is a log line, which is where a term belongs; one inside
  `raise` or an `IO` write is a crash or a console line, outside this
  seam. Everything else is a finding unless listed below by file and
  function, with the reason it is not a rendering.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  # The names a callee's answer goes by where it is inspected.
  @vocabulary [:reason, :error, :e, :other, :why]

  # The sites that inspect such a term and are not a rendering: each is
  # read only by a log line. `{file, function}` => why.
  @allowed %{
    {"apps/locus/lib/locus/config.ex", :log_format} =>
      "Locus's boot-time configuration error, which refuses the release's " <>
        "start and reaches only its boot log",
    {"apps/sanctum/lib/sanctum/oauth/refresh_lock.ex", :describe_exit} =>
      "the refresh lock's exit description, interpolated only into its " <>
        "`Logger.warning`"
  }

  test "no callee's term is inspected into a rendering" do
    unlisted =
      for {path, function, line} <- sites(),
          not Map.has_key?(@allowed, {path, function}),
          do: "  #{path}:#{line} (#{function})"

    assert unlisted == [],
           """
           These sites `inspect/1` a callee's term outside a log line:

           #{Enum.join(Enum.sort(unlisted), "\n")}

           A stored row, a wire body and a guest's answer read a refusal
           through the table — `Grimoire.render/1` or
           `Prima.Refusal.classify/1` — never its spelling. Log the term
           inside the `Logger` call if an operator needs it.
           """
  end

  test "every allowed site is still there" do
    found = MapSet.new(sites(), fn {path, function, _line} -> {path, function} end)
    stale = for {site, _why} <- @allowed, not MapSet.member?(found, site), do: site

    assert stale == [],
           "these allowed sites no longer inspect a term — delete their entries: " <>
             inspect(Enum.sort(stale))
  end

  describe "the scan" do
    test "finds an inspected term in a return and in a message, and skips a log line" do
      source = """
      defmodule Planted do
        require Logger

        def returned(reason), do: {:error, "failed: \#{inspect(reason)}"}

        def worded(other) do
          message = "got " <> inspect(other)
          {:error, {:invalid_argument, message}}
        end

        def stored(why), do: %{error: inspect(why, limit: 5)}

        def wrapped(reason),
          do: {:error, "failed: \#{inspect(Prima.Sanitizer.sanitize(reason))}"}

        def piped(error), do: {:error, error |> inspect()}

        def tagged(reason), do: "refused: " <> inspect(elem(reason, 0))

        def logged(error) do
          Logger.warning("the store answered \#{inspect(error)}")
          :error
        end

        def crashed(e), do: raise(ArgumentError, "bad: \#{inspect(e)}")

        def described(module), do: inspect(module)
      end
      """

      found = scan("planted.ex", source) |> Enum.map(fn {_path, function, _line} -> function end)

      assert Enum.sort(found) == [:piped, :returned, :stored, :tagged, :worded, :wrapped]
    end

    test "reaches every umbrella app's lib" do
      libs = Prima.Test.SourceTree.app_libs(@root)

      for app <- ~w(arca cyfr locus opus prima sanctum) do
        assert "apps/#{app}/lib" in libs, "the scan does not read apps/#{app}/lib"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The scan
  # ---------------------------------------------------------------------------

  defp sites do
    excluded = MapSet.new(Cyfr.Boundaries.scan_exclusions())

    for lib <- Prima.Test.SourceTree.app_libs(@root),
        file <- Prima.Test.SourceTree.files!(Path.join([@root, lib, "**/*.ex"])),
        path = Path.relative_to(file, @root),
        not MapSet.member?(excluded, path),
        site <- scan(path, Prima.Test.SourceTree.read(file)),
        do: site
  end

  # Each `inspect` of an expression mentioning a vocabulary variable,
  # outside a log line, a raise or an IO write, as
  # `{path, enclosing function, line}`.
  defp scan(path, source) do
    ast = Code.string_to_quoted!(source, file: path, columns: true)
    {_ast, {_stack, sites}} = Macro.traverse(ast, {[], []}, &enter/2, &leave/2)
    sites |> Enum.reverse() |> Enum.map(fn {function, line} -> {path, function, line} end)
  end

  defp enter({kind, _meta, [head | _]} = node, {stack, sites})
       when kind in [:def, :defp, :defmacro, :defmacrop],
       do: {node, {[{:function, name(head)} | stack], sites}}

  defp enter({{:., _, [{:__aliases__, _, [:Logger]}, _]}, _, _} = node, {stack, sites}),
    do: {node, {[:exempt | stack], sites}}

  defp enter({{:., _, [{:__aliases__, _, [:IO]}, _]}, _, _} = node, {stack, sites}),
    do: {node, {[:exempt | stack], sites}}

  defp enter({call, _meta, args} = node, {stack, sites})
       when call in [:raise, :reraise] and is_list(args),
       do: {node, {[:exempt | stack], sites}}

  defp enter({:|>, meta, [subject, {:inspect, _, _}]} = node, {stack, sites}),
    do: inspected(node, meta, subject, stack, sites)

  defp enter({:inspect, meta, [subject | _]} = node, {stack, sites}),
    do: inspected(node, meta, subject, stack, sites)

  defp enter(node, {stack, sites}), do: {node, {[:node | stack], sites}}

  defp leave(node, {[_ | stack], sites}), do: {node, {stack, sites}}

  defp inspected(node, meta, subject, stack, sites) do
    sites =
      if :exempt in stack or not mentions_vocabulary?(subject),
        do: sites,
        else: [{function(stack), meta[:line]} | sites]

    {node, {[:inspect | stack], sites}}
  end

  defp mentions_vocabulary?(subject) do
    {_subject, found?} =
      Macro.prewalk(subject, false, fn
        {variable, _meta, context} = node, _found
        when variable in @vocabulary and is_atom(context) ->
          {node, true}

        node, found ->
          {node, found}
      end)

    found?
  end

  defp function(stack),
    do: Enum.find_value(stack, :module_body, &(match?({:function, _}, &1) && elem(&1, 1)))

  defp name({:when, _, [head | _]}), do: name(head)
  defp name({name, _, _}) when is_atom(name), do: name
end
