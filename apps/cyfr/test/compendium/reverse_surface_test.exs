# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ReverseSurfaceTest do
  @moduledoc """
  What reaches BACK UP into the component domain, written down.

  Compendium→Arca and Compendium→Sanctum are ordinary layering: the
  component domain persists through storage and authorizes through the auth
  domain. The two arrows here point the other way and nothing guarded them,
  so they could only widen silently — the same gap `Arca.SanctumSurfaceTest`
  and `Opus.HostSurfaceTest` close for their own directions.

  `lib/arca` is the sharper of the two: the overlay's locators were wired
  through config precisely so the storage layer would not compile against
  Compendium, and one call slipped back past that.

  `lib/sanctum` is the broader one, and it crosses the license boundary
  (FSL calling Apache-2.0). It is product-real — consent has to read live
  manifests — but it should widen by decision, not by accident.
  """

  use ExUnit.Case, async: true

  # lib/arca → Compendium, in code.
  @arca_surface [
    # The closed `source` roster the components row store enforces on write
    # (`Arca.ComponentStorage.validate_source!/1`). The vocabulary is the
    # component domain's — how a row's bytes arrived — and the row store is
    # what refuses anything outside it. The ONE code edge; everything else
    # Arca says about Compendium is prose.
    "Compendium.Source"
  ]

  # lib/sanctum → Compendium, in code.
  @sanctum_surface [
    # Consent is derived from what a component DECLARES, so the whole
    # plan/preview/commit path reads manifests, activation graphs and the
    # dependency edges a blob is built from.
    "Compendium.Activation",
    "Compendium.Component",
    "Compendium.ComponentPath",
    "Compendium.DependencyResolver",
    "Compendium.Manifest",
    "Compendium.Registry",
    "Compendium.Resolver",

    # Provisioning uses AutoIndexer and Pull for component scans and
    # dependency closure, and AgentIndex to derive the agent roster; the
    # consent bootstrap mints the estate's agents as sources (AgentSource).
    "Compendium.AgentIndex",
    "Compendium.AgentSource",
    "Compendium.AquaTemplate",
    "Compendium.AutoIndexer",
    "Compendium.Pull",

    # First sign-in talks to cyfr.run: the legal-acceptance refusal is an
    # OCI error the door has to read, and the registry host is where the
    # person's namespace is claimed.
    "Compendium.OCI",
    "Compendium.RegistryHost"
  ]

  @namespace ~r/\bCompendium(?:\.[A-Z]\w+)+\b/

  defp root, do: Path.expand("../../../..", __DIR__)

  defp reached(glob) do
    for path <- Path.wildcard(Path.join(root(), glob)),
        line <- path |> Cyfr.Test.SourceTree.read() |> Cyfr.Test.CodeLines.lines(),
        [module] <- Regex.scan(@namespace, line, capture: :first),
        into: MapSet.new(),
        do: module |> String.split(".") |> Enum.take(2) |> Enum.join(".")
  end

  test "the storage layer reaches only into the Compendium namespaces this surface names" do
    extra =
      "apps/cyfr/lib/arca/**/*.ex"
      |> reached()
      |> MapSet.difference(MapSet.new(@arca_surface))
      |> Enum.sort()

    assert extra == [],
           """
           lib/arca reaches into Compendium namespaces this surface does not name:

           #{Enum.map_join(extra, "\n", &"  #{&1}")}

           The overlay's locators were wired through config so the storage
           layer would not compile against the component domain. Add the
           namespace with a line saying why the row store needs it, or move
           the shared piece to the glue namespace (`Cyfr.`).
           """
  end

  test "the auth domain reaches only into the Compendium namespaces this surface names" do
    extra =
      "apps/cyfr/lib/sanctum/**/*.ex"
      |> reached()
      |> MapSet.difference(MapSet.new(@sanctum_surface))
      |> Enum.sort()

    assert extra == [],
           """
           lib/sanctum reaches into Compendium namespaces this surface does not name:

           #{Enum.map_join(extra, "\n", &"  #{&1}")}

           This crosses the license boundary (FSL calling Apache-2.0), so it
           widens by decision: add the namespace with a line saying what
           consent or provisioning needs from it.
           """
  end

  test "neither surface names something that is no longer reached" do
    for {label, glob, surface} <- [
          {"lib/arca", "apps/cyfr/lib/arca/**/*.ex", @arca_surface},
          {"lib/sanctum", "apps/cyfr/lib/sanctum/**/*.ex", @sanctum_surface}
        ] do
      stale = surface |> MapSet.new() |> MapSet.difference(reached(glob)) |> Enum.sort()

      assert stale == [],
             "the surface names Compendium namespaces #{label} no longer uses: #{inspect(stale)}"
    end
  end
end
