# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.LiteralDriftTest do
  @moduledoc """
  Every operation a client spells as a literal exists in the catalog.

  The CLI names the operations it calls as string pairs (`CallTool(ctx,
  "webhook", map[string]any{"action": "get", …})`), and so does the one
  library site that dispatches by name across an app boundary (the build
  host registering a compiled component). Neither can compile against the
  catalog, so this is the binding: a renamed or retired action fails here,
  naming the file, before a person finds the dead command.

  Only literal pairs are read — a call whose arguments are a variable is
  bound by its own test. The catalog is the loaded one, so the run needs
  every provider app.
  """
  use ExUnit.Case, async: false

  @moduletag :requires_opus_modules

  @root Path.expand("../../../../..", __DIR__)

  # `CallTool(<ctx>, "<tool>", map[string]any{ "action": "<x>"`, the map
  # literal on the same or the following line.
  @go_call ~r/CallTool\([^,]+,\s*"(\w+)",\s*map\[string\]any\{\s*"action":\s*"(\w+)"/

  # `call_external("<tool>", <ctx>, %{ "action" => "<x>"` in library code.
  @ex_call ~r/call_(?:external|in_chain)\("(\w+)",[^%]*%\{\s*"action"\s*=>\s*"(\w+)"/

  test "every literal tool.action in the CLI and the library is one the catalog serves" do
    served = MapSet.new(Cyfr.Ops.Catalog.tool_actions())

    go_pairs =
      for file <- Path.wildcard(Path.join(@root, "apps/codex/**/*.go")),
          not String.ends_with?(file, "_test.go"),
          [_, tool, action] <- Regex.scan(@go_call, File.read!(file)),
          do: {Path.relative_to(file, @root), "#{tool}.#{action}"}

    ex_pairs =
      for dir <- ~w(apps/cyfr/lib apps/opus/lib apps/locus/lib),
          file <- Path.wildcard(Path.join([@root, dir, "**/*.ex"])),
          [_, tool, action] <- Regex.scan(@ex_call, Cyfr.Test.SourceTree.read(file)),
          do: {Path.relative_to(file, @root), "#{tool}.#{action}"}

    pairs = go_pairs ++ ex_pairs

    assert pairs != [],
           "no literal operation calls found — the regexes no longer match the sources"

    unknown = for {file, pair} <- pairs, not MapSet.member?(served, pair), do: "#{file}: #{pair}"

    assert unknown == [],
           """
           These literals name operations the catalog does not serve:

           #{Enum.join(Enum.sort(Enum.uniq(unknown)), "\n")}

           A renamed or retired action must take its callers with it.
           """
  end
end
