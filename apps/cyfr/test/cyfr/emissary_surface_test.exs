# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.EmissarySurfaceTest do
  @moduledoc """
  The auth domain's reach into the transport, written down.

  `Cyfr.SanctumSurfacesTest` pins every Apache namespace's reach INTO
  `lib/sanctum`; this is the reverse crossing — the one direction that had
  no guard. It matters twice over: `lib/sanctum` is the FSL security
  domain leaning on Apache transport internals, and the sharpest entry
  (consent shape derivation reading `ToolRegistry.available_providers/0`)
  makes what a consent can NAME depend on what the bus can SERVE. That
  dependency is deliberate — a shape must not name actions the registry
  cannot dispatch — but it widens only by decision, not by drift.

  The roster records today's reality, one reason per module. A new reach
  fails here until someone decides it belongs; a module Sanctum stops
  naming must leave the roster.
  """

  use ExUnit.Case, async: true

  @surface ~w(
    Emissary.MCP.ExternalProvider
    Emissary.PubSub
  )

  # Why each entry is on the roster (the operation catalog itself lives
  # under `Cyfr.Ops` now, so its modules are not Emissary's surface):
  #   ExternalProvider — consent candidates come from the live
  #     external-server plane.
  #   ToolError — the shared refusal renderer (one sentence per reason).
  #   ToolProvider — Sanctum.MCP implements the provider behaviour.
  #   Emissary.PubSub — the global PubSub server's process name (the
  #     vocabulary moved to Cyfr.Topics; the name did not).

  @namespace ~r/\bEmissary(?:\.[A-Z]\w+)+\b/

  defp root, do: Path.expand("../../../..", __DIR__)

  defp reached do
    for path <- Path.wildcard(Path.join(root(), "apps/cyfr/lib/sanctum/**/*.ex")),
        line <- path |> Cyfr.Test.SourceTree.read() |> Cyfr.Test.CodeLines.lines(),
        [module] <- Regex.scan(@namespace, line, capture: :first),
        into: MapSet.new() do
      case String.split(module, ".") do
        ["Emissary", "PubSub" | _] -> "Emissary.PubSub"
        parts -> parts |> Enum.take(3) |> Enum.join(".")
      end
    end
  end

  test "lib/sanctum reaches only the Emissary modules its surface names" do
    extra =
      reached()
      |> MapSet.difference(MapSet.new(@surface))
      |> Enum.sort()

    assert extra == [],
           """
           lib/sanctum reaches into Emissary modules its surface does not name:

           #{Enum.map_join(extra, "\n", &"  #{&1}")}

           The auth domain leaning on transport internals widens only by
           decision: add the module with a line saying why, or move the
           shared piece to the glue namespace (`Cyfr.`).
           """
  end

  test "the surface names nothing lib/sanctum has stopped reaching into" do
    stale =
      MapSet.new(@surface)
      |> MapSet.difference(reached())
      |> Enum.sort()

    assert stale == [],
           "stale surface entries (no longer reached): #{inspect(stale)}"
  end
end
