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
  Compendium. Its roster is now **empty**, and is held to be — the one
  call that had slipped back past the locators read the `source` roster,
  which is a vocabulary two sides agree on and lives in the contracts
  (`Cyfr.ComponentSource`). An empty roster only means something while
  the scan still reads, so the case below asserts that too.

  `lib/sanctum` crossed the license boundary (FSL calling Apache-2.0) and
  its roster is **empty** too. Everything consent reads about a component
  comes through the `Sanctum.Consent.Components` port, and every shape the
  two domains agree on — a manifest's `needs` and `caps` blocks, the
  component path, an activation node key, a name's newest row, an agent
  ref — lives in the contracts. The last reach was the probe of cyfr.run
  at first sign-in, which could not be handed a resolved value because the
  IdP access token *is* its input and the token must not travel past the
  door. It moved the other way instead: `Compendium.SignInSync` holds the
  probe and reaches down into `Sanctum.SignIn.record_namespace/2`, the web
  callback (a surface above the domain) calls it, and the CLI device flow
  skips it rather than handing its token up.

  Both rosters being empty is the point, and it is also what makes the
  canary below load-bearing: with nothing left to find in either
  directory, a scan that silently stopped reading would pass both cases
  having checked nothing. So it anchors on `lib/cyfr`, the host, whose
  reach into the component domain is ordinary downward layering and is
  not going away.
  """

  use ExUnit.Case, async: true

  # lib/arca → Compendium, in code. Empty: everything lib/arca says about
  # the component domain is prose. The closed `source` roster the row
  # store enforces on write (`Arca.ComponentStorage.validate_source!/1`)
  # was the one code edge, and it is `Cyfr.ComponentSource` now —
  # `Compendium.Source` keeps its name and reads the same declaration.
  @arca_surface []

  # lib/sanctum → Compendium, in code. Empty: the auth domain names
  # nothing in the component domain. The sign-in probe was the last one
  # and it is `Compendium.SignInSync` now, calling down.
  @sanctum_surface []

  # Where the scan is proved to read. The host reaches the component
  # domain as a matter of ordinary layering, so this is non-empty for a
  # structural reason rather than by accident — which is what a canary
  # needs to be.
  @canary "apps/cyfr/lib/cyfr/**/*.ex"

  @namespace ~r/\bCompendium(?:\.[A-Z]\w+)+\b/

  defp root, do: Path.expand("../../../..", __DIR__)

  defp reached(glob) do
    for path <- Cyfr.Test.SourceTree.files!(Path.join(root(), glob)),
        line <- path |> Cyfr.Test.SourceTree.read() |> Cyfr.Test.CodeLines.lines(),
        [module] <- Regex.scan(@namespace, line, capture: :first),
        into: MapSet.new(),
        do: module |> String.split(".") |> Enum.take(2) |> Enum.join(".")
  end

  test "the storage layer reaches only into the Compendium namespaces this surface names" do
    # Both rosters are empty, so a scan that read nothing would pass every
    # case here having checked nothing. The same scan over the host finds
    # its ordinary downward reaches, which is what says the scan works.
    assert MapSet.size(reached(@canary)) > 0,
           "the scan read no Compendium reach anywhere — it is not reading"

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
