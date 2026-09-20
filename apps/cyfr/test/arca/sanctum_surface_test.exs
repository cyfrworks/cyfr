# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SanctumSurfaceTest do
  @moduledoc """
  What the storage layer actually needs from the auth domain, written down.

  Sanctum→Arca is ordinary layering (the auth domain persists through the
  storage layer). Arca→Sanctum is the arrow pointing BACK UP — a real,
  deliberate cycle (`Sanctum.Context` is the tenancy carrier every write
  stamps; the cipher seals what storage holds) that also spans the license
  boundary: `lib/arca` is Apache-2.0, `lib/sanctum` is FSL. Nothing
  guarded it, so it could only widen silently.

  Same shape as `Opus.HostSurfaceTest`: the roster is pinned in both
  directions. A new Arca→Sanctum reach fails here until someone decides it
  belongs on the list; a namespace Arca stops reaching into must leave it.
  """

  use ExUnit.Case, async: true

  # The Sanctum namespaces lib/arca reaches into IN CODE (doc prose
  # mentions many more — the filter below is what keeps this list honest),
  # and why each is here. Much narrower than it reads from a raw grep.
  #
  # What was vocabulary is gone rather than forgotten: the tenancy scope
  # list and the webhook signature header's default are shapes two sides
  # agree on, so they live in the contracts (`Cyfr.TenancyScope`,
  # `Cyfr.Webhook`) and the storage layer reads them there, while the auth
  # domain keeps its names over the same declaration. What is left is the
  # tenancy carrier alone.
  @surface [
    # The tenancy carrier and its resolution — the reason the cycle
    # exists at all: every scoped read and stamped write names it.
    "Sanctum.Context",
    "Sanctum.Tenancy"
  ]

  @namespace ~r/\bSanctum(?:\.[A-Z]\w+)+\b/

  defp root, do: Path.expand("../../../..", __DIR__)

  defp reached do
    for path <- Cyfr.Test.SourceTree.files!(Path.join(root(), "apps/cyfr/lib/arca/**/*.ex")),
        line <- path |> Cyfr.Test.SourceTree.read() |> Cyfr.Test.CodeLines.lines(),
        [module] <- Regex.scan(@namespace, line, capture: :first),
        into: MapSet.new(),
        do: module |> String.split(".") |> Enum.take(2) |> Enum.join(".")
  end

  test "the storage layer reaches only into the Sanctum namespaces this surface names" do
    extra = reached() |> MapSet.difference(MapSet.new(@surface)) |> Enum.sort()

    assert extra == [],
           """
           lib/arca reaches into Sanctum namespaces this surface does not name:

           #{Enum.map_join(extra, "\n", &"  #{&1}")}

           This cycle spans the license boundary (Apache-2.0 storage calling
           the FSL auth domain), so it widens only by decision: add the
           namespace with a line saying why the storage layer needs it, or
           move the shared piece to the glue namespace (`Cyfr.`).
           """
  end

  test "the surface names nothing the storage layer has stopped reaching into" do
    stale = MapSet.new(@surface) |> MapSet.difference(reached()) |> Enum.sort()

    assert stale == [],
           "the surface names Sanctum namespaces lib/arca no longer uses: #{inspect(stale)}"
  end
end
