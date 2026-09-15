# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HostSurfaceTest do
  @moduledoc """
  What opus actually needs from cyfr, written down.

  Inventories the CYFR modules opus names directly. The shared contracts
  (`apps/cyfr_contracts`) are not cyfr and are not counted.

  The claim is fixed. This is what keeps it fixed: a namespace opus starts
  reaching into that is not on this list fails here, and adding it means
  deciding what a worker would do about it — implement the behaviour, or
  need a client for the infrastructure.
  """

  use ExUnit.Case, async: true

  alias Cyfr.Test.SourceTree

  # The cyfr namespaces opus reaches into, and what a remote worker would
  # have to do about each.
  @surface [
    # Infrastructure a worker would need a client for, not a behaviour it
    # would implement: the compiled-component and stream-handle cache.
    "Arca.Cache",

    # What CYFR owns of a run, reached only through `Opus.HostClient`'s host
    # calls — attach, renew, complete, fail, emit, the OAuth dispense, the
    # egress rate and denials, storage, the component's artifact, a
    # formula's children and catalog tools, and the runner exit report —
    # and the worker key the worker service holds (the tests below).
    "Cyfr.Execution",
    # Egress pinning: a guest request's host resolved and checked against
    # its consented private policy before the connection is made.
    "Cyfr.Network",
    # The guest error vocabulary a formula's invoke functions render their
    # own refusals in (`Cyfr.Ops.Error`).
    "Cyfr.Ops"
  ]

  # The CYFR modules opus names outside `Opus.HostClient`, each exactly.
  @beside_the_client %{
    "Arca.Cache" => "the compiled-component and stream-handle cache",
    "Arca.Cache.Keys" => "the cache's key spellings",
    "Cyfr.Network" => "egress pinning",
    "Cyfr.Ops.Error" => "the guest error vocabulary",
    "Cyfr.Execution.Keys" => "the worker key the worker service holds"
  }

  @namespace ~r/\b((?:Arca|Sanctum|Compendium|Emissary|Prism|Cyfr)(?:\.[A-Z]\w+)*)\b/

  defp root, do: Path.expand("../../../..", __DIR__)

  # The shared contracts are not cyfr: their modules are named where they
  # are defined, and a reach into them is not a reach into the control plane.
  defp contracts do
    for path <- SourceTree.files!(Path.join(root(), "apps/cyfr_contracts/lib/**/*.ex")),
        module <- defined_modules(File.read!(path)),
        into: MapSet.new(),
        do: module
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

  # Code lines under apps/opus/lib, by file relative to the umbrella root.
  defp opus_code do
    for path <- SourceTree.files!(Path.join(root(), "apps/opus/lib/**/*.ex")),
        line <- path |> File.read!() |> Cyfr.Test.CodeLines.lines(),
        do: {Path.relative_to(path, root()), line}
  end

  # Every CYFR module opus code names, by file: a reach counts unless it
  # names a contracts module exactly, so a cyfr module that shares a
  # contracts module's namespace is still counted.
  defp reaches do
    contracts = contracts()

    for {path, line} <- opus_code(),
        [_, module] <- Regex.scan(@namespace, line),
        not MapSet.member?(contracts, module),
        uniq: true,
        do: {path, module}
  end

  defp reached do
    for {_path, module} <- reaches(),
        into: MapSet.new(),
        do: module |> String.split(".") |> Enum.take(2) |> Enum.join(".")
  end

  test "opus reaches only into the namespaces this surface names" do
    extra = reached() |> MapSet.difference(MapSet.new(@surface)) |> Enum.sort()

    assert extra == [],
           """
           opus reaches into cyfr namespaces this surface does not name:

           #{Enum.map_join(extra, "\n", &"  #{&1}")}

           Add each with a line saying what a worker on another node would
           do about it — implement the behaviour, or need a client for the
           infrastructure.
           """
  end

  test "the surface names nothing opus has stopped reaching into" do
    stale = MapSet.new(@surface) |> MapSet.difference(reached()) |> Enum.sort()

    assert stale == [],
           "the surface names namespaces opus no longer uses: #{inspect(stale)}"
  end

  test "opus reaches CYFR only through Opus.HostClient" do
    refute Code.ensure_loaded?(Opus.Host)

    beside =
      for {path, module} <- reaches(),
          path != "apps/opus/lib/opus/host_client.ex",
          not Map.has_key?(@beside_the_client, module),
          do: "#{path}: #{module}"

    assert beside == [],
           """
           opus names CYFR modules outside Opus.HostClient that are not
           among the infrastructure it is known to reach:

           #{Enum.join(beside, "\n")}

           A run's authority, its children, its catalog tools and its
           attempt are CYFR's to decide, through a host call.
           """
  end

  test "opus reaches a run's attempt only through Opus.HostClient's host calls" do
    code = opus_code()

    transports =
      for {path, line} <- code, line =~ "Cyfr.Execution.Host", uniq: true, do: path

    assert transports == ["apps/opus/lib/opus/host_client.ex"],
           "Cyfr.Execution.Host is reached outside Opus.HostClient: #{inspect(transports)}"

    # The attempt's state (its masking set, emitter, rates, claim, holds
    # and close), its waiter and the lease are CYFR's: opus asks for them
    # through host calls and names nothing of the attempt itself. Of the
    # keys it holds only the worker service's own worker key.
    reaches =
      for {path, line} <- code,
          pattern <- [
            ~r/Cyfr\.Execution\.(Rates|Emit|Close|Assignments|Attempt|Lapse)\b/,
            ~r/Cyfr\.Execution\.Keys\.(?!worker_key\()/,
            ~r/\b(Close|Rates|Emit)\.[a-z_]+\(/,
            ~r/\brenew_lease\(/,
            ~r/\bArca\.ExecutionAttempts\b/,
            ~r/\bSanctum\.VaultReader\b/,
            ~r/\bAttempt\.[a-z_]+/
          ],
          line =~ pattern,
          do: "#{path}: #{String.trim(line)}"

    assert reaches == [],
           """
           opus reaches an attempt's state other than through Opus.HostClient:

           #{Enum.join(reaches, "\n")}
           """
  end

  test "the runner and the worker service reach CYFR only through Opus.HostClient and the worker key" do
    reaches =
      for {path, module} <- reaches(),
          path in ["apps/opus/lib/opus/runner.ex", "apps/opus/lib/opus/worker_service.ex"],
          module != "Cyfr.Execution.Keys",
          do: "#{path}: #{module}"

    assert reaches == [],
           """
           the runner or the worker service reaches CYFR other than through
           Opus.HostClient and the worker service's worker key:

           #{Enum.join(reaches, "\n")}
           """

    keys =
      for {path, line} <- opus_code(), line =~ "Cyfr.Execution.Keys", uniq: true, do: path

    assert keys == ["apps/opus/lib/opus/worker_service.ex"],
           "Cyfr.Execution.Keys is reached outside the worker service: #{inspect(keys)}"
  end
end
