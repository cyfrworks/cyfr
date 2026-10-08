# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.ErrorAdoptionTest do
  @moduledoc """
  A ratchet on the conversion to `Prima.Refusal`, the one refusal
  vocabulary.

  Limits plain-string error returns per module and rejects unlisted
  producers. A module may reduce its allowance as it adopts typed errors.

  So the roster is here, it is checked, and it only goes down:

  - A module that grows a new `{:error, "…"}` fails, naming it.
  - A module that converts some and forgets this file fails too, so the
    number in front of a reader is the number in the tree.
  - A module the scan reaches and the roster does not name may not return
    string errors at all.

  Converting one is the fix; lowering its number is the bookkeeping.
  Reaching zero deletes its line. Crafted operator sentences that fit no
  member of the vocabulary — compiler output, remediation hints, an
  upstream provider's own error code, a partial-failure count — are
  legitimately strings and simply stay counted here.

  ## What the scan reaches

  A tool module — one that defines `definition` or `handle/3` — and every
  module it names that this umbrella defines. Both halves are needed,
  because a refusal reaches a renderer from wherever it was produced: the
  scan read only tool modules once, and `Compendium.Builds.Provider`
  counted 2 where `Locus.MCP` counted 11, because the build orchestration's
  sentences live in `Compendium.Builds`, which defines no tool and which
  the scan never opened.

  ## Crashes and console lines

  A `raise` message and an `IO` line reach a crash report, a supervisor's
  log and a terminal, so they carry the shape of what went wrong — a fixed
  sentence and the offending term's kind (`Prima.LoggerContext.shape/1`) —
  never the term, which may be a credential, an identity or a tenant's
  data. `@raise_inspects` is the same ratchet over every `inspect` inside a
  `raise` or an `IO` call whose argument names a variable: what remains
  names a module or a name the code itself declares, and says so. An
  `inspect` of a constant — a module attribute, `__MODULE__`, a zero-argument
  roster call — names no runtime value and is not counted.
  """

  use ExUnit.Case, async: true

  # module path => string-returning `{:error, "…"}` sites remaining.
  # Ordered by size, which is also the order worth converting them in.
  @worklist %{
    # A malformed blob's `{:invalid_resource, node, edge, kind, message}`
    # says what is wrong with the stored resource, and nothing branches on
    # the sentence; a vault binding's scope, binding key, destination,
    # attach rule, named accounts, provided configuration and lender each
    # say theirs.
    "apps/prima/lib/prima/authority/blob.ex" => 22,
    "apps/prima/lib/prima/component_ref.ex" => 20,
    "apps/cyfr/lib/emissary/external/server.ex" => 19,
    # The concurrency argument's own refusal is a sentence about the value
    # offered; the two that were the tool's catch-alls are typed now, so
    # the action-coverage case reads one vocabulary.
    "apps/cyfr/lib/crucible/schedules/provider.ex" => 17,
    "apps/sanctum/lib/sanctum/providers/webhook.ex" => 18,
    "apps/cyfr/lib/crucible/provider.ex" => 12,
    # An upstream registry's own diagnostics, which are its words and not
    # this vocabulary's.
    "apps/cyfr/lib/compendium/oci/client.ex" => 12,
    "apps/cyfr/lib/grimoire/provider.ex" => 12,
    "apps/sanctum/lib/sanctum/providers/key.ex" => 11,
    # What is wrong with a cron expression, said in the expression's own
    # terms.
    "apps/cyfr/lib/crucible/schedules/cron.ex" => 10,
    "apps/cyfr/lib/compendium/scaffold.ex" => 8,
    "apps/cyfr/lib/compendium/provider.ex" => 6,
    "apps/cyfr/lib/compendium/providers/component.ex" => 6,
    # The entry rule's sentences, which the tincture validators return to
    # a publisher; the facade answers the same rule typed.
    "apps/cyfr/lib/compendium/tincture.ex" => 7,
    "apps/sanctum/lib/sanctum/providers/profile.ex" => 8,
    "apps/sanctum/lib/sanctum/webhook.ex" => 6,
    "apps/cyfr/lib/emissary/external/provider.ex" => 6,
    "apps/cyfr/lib/compendium/fork.ex" => 5,
    "apps/cyfr/lib/compendium/oci/reference.ex" => 5,
    "apps/prima/lib/prima/limits.ex" => 7,
    # The shape checks' sentences — why a decision or a completion is
    # outside the vocabulary, which `new/1` raises and the log refuses to
    # write — never a refusal on the wire; reached because the records
    # provider renders decisions.
    "apps/prima/lib/prima/decision.ex" => 13,
    "apps/sanctum/lib/sanctum/provider_credentials.ex" => 5,
    "apps/cyfr/lib/aqua/approvals.ex" => 4,
    "apps/cyfr/lib/compendium/component.ex" => 3,
    "apps/cyfr/lib/compendium/providers/shared.ex" => 4,
    "apps/cyfr/lib/compendium/registry.ex" => 4,
    "apps/cyfr/lib/grimoire/catalog.ex" => 3,
    # The build orchestration behind `Compendium.Builds.Provider`: the
    # three this ratchet could not see until the scan followed a tool
    # module into what it calls.
    "apps/cyfr/lib/compendium/builds.ex" => 3,
    "apps/sanctum/lib/sanctum/providers/oauth.ex" => 3,
    # Two of the three are the capacity refusals a poller sees when the
    # server will not mint them an athanor: remediation prose (wait, or ask
    # the operator), not a resource that is missing or briefly away.
    "apps/sanctum/lib/sanctum/providers/session.ex" => 3,
    "apps/sanctum/lib/sanctum/vault/oauth_grant.ex" => 3,
    # The authored-policy door's sentences, the person's own, which the
    # `aqua` tool wraps as `{:invalid_argument, …}`.
    "apps/cyfr/lib/compendium/aqua_agent.ex" => 2,
    # A tool this provider does not define, and the validation rate a
    # caller reached, with the seconds to wait.
    "apps/cyfr/lib/compendium/builds/provider.ex" => 2,
    "apps/cyfr/lib/crucible/record.ex" => 2,
    "apps/prima/lib/prima/arg.ex" => 2,
    "apps/sanctum/lib/sanctum/provider.ex" => 1,
    "apps/cyfr/lib/compendium/pull.ex" => 1,
    "apps/sanctum/lib/sanctum/api_key.ex" => 1,
    "apps/sanctum/lib/sanctum/auth/device_flow.ex" => 1,
    "apps/sanctum/lib/sanctum/providers/athanor.ex" => 1,
    "apps/sanctum/lib/sanctum/providers/tincture_visibility.ex" => 1,
    "apps/sanctum/lib/sanctum/vault.ex" => 1
  }

  # module path => `inspect` calls inside a `raise` or an `IO` call whose
  # argument names a variable. Each is a name, never a value.
  @raise_inspects %{
    # The config key that is missing, an atom this module spells.
    "apps/arca/lib/arca/adapters/s3.ex" => 1,
    # A changeset's field names and their validation sentences, which
    # `Arca.Data.invalid/1` renders interpolating only limits.
    "apps/arca/lib/arca/decision_log.ex" => 2,
    # The overlaid roots and the locator map the composition root installs:
    # root strings and module names, both literals of `Cyfr.Application`.
    "apps/arca/lib/arca/storage/unit_locator.ex" => 4,
    # Table names read from the live schema.
    "apps/arca/lib/arca/tenant_tables.ex" => 2,
    # The keyring's labels, which name keys and are not key material, and
    # the application's boot refusals; the composition root is S5's to
    # recut (the label prefix a too-long label prints is the one to review
    # there).
    "apps/cyfr/lib/cyfr/application.ex" => 5,
    # An application name from the boundary table.
    "apps/cyfr/lib/cyfr/boundaries.ex" => 1,
    # The payload module a topic row declares and the one it was handed.
    "apps/cyfr/lib/cyfr/bus.ex" => 2,
    # A payload module and the kinds it declares.
    "apps/cyfr/lib/cyfr/bus/payload.ex" => 3,
    # Configured provider modules that fail to load.
    "apps/cyfr/lib/grimoire/catalog.ex" => 2,
    # The installed port module.
    "apps/cyfr/lib/grimoire/proxy.ex" => 1,
    # The config keys that are missing or malformed, atoms this module
    # spells.
    "apps/opus/lib/opus/credentials.ex" => 2,
    # The keeper module that cannot run.
    "apps/opus/lib/opus/keeper.ex" => 1,
    # The malformed setting's config key.
    "apps/opus/lib/opus/settings.ex" => 1,
    # The installed port module.
    "apps/prima/lib/prima/caps.ex" => 1,
    # The provider module whose declaration is malformed.
    "apps/prima/lib/prima/provider.ex" => 3,
    # The installed port module.
    "apps/sanctum/lib/sanctum/consent/components.ex" => 1,
    # The installed port module.
    "apps/sanctum/lib/sanctum/grimoire.ex" => 1
  }

  defp root, do: Path.expand("../../../..", __DIR__)

  defp lib_files do
    root()
    |> Prima.Test.SourceTree.app_libs()
    |> Enum.flat_map(&Prima.Test.SourceTree.files!(Path.join([root(), &1, "**/*.ex"])))
  end

  # A module that defines a tool: where a refusal that reaches a renderer
  # is answered.
  defp tool_modules do
    Enum.filter(lib_files(), fn path ->
      source = Prima.Test.SourceTree.read(path)
      String.contains?(source, "def definition") or String.contains?(source, "def handle(")
    end)
  end

  # The tool modules, and every module of this umbrella they name. A
  # refusal a tool returns is often produced a call deeper, and a scan
  # that stops at the tool counts the wrong number.
  defp scanned_modules do
    by_module =
      for path <- lib_files(),
          name = defmodule_name(path),
          name != nil,
          into: %{},
          do: {name, path}

    tools = tool_modules()

    reached =
      for tool <- tools,
          {name, _line} <- Prima.Test.SourceTree.aliases(tool),
          path = Map.get(by_module, name),
          do: path

    Enum.uniq(tools ++ reached)
  end

  defp defmodule_name(path) do
    path
    |> Prima.Test.SourceTree.code_lines()
    |> Enum.find_value(fn {line, _n} ->
      case Regex.run(~r/^defmodule ([A-Z][\w.]*) do$/, line, capture: :all_but_first) do
        [name] -> name
        _ -> nil
      end
    end)
  end

  defp string_error_count(path) do
    path
    |> Prima.Test.SourceTree.code_lines()
    |> Enum.count(fn {line, _n} -> String.contains?(line, ~s|{:error, "|) end)
  end

  test "the scan reaches past the tool modules into what they call" do
    scanned = MapSet.new(scanned_modules(), &Path.relative_to(&1, root()))

    assert MapSet.size(scanned) > length(tool_modules()),
           "the scan reads only the tool modules; a refusal produced a call deeper is invisible"

    assert MapSet.member?(scanned, "apps/cyfr/lib/compendium/builds.ex"),
           "the build orchestration behind `Compendium.Builds.Provider` is the case this " <>
             "widening was measured against, and the scan does not open it"
  end

  test "no scanned module returns more string errors than the roster records" do
    counts =
      for path <- scanned_modules(),
          rel = Path.relative_to(path, root()),
          count = string_error_count(path),
          count > 0,
          into: %{},
          do: {rel, count}

    grown =
      for {rel, count} <- counts,
          recorded = Map.get(@worklist, rel, 0),
          count > recorded,
          do: "  #{rel}: #{count} now, #{recorded} recorded"

    assert grown == [],
           """
           These modules gained `{:error, "…"}` sites:

           #{Enum.join(Enum.sort(grown), "\n")}

           A refusal that a caller might branch on belongs in the
           `Prima.Refusal` vocabulary — `{:not_found, kind, name}`,
           `{:invalid_argument, msg}`, `{:unavailable, service}` — so the
           wire, the console and the guest all render one decision.

           If the new sentence is genuinely crafted operator prose that fits
           no member (compiler output, a remediation hint, an upstream
           provider's own code), raise the number above and say which.
           """

    shrunk =
      for {rel, recorded} <- @worklist,
          count = Map.get(counts, rel, 0),
          count < recorded,
          do: "  #{rel}: #{count} now, #{recorded} recorded"

    assert shrunk == [],
           """
           These modules have FEWER string errors than recorded — good, but
           the roster is the number a reader trusts, so lower it (or delete
           the line at zero):

           #{Enum.join(Enum.sort(shrunk), "\n")}
           """
  end

  describe "raise and IO lines" do
    test "no file inspects more runtime terms into a raise or an IO line than recorded" do
      counts =
        for path <- lib_files(),
            rel = Path.relative_to(path, root()),
            count = length(raise_inspects(rel, Prima.Test.SourceTree.read(path))),
            count > 0,
            into: %{},
            do: {rel, count}

      differ =
        for rel <- Enum.uniq(Map.keys(counts) ++ Map.keys(@raise_inspects)),
            now = Map.get(counts, rel, 0),
            recorded = Map.get(@raise_inspects, rel, 0),
            now != recorded,
            do: "  #{rel}: #{now} now, #{recorded} recorded"

      assert differ == [],
             """
             These files `inspect` a runtime term into a `raise` or an `IO`
             line a different number of times than recorded:

             #{Enum.join(Enum.sort(differ), "\n")}

             A crash report and a console carry the message whole. Name the
             term's kind with `Prima.LoggerContext.shape/1` and say what is
             wrong in fixed words; a count that fell is lowered here (and
             the line deleted at zero). A new site that names a module or a
             declared name joins the roster with that reason.
             """
    end

    test "the scan counts a runtime term and skips a constant, a log line and a return" do
      source = ~S"""
      defmodule Planted do
        require Logger

        @roster [:a, :b]

        def raised(other), do: raise(ArgumentError, "got #{inspect(other)}")
        def piped(reason), do: raise("failed: " <> (reason |> inspect()))
        def printed(reason), do: IO.puts(:stderr, "failed: #{inspect(reason)}")
        def dumped(term), do: IO.inspect(term)
        def field(row), do: raise(ArgumentError, "#{inspect(row.struct)} is wrong")
        def constant(_), do: raise(ArgumentError, "one of #{inspect(@roster)} in #{inspect(__MODULE__)}")
        def roster(_), do: raise(ArgumentError, "one of #{inspect(Planted.values())}")
        def shaped(other), do: raise(ArgumentError, "got #{Prima.LoggerContext.shape(other)}")
        def logged(reason), do: Logger.warning("failed: #{inspect(reason)}")
        def returned(reason), do: {:error, inspect(reason)}
      end
      """

      assert raise_inspects("planted.ex", source) |> Enum.map(&elem(&1, 0)) ==
               [:raised, :piped, :printed, :dumped, :field]
    end

    test "the roster names only files that still inspect into a raise" do
      gone =
        for rel <- Map.keys(@raise_inspects),
            path = Path.join(root(), rel),
            not File.exists?(path) or raise_inspects(rel, Prima.Test.SourceTree.read(path)) == [],
            do: rel

      assert gone == [], "delete these roster lines: #{inspect(Enum.sort(gone))}"
    end
  end

  # Each `inspect` of an expression naming a variable inside a `raise`,
  # `reraise` or `IO` call, and each `IO.inspect`, as `{function, line}`.
  defp raise_inspects(path, source) do
    ast = Code.string_to_quoted!(source, file: path, columns: true)
    {_ast, {_stack, sites}} = Macro.traverse(ast, {[], []}, &enter/2, &leave/2)
    Enum.reverse(sites)
  end

  defp enter({kind, _meta, [head | _]} = node, {stack, sites})
       when kind in [:def, :defp, :defmacro, :defmacrop],
       do: {node, {[{:function, function_name(head)} | stack], sites}}

  defp enter({{:., _, [{:__aliases__, _, [:IO]}, :inspect]}, meta, [subject | _]} = node, acc),
    do: inspected(node, meta, subject, :io, acc)

  defp enter({{:., _, [{:__aliases__, _, [:IO]}, _]}, _, _} = node, {stack, sites}),
    do: {node, {[:crash | stack], sites}}

  defp enter({call, _meta, args} = node, {stack, sites})
       when call in [:raise, :reraise] and is_list(args),
       do: {node, {[:crash | stack], sites}}

  defp enter({:|>, meta, [subject, {:inspect, _, _}]} = node, {stack, sites}),
    do: inspected(node, meta, subject, :crash in stack, {stack, sites})

  defp enter({:inspect, meta, [subject | _]} = node, {stack, sites}),
    do: inspected(node, meta, subject, :crash in stack, {stack, sites})

  defp enter(node, {stack, sites}), do: {node, {[:node | stack], sites}}

  defp leave(node, {[_ | stack], sites}), do: {node, {stack, sites}}

  defp inspected(node, meta, subject, counted, {stack, sites}) do
    sites =
      if counted in [true, :io] and names_variable?(subject),
        do: [{enclosing(stack), meta[:line]} | sites],
        else: sites

    {node, {[:inspect | stack], sites}}
  end

  # A variable other than a special form (`__MODULE__`), outside a module
  # attribute: a term the code received rather than one it spelled.
  defp names_variable?(subject) do
    {_subject, found?} =
      Macro.prewalk(subject, false, fn
        {:@, _meta, _attribute}, found ->
          {:attribute, found}

        {name, _meta, context} = node, found when is_atom(name) and is_atom(context) ->
          {node, found or not String.starts_with?(Atom.to_string(name), "__")}

        node, found ->
          {node, found}
      end)

    found?
  end

  defp enclosing(stack),
    do: Enum.find_value(stack, :module_body, &(match?({:function, _}, &1) && elem(&1, 1)))

  defp function_name({:when, _, [head | _]}), do: function_name(head)
  defp function_name({name, _, _}) when is_atom(name), do: name

  test "the roster names only modules the scan still reaches" do
    live = MapSet.new(scanned_modules(), &Path.relative_to(&1, root()))

    gone = for rel <- Map.keys(@worklist), not MapSet.member?(live, rel), do: rel

    assert gone == [],
           "the roster names files that are gone or no longer reached: #{inspect(Enum.sort(gone))}"
  end
end
