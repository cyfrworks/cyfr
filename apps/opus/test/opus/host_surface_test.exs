# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HostSurfaceTest do
  @moduledoc """
  What opus actually needs from cyfr, written down.

  Inventories direct CYFR dependencies in Opus beyond the delegates exposed by `Opus.Host`.
  The shared contracts (`apps/cyfr_contracts`) are not cyfr and are not counted.

  The claim is fixed. This is what keeps it fixed: a namespace opus starts
  reaching into that is not on this list fails here, and adding it means
  deciding what a worker would do about it — implement the behaviour, or
  need a client for the infrastructure.
  """

  use ExUnit.Case, async: true

  # The cyfr namespaces opus reaches into, and what a remote worker would
  # have to do about each.
  @surface [
    # The consent/record plane — `Opus.Host`'s delegates. These are
    # the ones that would genuinely go over the wire.
    # `Sanctum.Authority` is the authority's live half: the invoke-budget
    # slot a spawned child holds and gives back — a worker on another node
    # would take and release it through a client. The authority as data is
    # `Cyfr.Authority`, in the contracts.
    "Sanctum.Authority",
    # The pin check before a run's vault edges are unsealed: the consent
    # the authority was loaded from is still its profile's head.
    "Sanctum.Consent",
    "Sanctum.Context",
    "Sanctum.Policy",
    "Sanctum.VaultReader",
    "Emissary.MCP",

    # Infrastructure a worker would need a client for, not a behaviour it
    # would implement.
    "Arca",
    "Arca.Cache",
    "Arca.QueryHelpers",
    "Arca.Storage",
    "Arca.Usage",

    # The component catalogue: what to run, and whether it is what it says.
    # The code identity an execution records, resolved from the athanor's
    # component rows.
    "Compendium.Activation",
    "Compendium.Component",
    # The local-namespace trust policy: the storage boundary asks it before
    # a guest write lands in components/ — pulled components are
    # fork-to-modify, and the refusal sentence lives with the policy.
    "Compendium.NamespacePolicy",
    "Compendium.Resolver",

    # Shared primitives — glue, by construction available to any node.
    # Whether this boot still owns the control plane — the engine admits
    # nothing when it does not.
    "Cyfr.ControlPlane",
    # The execution port, and what CYFR owns of a run: the authority it is
    # admitted under, its invoke charge row and its recorded signature
    # attestation, the rate counters consented limits are checked against,
    # the execution slots and the registry a cancel finds a run's processes
    # through, the event stream a guest's events are pushed on, the
    # execution row opened, renewed and closed, its lifecycle telemetry,
    # and the cascade that fails a failed parent's children — a worker on
    # another node would reach them through host calls.
    "Cyfr.Execution",
    # Egress pinning: a guest request's host resolved and checked against
    # its consented private policy before the connection is made.
    "Cyfr.Network",
    # The operation catalog: an in-chain tool call is dispatched through it.
    "Cyfr.Ops",
    # The signed-pulls posture, read at execution as well as at pull so a
    # component stored before the knob was turned on cannot keep running. A
    # worker would need this value from its client, not re-read it locally.
    "Cyfr.RuntimeConfig"
  ]

  @namespace ~r/\b((?:Arca|Sanctum|Compendium|Emissary|Prism|Cyfr)(?:\.[A-Z]\w+)*)\b/

  defp root, do: Path.expand("../../../..", __DIR__)

  # The shared contracts are not cyfr: their modules are named where they
  # are defined, and a reach into them is not a reach into the control plane.
  defp contracts do
    modules =
      for path <- Path.wildcard(Path.join(root(), "apps/cyfr_contracts/lib/**/*.ex")),
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

    for path <- Path.wildcard(Path.join(root(), "apps/opus/lib/**/*.ex")),
        line <- path |> File.read!() |> Cyfr.Test.CodeLines.lines(),
        [_, module] <- Regex.scan(@namespace, line),
        not MapSet.member?(contracts, module),
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
           infrastructure. `Opus.Host` is only the consent/record plane; it
           is not the whole answer and no longer claims to be.
           """
  end

  test "the surface names nothing opus has stopped reaching into" do
    stale = MapSet.new(@surface) |> MapSet.difference(reached()) |> Enum.sort()

    assert stale == [],
           "the surface names namespaces opus no longer uses: #{inspect(stale)}"
  end

  test "Opus.Host covers the consent and record plane" do
    exports = Opus.Host.__info__(:functions) |> Keyword.keys() |> MapSet.new()

    for name <- [
          :tool_call,
          :unseal,
          :enforce,
          :record_start,
          :record_complete,
          :record_failed,
          :broadcast
        ] do
      assert MapSet.member?(exports, name),
             "Opus.Host no longer delegates #{name} — the plane it does cover must stay covered"
    end
  end
end
