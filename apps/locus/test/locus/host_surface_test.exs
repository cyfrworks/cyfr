# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.HostSurfaceTest do
  @moduledoc """
  What locus reaches for in cyfr, written down.

  Checks the builder release’s runtime isolation. It loads cyfr with
  runtime: false; its standalone path may use only pure cyfr modules.
  Locus.MCP runs in the server and has separate dependencies. The shared
  contracts (`apps/cyfr_contracts`) are not cyfr and are not counted.

  Opus, Arca and Compendium each have a rostered surface for the same
  reason.

  Each entry says what it is and, where it matters, whether it needs a
  *started* cyfr — because that is the distinction the builder release
  depends on.
  """
  use ExUnit.Case, async: true

  @surface [
    # ——— Build plane: pure, and safe in the builder release ———
    # The Cargo.toml template, delegated here rather than forked.
    "Compendium.Scaffold",
    # The log-metadata roster — shared phrasing, not capability.
    "Cyfr.LoggerContext",
    # The builder client's outbound HTTP, classified separately from the
    # pinned OCI path because it talks to an operator-configured sibling.
    "Cyfr.Network",
    # The operation catalog: an in-chain tool call is dispatched through it.
    "Cyfr.Ops",
    # Whether this server builds at all (`CYFR_BUILDS`): an application-env
    # read, answered by a loaded cyfr as well as a started one.
    "Cyfr.RuntimeConfig",

    # ——— Product plane: `Locus.MCP` only, and needs a STARTED cyfr ———
    # These are why the builder release must never route MCP traffic: each
    # wants a running repo, cache or registry. `mix.exs`'s `runtime: false`
    # means OTP will not start cyfr for us, so anything below is reachable
    # only in the full release where cyfr is already up.
    "Arca",
    "Arca.Overlay",
    "Arca.Storage",
    "Compendium.AutoIndexer",
    "Compendium.ComponentPath",
    "Compendium.NamespacePolicy",
    "Compendium.Resolver",
    "Cyfr.BuildRecords",
    "Cyfr.RateLimiter",
    "Cyfr.Bus",
    "Emissary.MCP",
    "Emissary.PubSub",
    "Sanctum.Context"
  ]

  @namespace ~r/\b((?:Arca|Sanctum|Compendium|Emissary|Prism|Cyfr)(?:\.[A-Z]\w+)*)\b/

  defp root, do: Path.expand("../../../..", __DIR__)

  # The shared contracts are not cyfr: their modules are named where they
  # are defined, and a reach into them is not a reach into the control plane.
  defp contracts do
    modules =
      for path <- Path.wildcard(Path.join(root(), "apps/cyfr_contracts/lib/**/*.ex")),
          [_, module] <- Regex.scan(~r/^defmodule ([A-Z][\w.]*)/m, File.read!(path)),
          into: MapSet.new(),
          do: module

    if MapSet.size(modules) == 0, do: raise("no modules found under apps/cyfr_contracts/lib")
    modules
  end

  # A reach counts unless it names a contracts module exactly, so a cyfr
  # module that shares a contracts module's namespace is still counted.
  defp reached do
    contracts = contracts()

    for path <- Path.wildcard(Path.join(root(), "apps/locus/lib/**/*.ex")),
        line <- path |> File.read!() |> Cyfr.Test.CodeLines.lines(),
        [_, module] <- Regex.scan(@namespace, line),
        not MapSet.member?(contracts, module),
        into: MapSet.new(),
        do: module |> String.split(".") |> Enum.take(2) |> Enum.join(".")
  end

  test "locus reaches only into the namespaces this surface names" do
    extra = reached() |> MapSet.difference(MapSet.new(@surface)) |> Enum.sort()

    assert extra == [],
           """
           locus reaches into cyfr namespaces this surface does not name:

           #{Enum.map_join(extra, "\n", &"  #{&1}")}

           Add each with a line saying what it is for, and whether it needs a
           STARTED cyfr — the builder release loads cyfr without starting it
           (`{:cyfr, runtime: false}`), so a new reach into running state is
           a reach the builder cannot satisfy.
           """
  end

  test "the surface names nothing locus has stopped reaching for" do
    stale = MapSet.difference(MapSet.new(@surface), reached()) |> Enum.sort()

    assert stale == [],
           """
           This surface names namespaces locus no longer reaches:

           #{Enum.map_join(stale, "\n", &"  #{&1}")}

           Remove them — a roster wider than the code overstates the coupling
           it exists to describe.
           """
  end
end
