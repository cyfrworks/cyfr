# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.EmissarySurfaceTest do
  @moduledoc """
  The auth domain's reach into the transport, written down.

  The roster is **empty**, and is held to be: a foundation below the host
  emits `:telemetry` and never broadcasts, so the PubSub server's own
  name — the last thing `lib/sanctum` knew about the transport — is the
  host bridge's now. Consent reaches the operation catalog and its
  external tool servers through the `Sanctum.Catalog` port, and the
  catalog lives under `Cyfr.Ops` rather than in Emissary.

  An empty roster only means something while the scan still reads, so
  the case below asserts that too, against a namespace `lib/sanctum` does
  reach.
  """

  use ExUnit.Case, async: true

  @surface []

  @namespace ~r/\bEmissary(?:\.[A-Z]\w+)+\b/

  defp root, do: Path.expand("../../../..", __DIR__)

  defp reached do
    for path <- Cyfr.Test.SourceTree.files!(Path.join(root(), "apps/sanctum/lib/sanctum/**/*.ex")),
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
    # The roster is empty, so a scan that read nothing would pass this
    # case having checked nothing. The same reader, over the same tree,
    # has to come back with code.
    lines =
      for path <-
            Cyfr.Test.SourceTree.files!(Path.join(root(), "apps/sanctum/lib/sanctum/**/*.ex")),
          line <- path |> Cyfr.Test.SourceTree.read() |> Cyfr.Test.CodeLines.lines(),
          do: line

    assert length(lines) > 100, "the scan read no code line under lib/sanctum — it is not reading"

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
