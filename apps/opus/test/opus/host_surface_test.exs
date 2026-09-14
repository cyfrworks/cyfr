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
    # `Sanctum.Authority` is the authority's live half: the invoke-budget
    # slot a spawned child holds and gives back — a worker on another node
    # would take and release it through a client. The authority as data is
    # `Cyfr.Authority`, in the contracts.
    "Sanctum.Authority",
    "Sanctum.Context",
    # A guest's egress denial recorded for the audit trail, through
    # `Opus.Host.enforce/1`.
    "Sanctum.Policy",

    # Infrastructure a worker would need a client for, not a behaviour it
    # would implement.
    "Arca",
    "Arca.Cache",
    "Arca.QueryHelpers",
    "Arca.Storage",
    "Arca.Usage",

    # The local-namespace trust policy: the storage boundary asks it before
    # a guest write lands in components/ — pulled components are
    # fork-to-modify, and the refusal sentence lives with the policy.
    "Compendium.NamespacePolicy",

    # Shared primitives — glue, by construction available to any node.
    # The execution port, and what CYFR owns of a run: its admission (the
    # authority, the resolved and attested component, the consented limits
    # and policy, the admitted row and its signed assignment), the waiter
    # that awaits the run's attempt, the invoke charge row, the execution
    # slots and the registry a cancel finds a run's processes through, the
    # cascade a cancel fails children through, and the host calls of
    # `Opus.HostClient` — attach, renew, complete, fail, emit, the OAuth
    # dispense and the egress rate — which are the only way opus reaches a
    # run's attempt (the test below).
    "Cyfr.Execution",
    # Egress pinning: a guest request's host resolved and checked against
    # its consented private policy before the connection is made.
    "Cyfr.Network",
    # The operation catalog: an in-chain tool call is dispatched through it.
    "Cyfr.Ops"
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
           infrastructure. `Opus.Host` is only the consent plane a host
           function crosses; it is not the whole answer.
           """
  end

  test "the surface names nothing opus has stopped reaching into" do
    stale = MapSet.new(@surface) |> MapSet.difference(reached()) |> Enum.sort()

    assert stale == [],
           "the surface names namespaces opus no longer uses: #{inspect(stale)}"
  end

  # Code lines under apps/opus/lib, by file relative to the umbrella root.
  defp opus_code do
    for path <- Path.wildcard(Path.join(root(), "apps/opus/lib/**/*.ex")),
        line <- path |> File.read!() |> Cyfr.Test.CodeLines.lines(),
        do: {Path.relative_to(path, root()), line}
  end

  test "opus reaches a run's attempt only through Opus.HostClient's host calls" do
    code = opus_code()

    transports =
      for {path, line} <- code, line =~ "Cyfr.Execution.Host", uniq: true, do: path

    assert transports == ["apps/opus/lib/opus/host_client.ex"],
           "Cyfr.Execution.Host is reached outside Opus.HostClient: #{inspect(transports)}"

    # The attempt's state (its masking set, emitter, rates, claim and
    # close) and the lease are CYFR's: opus asks for them through host
    # calls. What opus names of the attempt itself is the waiter's two
    # calls, `await` and `abandon`.
    reaches =
      for {path, line} <- code,
          pattern <- [
            ~r/Cyfr\.Execution\.(Rates|Emit|Close|Keys|Assignments)\b/,
            ~r/\b(Close|Rates|Emit)\.[a-z_]+\(/,
            ~r/\brenew_lease\(/,
            ~r/\bArca\.ExecutionAttempts\b/,
            ~r/\bSanctum\.VaultReader\b/,
            ~r/\bAttempt\.(?!await\(|abandon\()[a-z_]+/
          ],
          line =~ pattern,
          do: "#{path}: #{String.trim(line)}"

    assert reaches == [],
           """
           opus reaches an attempt's state other than through Opus.HostClient:

           #{Enum.join(reaches, "\n")}
           """
  end

  test "Opus.Host covers the consent plane a host function crosses" do
    exports = Opus.Host.__info__(:functions) |> Keyword.keys() |> MapSet.new()

    for name <- [:tool_call, :host_intercepted?, :enforce] do
      assert MapSet.member?(exports, name),
             "Opus.Host no longer delegates #{name} — the plane it does cover must stay covered"
    end
  end
end
