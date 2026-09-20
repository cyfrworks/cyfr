# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.SanctumInventoryTest do
  @moduledoc """
  `docs/plans/sanctum-inventory.md` against the tree it describes.

  Slice G moves Arca below Sanctum and both below Cyfr. The inventory is
  what the slice's targets are cut from: every dependency Sanctum has above
  itself, every dependency Arca has outside contracts, and the one target
  that owns each file. A target reads it instead of reading a sibling's
  output, so an edge the document does not know about is an edge that no
  target closes — and `apps/sanctum` or `apps/arca` then fails to compile a
  wave later, which is exactly how the first cut of G1–G8 went wrong.

  Two scans, because neither sees everything:

    * the **source scan**, through `Cyfr.Test.CodeLines` — the filter every
      architecture roster uses — sees aliases, struct patterns, typespecs
      and compile-time attributes, which emit no call;
    * the **compiled scan**, the import table of each `.beam`, sees every
      remote call the compiler emitted, including ones spelled in a way a
      regex would miss.

  Both must be non-empty. A scan that reads nothing passes every assertion
  it makes, so an empty one is a failure here rather than a green run
  against a moved tree.
  """

  use ExUnit.Case, async: true

  alias Cyfr.Test.{CodeLines, SourceTree}

  @inventory "docs/plans/sanctum-inventory.md"

  # The layers a dependency may point at. Sanctum may reach contracts and
  # Arca; Arca may reach contracts alone. Anything else is a row the
  # inventory must carry.
  @sanctum_allowed [:sanctum, :arca, :contracts, :elsewhere]
  @arca_allowed [:arca, :contracts, :elsewhere]

  defp root, do: Path.expand("../../../..", __DIR__)

  defp inventory_source, do: SourceTree.read(Path.join(root(), @inventory))

  # --- the document ------------------------------------------------------

  # The body of one `## n. …` section, by the number that opens its heading.
  defp section(number) do
    inventory_source()
    |> String.split(~r/^## /m)
    |> Enum.find(&String.starts_with?(&1, "#{number}. "))
    |> case do
      nil -> flunk("#{@inventory} has no section #{number}")
      body -> body
    end
  end

  # Every backticked module name in a section, as a MapSet of strings.
  # `Sanctum.Context.*` and `Cyfr.Boot.id/0` both yield their module.
  defp listed_modules(number) do
    ~r/`([A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)/
    |> Regex.scan(section(number))
    |> Enum.map(fn [_, mod] -> mod end)
    |> MapSet.new()
  end

  # A scanned module is listed when the section names it or any prefix of
  # it: listing `Compendium.Registry` covers `Compendium.Registry.Client`.
  defp listed?(listed, module) do
    module
    |> String.split(".")
    |> Enum.scan(&"#{&2}.#{&1}")
    |> Enum.any?(&MapSet.member?(listed, &1))
  end

  # --- the layers --------------------------------------------------------

  defp contracts_modules do
    :cyfr_contracts
    |> Application.app_dir("ebin")
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.map(&module_name/1)
    |> MapSet.new()
  end

  # `.../Elixir.Cyfr.JCS.beam` is the module `Cyfr.JCS`. An Erlang module's
  # beam carries no prefix and yields its own name, which no layer claims.
  defp module_name(path) do
    path |> Path.basename(".beam") |> String.replace_prefix("Elixir.", "")
  end

  defp layer(module, contracts) do
    cond do
      MapSet.member?(contracts, module) -> :contracts
      String.starts_with?(module, "Sanctum.") or module == "Sanctum" -> :sanctum
      String.starts_with?(module, "Arca.") or module == "Arca" -> :arca
      String.starts_with?(module, "Aqua.") -> :above
      String.starts_with?(module, "Compendium.") -> :above
      String.starts_with?(module, "Emissary") -> :above
      String.starts_with?(module, "Prism") -> :above
      String.starts_with?(module, "Cyfr.") or module == "Cyfr" -> :above
      true -> :elsewhere
    end
  end

  # --- the source scan ---------------------------------------------------

  @module ~r/\b((?:Sanctum|Arca|Aqua|Compendium|Emissary|EmissaryWeb|Prism|PrismWeb|Cyfr)(?:\.[A-Z][A-Za-z0-9_]*)*)/

  defp source_scan(globs) do
    contracts = contracts_modules()

    for glob <- List.wrap(globs),
        {path, source} <- SourceTree.sources(Path.join(root(), glob)),
        {line, number} <- CodeLines.code_lines(source),
        [_, module] <- Regex.scan(@module, line),
        uniq: true do
      {Path.relative_to(path, root()), number, module, layer(module, contracts)}
    end
  end

  # --- the compiled scan -------------------------------------------------

  # Every remote call the compiler emitted, read from each beam's import
  # table. `apply/3`, configured module names and compile-time evaluation
  # leave no entry here; the source scan carries those.
  defp compiled_scan(prefix) do
    contracts = contracts_modules()

    for path <- beams(),
        caller = module_name(path),
        caller == prefix or String.starts_with?(caller, prefix <> "."),
        production?(path),
        {:ok, {_mod, [imports: imports]}} =
          :beam_lib.chunks(String.to_charlist(path), [:imports]),
        {callee, function, arity} <- imports,
        callee = inspect(callee),
        callee != caller,
        uniq: true do
      {caller, callee, "#{function}/#{arity}", layer(callee, contracts)}
    end
  end

  # The test build compiles `test/support` into the same ebin. A support
  # module is not the app, and its reaches are the suite's, not Sanctum's.
  defp production?(path) do
    case :beam_lib.chunks(String.to_charlist(path), [:compile_info]) do
      {:ok, {_mod, [compile_info: info]}} ->
        info |> Keyword.get(:source, ~c"") |> to_string() |> String.contains?("/lib/")

      _ ->
        false
    end
  end

  defp beams do
    :cyfr
    |> Application.app_dir("ebin")
    |> Path.join("*.beam")
    |> Path.wildcard()
  end

  # --- the file assignment ----------------------------------------------

  # Section 6's rows as `{pattern, target}`, most specific first: a literal
  # path before a `/**` prefix, a longer prefix before a shorter one.
  defp assignment_rules do
    ~r/^\| `([^`]+)` \| ([A-Za-z0-9-]+) \|$/m
    |> Regex.scan(section(6))
    |> Enum.map(fn [_, pattern, target] -> {pattern, target} end)
    |> Enum.sort_by(fn {pattern, _} ->
      {String.ends_with?(pattern, "/**"), -String.length(pattern)}
    end)
  end

  defp matches?(pattern, path) do
    case String.split(pattern, "/**") do
      [^path] -> true
      [prefix, ""] -> String.starts_with?(path, prefix <> "/")
      _ -> false
    end
  end

  # Section 6's declared moves: a target that takes a file out of these two
  # directories leaves its row matching nothing, which is the row doing its
  # job rather than an obsolete entry. Only these are exempt from the
  # dead-row check.
  defp declared_moves do
    ~r/^\| `([^`]+)` \| ([A-Za-z0-9-]+) \| `[^`]+` \|$/m
    |> Regex.scan(section(6))
    |> Enum.map(fn [_, path, _target] -> path end)
    |> MapSet.new()
  end

  defp assigned_files do
    for glob <- ~w(apps/cyfr/lib/sanctum/**/*.ex apps/cyfr/lib/arca/**/*.ex
                   apps/cyfr/lib/arca.ex
                   apps/cyfr/test/sanctum/**/*.exs apps/cyfr/test/arca/**/*.exs),
        path <- SourceTree.files!(Path.join(root(), glob)) do
      Path.relative_to(path, root())
    end
  end

  # --- the scans are real ------------------------------------------------

  describe "the scans" do
    test "both read something" do
      assert length(source_scan("apps/cyfr/lib/sanctum/**/*.ex")) > 100
      assert length(source_scan("apps/cyfr/lib/arca/**/*.ex")) > 100
      assert length(compiled_scan("Sanctum")) > 100
      assert length(compiled_scan("Arca")) > 100
    end

    test "the compiled scan finds no edge the source scan missed" do
      contracts = contracts_modules()

      for {prefix, glob} <- [
            {"Sanctum", "apps/cyfr/lib/sanctum/**/*.ex"},
            {"Arca", "apps/cyfr/lib/arca/**/*.ex"}
          ] do
        named =
          glob
          |> source_scan()
          |> Enum.map(fn {_path, _line, module, _layer} -> module end)
          |> MapSet.new()

        missed =
          for {caller, callee, function, :above} <- compiled_scan(prefix),
              not listed?(named, callee),
              do: "#{caller} -> #{callee}.#{function}"

        assert missed == [],
               """
               The compiled scan found calls the source scan cannot see.
               Either the source regex is wrong or the call is built at
               runtime; #{@inventory} §0 records how the two reconcile.

               #{Enum.join(Enum.sort(missed), "\n")}
               """

        _ = contracts
      end
    end
  end

  # --- every dependency is listed ---------------------------------------

  describe "the inventory lists every dependency" do
    test "Sanctum's, outside sanctum -> cyfr_contracts, arca" do
      listed = listed_modules(2)

      unlisted =
        for {path, line, module, layer} <- source_scan("apps/cyfr/lib/sanctum/**/*.ex"),
            layer not in @sanctum_allowed,
            not listed?(listed, module),
            do: "#{path}:#{line} names #{module}"

      assert unlisted == [],
             """
             Sanctum reaches a module above itself that #{@inventory} §2
             does not list. `apps/sanctum` cannot compile against contracts
             and Arca until a target owns it, so add the row and name its
             target before the dependency lands.

             #{Enum.join(Enum.sort(unlisted), "\n")}
             """
    end

    test "Arca's, outside arca -> cyfr_contracts" do
      listed = listed_modules(3)

      unlisted =
        for {path, line, module, layer} <-
              source_scan(["apps/cyfr/lib/arca/**/*.ex", "apps/cyfr/lib/arca.ex"]),
            layer not in @arca_allowed,
            not listed?(listed, module),
            do: "#{path}:#{line} names #{module}"

      assert unlisted == [],
             """
             Arca reaches a module outside contracts that #{@inventory} §3
             does not list. Arca sits at the bottom of slice G's graph; a
             reach it does not declare is one nothing removes.

             #{Enum.join(Enum.sort(unlisted), "\n")}
             """
    end
  end

  # --- every file has exactly one owner ---------------------------------

  describe "the file assignment" do
    test "every file matches exactly one row" do
      rules = assignment_rules()
      assert rules != [], "#{@inventory} §6 has no assignment rows"

      unassigned =
        for path <- assigned_files(),
            not Enum.any?(rules, fn {pattern, _} -> matches?(pattern, path) end),
            do: path

      assert unassigned == [],
             """
             These files have no target in #{@inventory} §6. A file with no
             owner is a file two targets may both edit, which is what makes
             a wave stop being file-disjoint.

             #{Enum.join(Enum.sort(unassigned), "\n")}
             """
    end

    test "every row matches at least one file" do
      files = assigned_files()

      moved = declared_moves()

      dead =
        for {pattern, target} <- assignment_rules(),
            not MapSet.member?(moved, pattern),
            not Enum.any?(files, &matches?(pattern, &1)),
            do: "#{pattern} (#{target})"

      assert dead == [],
             """
             These rows of #{@inventory} §6 match no file. An exception list
             is exact: a row whose file was deleted must go with it, and a
             row whose file a target moved out of these directories must be
             declared under "Files a target removes" in the same section.

             #{Enum.join(Enum.sort(dead), "\n")}
             """
    end

    test "the most specific row wins, and it is the one the document means" do
      rules = assignment_rules()

      owner = fn path ->
        Enum.find_value(rules, fn {pattern, target} ->
          if matches?(pattern, path), do: target
        end)
      end

      assert owner.("apps/cyfr/lib/sanctum/tenancy/caps.ex") == "G9"
      assert owner.("apps/cyfr/lib/sanctum/tenancy/users.ex") == "G4"
      assert owner.("apps/cyfr/lib/sanctum/test_context.ex") == "G1"
      assert owner.("apps/cyfr/test/sanctum/establish_boundary_test.exs") == "G1"
      assert owner.("apps/cyfr/lib/arca/audit_handler.ex") == "G3"
      assert owner.("apps/cyfr/lib/arca/schemas/membership.ex") == "G3"
      assert owner.("apps/cyfr/lib/arca/schemas/thread.ex") == "G10-move"
      assert owner.("apps/cyfr/lib/arca/turn_storage.ex") == "G9"
    end
  end
end
