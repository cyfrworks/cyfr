# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.LiteralDriftTest do
  @moduledoc """
  Every operation a client spells as a literal exists in the catalog, and
  the CLI's generated names and argument structs are the catalog's.

  The CLI names the operations its built-in commands call through
  `apps/codex/internal/ops/catalog_gen.go`, rendered by `mix ops.gen.cli`
  from the catalog: a renamed or retired action fails `go build` there.
  This test refuses a checked-in render that is stale, so the build sees
  the catalog as it is. Argument fields and their presence are generated from the same
  declarations; renamed fields fail the Go build.

  The one library site that dispatches by name across an app boundary
  (the build host registering a compiled component) still spells a
  literal pair; that pair is checked against the catalog here. The catalog
  is the loaded one, so the run needs every provider app.
  """
  use ExUnit.Case, async: false

  @root Path.expand("../../../..", __DIR__)

  # `CallTool(<ctx>, "<tool>", map[string]any{ "action": "<x>"`, the map
  # literal on the same or the following line.
  @go_call ~r/CallTool\([^,]+,\s*"(\w+)",\s*map\[string\]any\{\s*"action":\s*"(\w+)"/

  # `call_external("<tool>", <ctx>, %{ "action" => "<x>"` in library code.
  @ex_call ~r/call_(?:external|in_chain)\("(\w+)",[^%]*%\{\s*"action"\s*=>\s*"(\w+)"/

  test "every literal tool.action in the CLI and the library is one the catalog serves" do
    served = MapSet.new(Grimoire.Catalog.tool_actions())

    go_pairs =
      for file <- Prima.Test.SourceTree.files!(Path.join(@root, "apps/codex/**/*.go")),
          not String.ends_with?(file, "_test.go"),
          [_, tool, action] <- Regex.scan(@go_call, File.read!(file)),
          do: {Path.relative_to(file, @root), "#{tool}.#{action}"}

    ex_pairs =
      for dir <- Prima.Test.SourceTree.app_libs(@root),
          file <- Prima.Test.SourceTree.files!(Path.join([@root, dir, "**/*.ex"])),
          [_, tool, action] <- Regex.scan(@ex_call, Prima.Test.SourceTree.read(file)),
          do: {Path.relative_to(file, @root), "#{tool}.#{action}"}

    pairs = go_pairs ++ ex_pairs

    assert ex_pairs != [],
           "no literal operation calls found — the regexes no longer match the sources"

    unknown = for {file, pair} <- pairs, not MapSet.member?(served, pair), do: "#{file}: #{pair}"

    assert unknown == [],
           """
           These literals name operations the catalog does not serve:

           #{Enum.join(Enum.sort(Enum.uniq(unknown)), "\n")}

           A renamed or retired action must take its callers with it.
           """
  end

  @generated "apps/codex/internal/ops/catalog_gen.go"

  test "the CLI's generated table is the catalog's, and a moved catalog is seen" do
    rendered = Mix.Tasks.Ops.Gen.Cli.render()
    file = File.read(Path.join(@root, @generated))

    assert Mix.Tasks.Ops.Gen.Cli.current?(file, rendered),
           "#{@generated} is stale — run `mix ops.gen.cli` and commit the file"

    # A catalog that lost an action, or the file that kept one, is drift.
    {:ok, text} = file
    [line | _] = Regex.run(~r/^\t[A-Z]\w+ += "[a-z_]+"$/m, text)
    planted = String.replace(text, line <> "\n", "", global: false)
    refute Mix.Tasks.Ops.Gen.Cli.current?({:ok, planted}, rendered)
    refute Mix.Tasks.Ops.Gen.Cli.current?({:error, :enoent}, rendered)
  end
end
