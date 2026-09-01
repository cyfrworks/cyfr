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

  Two deliberate exceptions, and the second is the wider one. Building the
  public URL for a copy-link reads a global fact off `EmissaryWeb.Endpoint`
  rather than reaching into the transport. And `PrismWeb.verified_routes/0`
  names the endpoint, the router AND `EmissaryWeb.static_paths/0`, because
  that is the triple `use Phoenix.VerifiedRoutes` takes — injected by
  `use PrismWeb, :live_view` into every console LiveView, which makes it the
  widest crossing here.

  This file's glob used to be `prism_web/**/*.ex`, which never matches the
  sibling root module `prism_web.ex` — so the three-name reach lived in the
  one file the guard could not see, and the paragraph above used to claim
  there was exactly one.
  """

  use ExUnit.Case, async: true

  @allowed ~w(EmissaryWeb EmissaryWeb.Endpoint EmissaryWeb.Router)

  @namespace ~r/\bEmissaryWeb(?:\.[A-Z]\w+)*\b/

  defp root, do: Path.expand("../../../..", __DIR__)

  # The namespace is a directory AND a sibling root module; `dir/**/*.ex`
  # matches only the first.
  defp sources do
    Path.wildcard(Path.join(root(), "apps/cyfr/lib/prism_web/**/*.ex")) ++
      Path.wildcard(Path.join(root(), "apps/cyfr/lib/prism_web.ex"))
  end

  defp reached do
    for path <- sources(),
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
