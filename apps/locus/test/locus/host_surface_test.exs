# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.HostSurfaceTest do
  @moduledoc """
  What locus reaches for in cyfr, written down.

  Checks the builder release’s runtime isolation. It loads cyfr with
  runtime: false; its standalone path reaches no cyfr module, only the
  shared contracts (`apps/cyfr_contracts`), which are not cyfr and are not
  counted. Locus.MCP runs in the server and has separate dependencies.

  Opus, Arca and Compendium each have a rostered surface for the same
  reason.

  Each entry says what it is and, where it matters, whether it needs a
  *started* cyfr — because that is the distinction the builder release
  depends on.
  """
  use ExUnit.Case, async: true

  @surface [
    # ——— Build plane: nothing ———
    # Every module but `Locus.MCP` reaches only the contracts, so the
    # builder release runs no cyfr code.

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
    # The operation catalog: `Locus.MCP` is a provider, and a compiled
    # component is registered through it.
    "Cyfr.Ops",
    "Cyfr.RateLimiter",
    # Whether this server builds at all (`CYFR_BUILDS`): an application-env
    # read, answered by a loaded cyfr as well as a started one.
    "Cyfr.RuntimeConfig",
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
      for path <-
            Cyfr.Test.SourceTree.files!(Path.join(root(), "apps/cyfr_contracts/lib/**/*.ex")),
          module <- defined_modules(File.read!(path)),
          into: MapSet.new(),
          do: module

    if MapSet.size(modules) == 0, do: raise("no modules found under apps/cyfr_contracts/lib")
    modules
  end

  # Every `defmodule` in formatted source, a nested one named under the
  # module enclosing it (`Outer.Inner`): each level indents two spaces.
  defp defined_modules(source) do
    source
    |> Cyfr.Test.CodeLines.lines()
    |> Enum.flat_map(&Regex.scan(~r/^((?:  )*)defmodule ([A-Z][\w.]*) do/, &1))
    |> Enum.map_reduce([], fn [_, indent, name], enclosing ->
      path = Enum.take(enclosing, div(byte_size(indent), 2)) ++ [name]
      {Enum.join(path, "."), path}
    end)
    |> elem(0)
  end

  # A reach counts unless it names a contracts module exactly, so a cyfr
  # module that shares a contracts module's namespace is still counted.
  defp reached do
    contracts = contracts()

    for path <- Cyfr.Test.SourceTree.files!(Path.join(root(), "apps/locus/lib/**/*.ex")),
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
