# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.WebDirectionTest do
  @moduledoc """
  One web layer, one direction: `emissary_web` owns the endpoint and the
  router and MAY name `prism_web` (mounting its LiveViews, layouts and
  on_mount hooks is the composition root's job); `prism_web` — the console
  — must not name `emissary_web` back.

  `Cyfr.NamespaceDirectionTest` deliberately scopes the two web namespaces
  out, so this crossing had no guard and carried five back-edges:
  `SafeRedirect` (now a prism_web module — its only callers were console
  flows) and the tincture rate-limit knobs (now `Cyfr.RuntimeConfig`).
  The one deliberate exception is the endpoint itself: there is exactly one
  (`EmissaryWeb.Endpoint`), and building the public URL for a copy-link is
  reading a global fact, not reaching into the transport.
  """

  use ExUnit.Case, async: true

  @allowed ~w(EmissaryWeb.Endpoint)

  @namespace ~r/\bEmissaryWeb(?:\.[A-Z]\w+)*\b/

  defp root, do: Path.expand("../../../..", __DIR__)

  defp reached do
    for path <- Path.wildcard(Path.join(root(), "apps/cyfr/lib/prism_web/**/*.ex")),
        line <- path |> Cyfr.Test.SourceTree.read() |> Cyfr.Test.CodeLines.lines(),
        [module] <- Regex.scan(@namespace, line, capture: :first),
        into: MapSet.new() do
      module |> String.split(".") |> Enum.take(2) |> Enum.join(".")
    end
  end

  test "prism_web names nothing in emissary_web beyond the endpoint" do
    extra =
      reached()
      |> MapSet.difference(MapSet.new(@allowed))
      |> Enum.sort()

    assert extra == [],
           """
           lib/prism_web reaches into emissary_web:

           #{Enum.map_join(extra, "\n", &"  #{&1}")}

           The console depends on the transport in one direction only.
           Move the shared piece to prism_web (if only the console uses it)
           or to the glue namespace (Cyfr.) — see SafeRedirect and the
           tincture rate-limit knobs for the two precedents.
           """
  end
end
