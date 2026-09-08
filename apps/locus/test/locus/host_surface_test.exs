# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.HostSurfaceTest do
  @moduledoc """
  What locus reaches for in cyfr, written down.

  `apps/locus/mix.exs` declares `{:cyfr, runtime: false}` — the builder
  release loads cyfr for its pure modules and never starts it. That is a
  real isolation property, and it was held by a comment: nothing checked
  which cyfr modules locus actually names, and `Locus.MCP` names several
  that need cyfr *running* (`Arca.put`, `Cyfr.RateLimiter.check`,
  `Compendium.AutoIndexer.scan`). The convention was that the MCP module
  never runs in the builder; a convention is not a guard.

  Opus, Arca and Compendium each have a rostered surface for the same
  reason. This is the one that was missing.

  Each entry says what it is and, where it matters, whether it needs a
  *started* cyfr — because that is the distinction the builder release
  depends on.
  """
  use ExUnit.Case, async: true

  @surface [
    # ——— Build plane: pure, and safe in the builder release ———
    # The host ABI, compile-embedded (`Compendium.WITSource`) rather than
    # read from disk, so the sandbox is written from the release's own
    # bytes. The Cargo.toml template is delegated here rather than forked.
    "Compendium.Scaffold",
    "Compendium.WITSource",
    # Artifact validation before anything is stored: the WASM component
    # shape, and the tincture bundle's.
    "Compendium.WasmValidator",
    # Path grammar for source files written into the build sandbox — the
    # denylist Arca shares, applied before any file is created.
    "Cyfr.PathSafety",
    # Content addressing for build outputs.
    "Cyfr.Digest",
    # Reference and limit vocabulary the build request speaks.
    "Sanctum.ComponentRef",
    "Sanctum.Limits",
    # The log-metadata roster and the unexpected-message spelling — shared
    # phrasing, not capability.
    "Cyfr.LoggerContext",
    "Cyfr.UnexpectedMessage",
    "Cyfr.UUID7",
    # The short-hex mint for scratch-dir labels — pure, like UUID7.
    "Cyfr.Hex",
    # The builder client's outbound HTTP, classified separately from the
    # pinned OCI path because it talks to an operator-configured sibling.
    "Cyfr.Network",
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
    "Cyfr.Topics",
    "Emissary.MCP",
    "Emissary.PubSub",
    "Sanctum.Context"
  ]

  @namespace ~r/\b((?:Arca|Sanctum|Compendium|Emissary|Prism|Cyfr)(?:\.[A-Z]\w+)*)\b/

  defp root, do: Path.expand("../../../..", __DIR__)

  defp reached do
    for path <- Path.wildcard(Path.join(root(), "apps/locus/lib/**/*.ex")),
        line <- path |> File.read!() |> Cyfr.Test.CodeLines.lines(),
        [_, module] <- Regex.scan(@namespace, line),
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
