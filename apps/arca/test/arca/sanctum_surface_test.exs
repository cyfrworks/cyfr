# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SanctumSurfaceTest do
  @moduledoc """
  What the storage layer actually needs from the auth domain, written down.

  Sanctum→Arca is ordinary layering (the auth domain persists through the
  storage layer). Arca→Sanctum would point BACK UP — a cycle that also
  spans the license boundary, `lib/arca` being Apache-2.0 and
  `lib/sanctum` FSL. The roster below is empty, and this test keeps it
  that way.

  Same shape as the island rosters in `Cyfr.Boundaries`: pinned in both
  directions. A new Arca→Sanctum reach fails here until someone decides it
  belongs on the list; a namespace Arca stops reaching into must leave it.
  With an empty roster the first half is the whole test.
  """

  use ExUnit.Case, async: true

  # The Sanctum namespaces lib/arca reaches into IN CODE (doc prose
  # mentions many more — the filter below is what keeps this list honest).
  # It is empty: the storage layer has no arrow back up.
  #
  # What the two sides share lives in the contracts: the tenancy scope
  # list and the webhook signature header's default are read from
  # `Prima.TenancyScope` and `Prima.Webhook`, while the auth domain keeps
  # its names over the same declaration. Every facade takes the
  # `%Prima.Actor{}` the context projects, the caps are asked through
  # `Prima.Caps`, and the server's own work carries `Prima.Actor.system/0`.
  @surface []

  @namespace ~r/\bSanctum(?:\.[A-Z]\w+)+\b/

  defp root, do: Path.expand("../../../..", __DIR__)

  defp reached do
    for path <- Prima.Test.SourceTree.files!(Path.join(root(), "apps/arca/lib/arca/**/*.ex")),
        line <- path |> Prima.Test.SourceTree.read() |> Prima.Test.CodeLines.lines(),
        [module] <- Regex.scan(@namespace, line, capture: :first),
        into: MapSet.new(),
        do: module |> String.split(".") |> Enum.take(2) |> Enum.join(".")
  end

  test "the storage layer reaches only into the Sanctum namespaces this surface names" do
    # The roster is empty, so a scan that read nothing would pass this case
    # having checked nothing. The same reader, over the same tree, has to
    # come back with code.
    read =
      for path <- Prima.Test.SourceTree.files!(Path.join(root(), "apps/arca/lib/arca/**/*.ex")),
          line <- path |> Prima.Test.SourceTree.read() |> Prima.Test.CodeLines.lines(),
          do: line

    assert length(read) > 100, "the scan read no code line under lib/arca — it is not reading"

    extra = reached() |> MapSet.difference(MapSet.new(@surface)) |> Enum.sort()

    assert extra == [],
           """
           lib/arca reaches into Sanctum namespaces this surface does not name:

           #{Enum.map_join(extra, "\n", &"  #{&1}")}

           This cycle spans the license boundary (Apache-2.0 storage calling
           the FSL auth domain), so it widens only by decision: add the
           namespace with a line saying why the storage layer needs it, or
           move the shared piece to Prima (`Prima.`).
           """
  end

  test "the surface names only Sanctum namespaces the storage layer reaches into" do
    stale = MapSet.new(@surface) |> MapSet.difference(reached()) |> Enum.sort()

    assert stale == [],
           "the surface names Sanctum namespaces lib/arca does not use: #{inspect(stale)}"
  end
end
