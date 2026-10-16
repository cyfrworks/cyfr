# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Gate.LiteralDriftTest do
  @moduledoc """
  Every operation the library spells as a literal exists in the catalog,
  and the CLI's generated names, argument structs and rosters are the
  catalog's and their owners'.

  The CLI names the operations its built-in commands call through
  `apps/codex/internal/ops/catalog_gen.go`, rendered by `mix ops.gen.cli`
  from the catalog: a renamed or retired action fails `go build` there.
  This test refuses a checked-in render that is stale, so the build sees
  the catalog as it is. Argument fields and their presence are generated from the same
  declarations; renamed fields fail the Go build. The credential kinds and
  the sign-in providers the CLI reads are rendered into the same file from
  `Prima.CredentialKinds` and Sanctum's rosters, so a roster that moves
  makes the render stale.

  The one library site that dispatches by name across an app boundary
  (the build host registering a compiled component) still spells a
  literal pair; that pair is checked against the catalog here. The catalog
  is the loaded one, so the run needs every provider app.
  """
  use ExUnit.Case, async: false

  @root Path.expand("../../../../..", __DIR__)

  # `call_external("<tool>", <ctx>, %{ "action" => "<x>"` in library code.
  @ex_call ~r/call_(?:external|in_chain)\("(\w+)",[^%]*%\{\s*"action"\s*=>\s*"(\w+)"/

  test "every literal tool.action in the library is one the catalog serves" do
    served = MapSet.new(Sanctum.Catalog.tool_actions())

    ex_pairs =
      for dir <- Prima.Test.SourceTree.app_libs(@root),
          file <- Prima.Test.SourceTree.files!(Path.join([@root, dir, "**/*.ex"])),
          [_, tool, action] <- Regex.scan(@ex_call, Prima.Test.SourceTree.read(file)),
          do: {Path.relative_to(file, @root), "#{tool}.#{action}"}

    assert ex_pairs != [],
           "no literal operation calls found — the regexes no longer match the sources"

    unknown =
      for {file, pair} <- ex_pairs, not MapSet.member?(served, pair), do: "#{file}: #{pair}"

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

    # Each roster is in the file as its owner reads, and an owner that
    # moved, against the file that kept the old list, is drift.
    operations = Mix.Tasks.Ops.Gen.Cli.operations()
    rosters = Mix.Tasks.Ops.Gen.Cli.rosters()
    assert length(rosters) == 4

    for {name, comment, [_ | _] = values} <- rosters do
      assert text =~ "var #{name} = []string{#{Enum.map_join(values, ", ", &~s("#{&1}"))}}"

      moved = List.keyreplace(rosters, name, 0, {name, comment, Enum.drop(values, -1)})

      refute Mix.Tasks.Ops.Gen.Cli.current?(
               file,
               Mix.Tasks.Ops.Gen.Cli.render(operations, moved)
             ),
             "a moved #{name} is not seen"
    end
  end
end
