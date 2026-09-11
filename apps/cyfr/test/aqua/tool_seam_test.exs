# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ToolSeamTest do
  @moduledoc """
  `Aqua.Ops` is the assistant plane's seam onto the MCP tool
  surface — the same contract `PrismWeb.ToolSeamTest` pins for the
  console.

  Checks that assistant-domain MCP dependencies use Aqua.Ops.

  Outside its scope, deliberately: `Emissary.PubSub` used as a process
  NAME (the application's one supervised PubSub, the posture
  `Cyfr.EmissarySurfaceTest` rosters for sanctum), and `Aqua.Intents`'
  read of the console route table, rostered in
  `Cyfr.NamespaceDirectionTest`.
  """

  use ExUnit.Case, async: true

  @seam "apps/cyfr/lib/aqua/ops.ex"

  defp root, do: Path.expand("../../../..", __DIR__)

  test "the assistant reaches the tool surface only through its seam" do
    offenders =
      for path <- Path.wildcard(Path.join(root(), "apps/cyfr/lib/aqua/**/*.ex")),
          rel = Path.relative_to(path, root()),
          rel != @seam,
          {line, n} <- path |> Cyfr.Test.SourceTree.read() |> Cyfr.Test.CodeLines.code_lines(),
          String.contains?(line, "Emissary.MCP."),
          do: "#{rel}:#{n}: #{String.trim(line)}"

    assert offenders == [],
           "aqua reaches Emissary.MCP past its seam — go through Aqua.Ops " <>
             "(or grow the helper), never the registry directly:\n" <>
             Enum.join(offenders, "\n")
  end
end
