# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.LayerIndependenceTest do
  @moduledoc """
  The two lower applications name nothing above themselves.

  `arca` depends on the shared contracts alone and `sanctum` on the
  contracts and Arca, which their own builds prove by failing to compile
  (`test.yml`'s `arca-independence` and `sanctum-independence`). This is
  the same boundary read from inside the umbrella, where a reach lands
  first: the independence jobs run on their own checkouts, so a crossing
  introduced here is green until one of them runs.

  Two scans, because neither sees everything:

    * the **source scan**, through `Cyfr.Test.CodeLines` — the filter every
      architecture roster uses — sees aliases, struct patterns, typespecs
      and compile-time attributes, which emit no call;
    * the **compiled scan**, the import table of each `.beam`, sees every
      remote call the compiler emitted, including ones spelled in a way a
      regex would miss. `apply/3`, a configured module name and anything
      evaluated at compile time leave no entry there, which is why the
      source scan runs beside it.

  Both must be non-empty. A scan that reads nothing passes every assertion
  it makes, so an empty one is a failure here rather than a green run
  against a moved tree.

  This replaces the drift check against `docs/plans/sanctum-inventory.md`,
  which described the tree slice G moved and the target that owned each
  file of it. The move is done: every file of both directories is in its
  own application now, so every row of that document's file assignment
  names a path that no longer exists, and what the document was for — no
  edge lands that no target closes — is what the two builds now answer.
  """

  use ExUnit.Case, async: true

  alias Cyfr.Test.{CodeLines, SourceTree}

  # The layers a dependency may point at. Sanctum may reach contracts and
  # Arca; Arca may reach contracts alone.
  @sanctum_allowed [:sanctum, :arca, :contracts, :elsewhere]
  @arca_allowed [:arca, :contracts, :elsewhere]

  @arca_lib "apps/arca/lib/**/*.ex"
  @sanctum_lib "apps/sanctum/lib/**/*.ex"

  defp root, do: Path.expand("../../../..", __DIR__)

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
  # table.
  defp compiled_scan(app, prefix) do
    contracts = contracts_modules()

    for path <- beams(app),
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
  # module is not the app, and its reaches are the suite's.
  defp production?(path) do
    case :beam_lib.chunks(String.to_charlist(path), [:compile_info]) do
      {:ok, {_mod, [compile_info: info]}} ->
        info |> Keyword.get(:source, ~c"") |> to_string() |> String.contains?("/lib/")

      _ ->
        false
    end
  end

  defp beams(app) do
    app
    |> Application.app_dir("ebin")
    |> Path.join("*.beam")
    |> Path.wildcard()
  end

  # --- the scans are real ------------------------------------------------

  describe "the scans" do
    test "both read something" do
      assert length(source_scan(@sanctum_lib)) > 100
      assert length(source_scan(@arca_lib)) > 100
      assert length(compiled_scan(:sanctum, "Sanctum")) > 100
      assert length(compiled_scan(:arca, "Arca")) > 100
    end
  end

  # --- neither app names a layer above itself ----------------------------

  describe "the applications below the host" do
    test "sanctum names nothing outside sanctum -> cyfr_contracts, arca" do
      above =
        for {path, line, module, layer} <- source_scan(@sanctum_lib),
            layer not in @sanctum_allowed,
            do: "#{path}:#{line} names #{module}"

      compiled =
        for {caller, callee, function, :above} <- compiled_scan(:sanctum, "Sanctum"),
            do: "#{caller} -> #{callee}.#{function}"

      assert Enum.sort(above ++ compiled) == [],
             """
             Sanctum reaches a module above itself. `apps/sanctum` depends on
             the contracts and Arca alone, so this does not compile in its own
             build — either move what it needs down, or invert the reach.

             #{Enum.join(Enum.sort(above ++ compiled), "\n")}
             """
    end

    test "arca names nothing outside arca -> cyfr_contracts" do
      above =
        for {path, line, module, layer} <- source_scan(@arca_lib),
            layer not in @arca_allowed,
            do: "#{path}:#{line} names #{module}"

      compiled =
        for {caller, callee, function, layer} <- compiled_scan(:arca, "Arca"),
            layer not in @arca_allowed,
            do: "#{caller} -> #{callee}.#{function}"

      assert Enum.sort(above ++ compiled) == [],
             """
             Arca reaches a module outside the contracts. It sits at the
             bottom of the graph — `apps/arca` depends on the contracts alone,
             so this does not compile in its own build.

             #{Enum.join(Enum.sort(above ++ compiled), "\n")}
             """
    end
  end
end
