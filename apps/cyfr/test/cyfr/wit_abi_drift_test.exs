# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.WitAbiDriftTest do
  @moduledoc """
  The guest ABI is written down once, in `wit/`, and this test binds what
  still copies it by hand to it.

  `wit/` is the contract: `Prima.WIT` embeds it at compile time,
  `Locus.Builder` copies it into the build sandbox, and `Prima.CargoToml`
  points a generated `Cargo.toml` at it, so a component is compiled against
  those interface names. The runner's host side is generated from the same
  files (`bindgen!` in `apps/locus/runner/src/imports/mod.rs`), so its
  imports and the exports it calls cannot name an interface `wit/` lacks,
  and the registration gate's exports (`Prima.WIT.expected_exports/1`)
  come from the same world files. What is still spelled by hand is the
  catalyst scaffold's WIT dependency table.

  This is the same guard `Cyfr.CrossLanguageDriftTest` puts on the Go
  component-ref port and `Emissary.MCP.ClientProtocolDriftTest` puts on the
  protocol version: read both sources, and fail here rather than there.
  """

  use ExUnit.Case, async: true

  @wit_root Path.expand("../../../../wit", __DIR__)

  # What `wit/` actually declares: for each package, its version and the
  # interfaces defined in it — across the world files and their deps.
  defp wit_abi_names do
    @wit_root
    |> Path.join("**/*.wit")
    |> Prima.Test.SourceTree.files!()
    |> Enum.flat_map(fn path ->
      source = File.read!(path)

      with [[_, package, version]] <-
             Regex.scan(~r/package\s+(cyfr:[a-z]+)@(\d+\.\d+\.\d+)\s*;/, source) do
        ~r/^\s*interface\s+([a-z-]+)\s*\{/m
        |> Regex.scan(source)
        |> Enum.map(fn [_, interface] -> "#{package}/#{interface}@#{version}" end)
      else
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  test "the wit tree is where this test thinks it is" do
    assert File.dir?(@wit_root)
    refute wit_abi_names() == []
  end

  # `Prima.CargoToml` hand-writes the catalyst WIT dependency table
  # into a generated Cargo.toml; the build sandbox materializes whatever
  # sits under `wit/catalyst/deps/`. A new dep directory that the template
  # never declares fails a build with a message about the world, not
  # about the missing declaration — this binds the two.
  test "the scaffold's Cargo.toml declares exactly the catalyst WIT deps" do
    declared =
      ~r/"(cyfr:[a-z-]+)" = \{ path = "wit\/deps\/(cyfr-[a-z-]+)" \}/
      |> Regex.scan(Prima.CargoToml.template(:catalyst, include_oauth_wit: true))
      |> Enum.map(fn [_, _pkg, dir] -> dir end)
      |> Enum.sort()

    on_disk =
      @wit_root
      |> Path.join("catalyst/deps/*")
      |> Prima.Test.SourceTree.files!()
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

    assert declared == on_disk,
           "scaffold declares #{inspect(declared)} but wit/catalyst/deps holds " <>
             inspect(on_disk)
  end
end
