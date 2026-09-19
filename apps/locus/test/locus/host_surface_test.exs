# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.HostSurfaceTest do
  @moduledoc """
  Locus names nothing of the control plane. Every module its code names is
  its own (`Locus.*`), a shared contract (a module defined under
  `apps/cyfr_contracts/lib`, whatever its namespace), or Elixir, OTP,
  Jason, Plug, Bandit or ThousandIsland. CYFR reaches the builder over the
  build wire alone (`Cyfr.BuilderProtocol`, served by
  `Locus.BuilderService`), and the builder reaches CYFR not at all. A reach
  into anything else fails here, and the answer is a field of the wire,
  never a dependency.

  The roster of control-plane namespaces Locus reaches is empty, and is
  held to be: a planted name is reported, so the scan cannot pass by
  seeing nothing.
  """

  use ExUnit.Case, async: true

  alias Locus.Test.{CodeLines, SourceTree}

  @root Path.expand("../../../..", __DIR__)

  # The control-plane namespaces Locus reaches into.
  @surface []

  # The namespaces Locus may name, beside its own and the contracts.
  @allowed_roots ~w(
    Elixir Kernel Access Agent Application Base Bitwise Enum Exception File Function GenServer IO
    Integer Keyword List Logger Map MapSet Path Port Process Regex String Supervisor System Task
    Jason Plug Bandit ThousandIsland
    ArgumentError RuntimeError
  )

  @module ~r/\b([A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)\b/

  @control_plane ~r/\b((?:Arca|Sanctum|Aqua|Compendium|Crucible|Emissary|Grimoire|Prism|Codex|Opus|Cyfr)(?:\.[A-Z]\w*)*)\b/

  # Every `defmodule` in the contracts, a nested one named under the module
  # enclosing it (`Outer.Inner`): each level indents two spaces.
  defp contracts do
    for path <- SourceTree.files!(Path.join(@root, "apps/cyfr_contracts/lib/**/*.ex")),
        module <- defined_modules(File.read!(path)),
        into: MapSet.new(),
        do: module
  end

  defp defined_modules(source) do
    source
    |> CodeLines.lines()
    |> Enum.flat_map(&Regex.scan(~r/^((?:  )*)defmodule ([A-Z][\w.]*) do/, &1))
    |> Enum.map_reduce([], fn [_, indent, name], enclosing ->
      path = Enum.take(enclosing, div(byte_size(indent), 2)) ++ [name]
      {Enum.join(path, "."), path}
    end)
    |> elem(0)
  end

  defp code(glob) do
    for path <- SourceTree.files!(Path.join(@root, glob)),
        line <- lines(Path.relative_to(path, @root), File.read!(path)),
        do: line
  end

  defp lines(path, source), do: for(line <- CodeLines.lines(source), do: {path, line})

  defp allowed?(module, contracts) do
    String.starts_with?(module, "Locus.") or module == "Locus" or
      MapSet.member?(contracts, module) or
      (module |> String.split(".") |> hd()) in @allowed_roots
  end

  # A bare name is an alias, whose `alias` line names the module in full
  # and is checked itself.
  defp outside(lines, contracts) do
    for {path, line} <- lines,
        [_, module] <- Regex.scan(@module, line),
        String.contains?(module, "."),
        not allowed?(module, contracts),
        uniq: true,
        do: "#{path}: #{module}"
  end

  # A reach counts unless it names a contracts module exactly, so a
  # control-plane module sharing a contracts module's namespace
  # (`Compendium.Resolver` beside `Compendium.WITSource`) still counts.
  defp reached(lines, contracts) do
    for {_path, line} <- lines,
        [_, module] <- Regex.scan(@control_plane, line),
        not MapSet.member?(contracts, module),
        into: MapSet.new(),
        do: module |> String.split(".") |> Enum.take(2) |> Enum.join(".")
  end

  test "locus names only its own modules, the contracts, Elixir, OTP, Jason, Plug, Bandit and ThousandIsland" do
    assert outside(code("apps/locus/lib/**/*.ex"), contracts()) == [],
           """
           locus names modules outside its surface. A build's sources, its
           caps and its deadline arrive in the request, and what it made
           leaves in the answer: nothing else of CYFR's is the builder's.
           """
  end

  test "the control-plane namespaces locus reaches are the roster's, and the roster is empty" do
    assert @surface == []

    assert reached(code("apps/locus/lib/**/*.ex"), contracts()) == MapSet.new(@surface),
           "locus reaches into the control plane; the locus release carries the contracts alone"
  end

  test "locus's suite names nothing of the control plane either" do
    # This file plants control-plane names on purpose.
    this = Path.relative_to(__ENV__.file, @root)
    lines = Enum.reject(code("apps/locus/test/**/*.{ex,exs}"), &(elem(&1, 0) == this))

    assert lines != []
    assert reached(lines, contracts()) == MapSet.new()
  end

  test "a planted control-plane name is reported by both scans" do
    contracts = contracts()

    planted =
      lines("planted.ex", ~S"""
      defmodule Locus.Planted do
        alias Sanctum.Context
        alias Emissary.MCP.{Progress, Tools}

        def reach(%Context{} = ctx, path, tool, args) do
          {:ok, _bytes} = Arca.Storage.get(ctx, path)
          Progress.report(Tools, Cyfr.Ops.Catalog.call_external(ctx, tool, args))
          Compendium.Resolver.resolve(ctx, path)
        end
      end
      """)

    assert reached(planted, contracts) ==
             MapSet.new(
               ~w(Arca.Storage Sanctum.Context Cyfr.Ops Compendium.Resolver Emissary.MCP)
             )

    assert outside(planted, contracts) == [
             "planted.ex: Sanctum.Context",
             "planted.ex: Emissary.MCP.Progress",
             "planted.ex: Emissary.MCP.Tools",
             "planted.ex: Arca.Storage",
             "planted.ex: Cyfr.Ops.Catalog",
             "planted.ex: Compendium.Resolver"
           ]

    # What the contracts define passes, under whatever namespace.
    shared =
      lines("shared.ex", ~S"""
      defmodule Locus.Shared do
        @spec run(binary()) :: {:ok, map()} | {:error, Cyfr.BuilderProtocol.refusal()}
        def run(bytes) do
          {:ok, _slot} = Cyfr.Slots.acquire(Locus.BuildSlots, "ath_1", :root, wait_ms: 0)
          Compendium.WasmValidator.validate(bytes)
        end
      end
      """)

    assert reached(shared, contracts) == MapSet.new()
    assert outside(shared, contracts) == []
  end

  test "locus depends on the contracts alone" do
    mix = File.read!(Path.join(@root, "apps/locus/mix.exs"))
    assert mix =~ "{:cyfr_contracts, in_umbrella: true}"
    refute mix =~ "{:cyfr, in_umbrella: true"
    refute mix =~ "Arca.Repo"
    refute mix =~ "ecto"
  end
end
