# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HostSurfaceTest do
  @moduledoc """
  What opus actually needs from cyfr, written down.

  Inventories direct CYFR dependencies in Opus beyond the delegates exposed by `Opus.Host`.

  The claim is fixed. This is what keeps it fixed: a namespace opus starts
  reaching into that is not on this list fails here, and adding it means
  deciding what a worker would do about it — implement the behaviour, or
  need a client for the infrastructure.
  """

  use ExUnit.Case, async: true

  # The cyfr namespaces opus reaches into, and what a remote worker would
  # have to do about each.
  @surface [
    # The consent/record plane — `Opus.Host`'s eight delegates. These are
    # the ones that would genuinely go over the wire.
    "Sanctum.Authority",
    "Sanctum.Consent",
    "Sanctum.Context",
    "Sanctum.Policy",
    "Sanctum.VaultReader",
    "Emissary.MCP",

    # Infrastructure a worker would need a client for, not a behaviour it
    # would implement.
    "Arca",
    "Arca.Cache",
    "Arca.Execution",
    # The invoke budget's durable half: a spawn-shaped child's charge row,
    # taken before it runs and given back after — a worker on another
    # node would charge and release through a client.
    "Arca.BudgetReservations",
    # The attempt that owns an execution: renewed, cancelled and closed by
    # the runner that holds it, and the turn root a host loop pauses and
    # resumes — a worker on another node would renew and close its
    # attempt through a client.
    "Arca.ExecutionAttempts",
    # The durable half of an execution's stream: the rows a replay reads
    # and the counter a delta rides under — a worker on another node would
    # read them through a client.
    "Arca.ExecutionEvents",
    # An execution's result is kept as a payload once it completes.
    "Arca.ExecutionPayloads",
    "Arca.QueryHelpers",
    "Arca.Storage",
    # The turn a root belongs to: paused and resumed with the root's
    # attempt in one transaction — a worker holding a turn root would
    # move the rows through a client.
    "Arca.TurnStorage",
    "Arca.Usage",
    "Emissary.PubSub",

    # The component catalogue: what to run, and whether it is what it says.
    "Compendium.Activation",
    # The agent that dispatched a child, named on the row as its parent:
    # what of the child's output is kept follows from it.
    "Compendium.AgentSource",
    "Compendium.Component",
    "Compendium.Manifest",
    # The local-namespace trust policy: the storage boundary asks it before
    # a guest write lands in components/ — pulled components are
    # fork-to-modify, and the refusal sentence lives with the policy.
    "Compendium.NamespacePolicy",
    "Compendium.Resolver",
    "Compendium.Source",

    # Policy and vocabulary that travel with a request.
    "Sanctum",
    "Sanctum.Cidr",
    "Sanctum.ComponentRef",
    "Sanctum.Limits",

    # Shared primitives — glue, by construction available to any node.
    # This boot's name on every execution row (the lease's runner id).
    "Cyfr.Boot",
    # Whether this boot still owns the control plane — the engine admits
    # nothing when it does not.
    "Cyfr.ControlPlane",
    "Cyfr.Digest",
    "Cyfr.Execution",
    "Cyfr.Json",
    "Cyfr.LoggerContext",
    "Cyfr.MediaType",
    "Cyfr.Network",
    # The operation catalog: an in-chain tool call is dispatched through it.
    "Cyfr.Ops",
    # The class an execution's payloads are kept under when its caller
    # names none — a worker on another node would take it from its
    # assignment, which names the retention class with the input.
    "Cyfr.Retention",
    "Cyfr.PathSafety",
    # The signed-pulls posture, read at execution as well as at pull so a
    # component stored before the knob was turned on cannot keep running. A
    # worker would need this value from its client, not re-read it locally.
    "Cyfr.RuntimeConfig",
    "Cyfr.Time",
    "Cyfr.Topics",
    # The shared unexpected-message catch-all spelling — a log-line SSOT,
    # not a capability.
    "Cyfr.UnexpectedMessage",
    "Cyfr.UUID7"
  ]

  @namespace ~r/\b((?:Arca|Sanctum|Compendium|Emissary|Prism|Cyfr)(?:\.[A-Z]\w+)*)\b/

  defp root, do: Path.expand("../../../..", __DIR__)

  defp reached do
    for path <- Path.wildcard(Path.join(root(), "apps/opus/lib/**/*.ex")),
        line <- path |> File.read!() |> Cyfr.Test.CodeLines.lines(),
        [_, module] <- Regex.scan(@namespace, line),
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
          :load_root,
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
