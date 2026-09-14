# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.WitAbiDriftTest do
  @moduledoc """
  The guest ABI is written down twice, and nothing bound the two together.

  `wit/` is the contract: `Compendium.WITSource` embeds it at compile time,
  `Locus.Builder` copies it into the build sandbox, and `Compendium.Scaffold`
  points a generated `Cargo.toml` at it — so a component is compiled against
  those interface names. The host side of the same contract is a set of
  string keys in `Opus`: the import map a component's world is instantiated
  with, and the export path each type is called through.

  Rename an interface in `wit/` and both sides still compile. Nothing fails
  until a guest is instantiated and the host cannot satisfy an import it
  never heard of — at runtime, per component, with a message about a missing
  function rather than about the rename that caused it.

  This is the same guard `Cyfr.CrossLanguageDriftTest` puts on the Go
  component-ref port and `Emissary.MCP.ClientProtocolDriftTest` puts on the
  protocol version: read both sources, and fail here rather than there.
  """

  use ExUnit.Case, async: true

  @wit_root Path.expand("../../../../wit", __DIR__)
  @opus_lib Path.expand("../../../opus/lib", __DIR__)

  # Every `cyfr:<package>/<interface>@<version>` string the engine hands to
  # Wasmex, whether as an import it provides or an export it calls.
  defp opus_abi_names do
    @opus_lib
    |> Path.join("**/*.ex")
    |> Cyfr.Test.SourceTree.files!()
    |> Enum.flat_map(fn path ->
      ~r/"(cyfr:[a-z]+\/[a-z-]+@\d+\.\d+\.\d+)"/
      |> Regex.scan(File.read!(path))
      |> Enum.map(fn [_, name] -> name end)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # What `wit/` actually declares: for each package, its version and the
  # interfaces defined in it — across the world files and their deps.
  defp wit_abi_names do
    @wit_root
    |> Path.join("**/*.wit")
    |> Cyfr.Test.SourceTree.files!()
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
    refute opus_abi_names() == []
  end

  test "every ABI name the engine uses is declared in wit/" do
    declared = wit_abi_names()
    undeclared = opus_abi_names() -- declared

    assert undeclared == [],
           """
           Opus names guest interfaces that wit/ does not declare:

           #{Enum.map_join(undeclared, "\n", &"  #{&1}")}

           wit/ declares:

           #{Enum.map_join(declared, "\n", &"  #{&1}")}

           Both sides compile either way — a component built against wit/ and
           a host offering something else only disagree when a guest is
           instantiated, as a missing import.
           """
  end

  # The reverse is deliberately NOT asserted: wit/ may declare an interface
  # the engine does not implement yet, which is how a new host function gets
  # its contract written before its handler exists. Only the engine claiming
  # something wit/ never declared is a defect.
  test "the interfaces the engine does implement cover the worlds' imports" do
    imported =
      @wit_root
      |> Path.join("*/world.wit")
      |> Cyfr.Test.SourceTree.files!()
      |> Enum.flat_map(fn path ->
        ~r/import\s+(cyfr:[a-z]+\/[a-z-]+@\d+\.\d+\.\d+)\s*;/
        |> Regex.scan(File.read!(path))
        |> Enum.map(fn [_, name] -> name end)
      end)
      |> Enum.uniq()
      |> Enum.sort()

    refute imported == [], "no imports found in the world files — the regex has drifted"

    missing = imported -- opus_abi_names()

    assert missing == [],
           """
           A world imports host interfaces the engine provides no import map for:

           #{Enum.map_join(missing, "\n", &"  #{&1}")}

           A component built against that world will fail to instantiate.
           """
  end

  # `Compendium.Scaffold` hand-writes the catalyst WIT dependency table
  # into a generated Cargo.toml; the build sandbox materializes whatever
  # sits under `wit/catalyst/deps/`. A new dep directory that the scaffold
  # never declares fails a build with a message about the world, not
  # about the missing declaration — this binds the two.
  test "the scaffold's Cargo.toml declares exactly the catalyst WIT deps" do
    declared =
      ~r/"(cyfr:[a-z-]+)" = \{ path = "wit\/deps\/(cyfr-[a-z-]+)" \}/
      |> Regex.scan(Compendium.Scaffold.cargo_toml_for(:catalyst, include_oauth_wit: true))
      |> Enum.map(fn [_, _pkg, dir] -> dir end)
      |> Enum.sort()

    on_disk =
      @wit_root
      |> Path.join("catalyst/deps/*")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

    assert declared == on_disk,
           "scaffold declares #{inspect(declared)} but wit/catalyst/deps holds " <>
             inspect(on_disk)
  end

  # The registration gate (`Compendium.WasmValidator.validate/2`) demands
  # the exports `Compendium.WITSource.expected_exports/1` derives from the
  # world files; the engine calls a component through the same names
  # (`Opus.Runtime.execute_with_convention/3`). If the two drift, either
  # registration refuses components the engine could run, or the engine
  # calls an export registration never verified — both wrong.
  test "the worlds registration demands are the ones the engine calls" do
    runtime = File.read!(Path.join(@opus_lib, "opus/runtime.ex"))

    for type <- Cyfr.ComponentRef.executable_types() do
      expected = Compendium.WITSource.expected_exports(type)

      assert expected != [],
             "WITSource derives no expected exports for #{type} — " <>
               "the world.wit parse has drifted"

      for name <- expected do
        assert String.contains?(runtime, ~s("#{name}")),
               "registration demands #{name} for #{type}, but Opus.Runtime " <>
                 "never addresses it — the call convention and the gate have drifted"
      end
    end
  end
end
