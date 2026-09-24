# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.IngressInventoryTest do
  @moduledoc """
  Inventories execution entry points to verify credential-grant checks.

  A runtime registry of ingresses would be architecture invented for a
  test. Instead the code is scanned for callers of the run family and
  compared against a literal allowlist — so a NEW ingress fails here
  until someone classifies it, which is the fail-closed direction. The
  second arm (`Cyfr.Execution.CredentialedIngressGateTest`) proves each
  classified ingress yields no credentials without a profile.
  """

  use ExUnit.Case, async: true

  # Every non-test module that may start an execution, and what it is.
  # Adding a row is a deliberate act: it means "this is an ingress, and
  # the credential gate covers it".
  @allowed %{
    # Where execution is defined: the run family, and the dispatch every
    # run goes through.
    "apps/cyfr/lib/cyfr/execution.ex" => :internal,
    "apps/cyfr/lib/cyfr/execution/dispatch.ex" => :internal,
    # Ingresses proper.
    "apps/cyfr/lib/cyfr/execution/mcp.ex" => :mcp,
    "apps/cyfr/lib/cyfr/schedules/scheduler.ex" => :cron,
    "apps/cyfr/lib/emissary_web/controllers/webhook_controller.ex" => :webhook,
    # One implementation behind two tincture surfaces (the HTTP controller
    # and the console shell render its outcomes; neither calls run_root
    # itself any more).
    "apps/cyfr/lib/emissary/tincture/invoke.ex" => :tincture,
    # Formula children run under the authority CYFR holds for the parent's
    # attempt, never their own, admitted for the parent's runner.
    "apps/cyfr/lib/cyfr/execution/host/children.ex" => :in_chain,
    # The agent loop: the turn's root is claimed without a guest, and every
    # call it dispatches is a child of that root.
    "apps/cyfr/lib/aqua/loop.ex" => :in_chain,
    "apps/cyfr/lib/aqua/loop/binding.ex" => :in_chain,
    "apps/cyfr/lib/aqua/loop/turn.ex" => :in_chain
  }

  @patterns [
    "Cyfr.Execution.run_root(",
    "Cyfr.Execution.run_root_edge(",
    "Cyfr.Execution.claim_turn_root(",
    "Cyfr.Execution.run_child(",
    "&Cyfr.Execution.run_child/",
    "Cyfr.Execution.admit_child(",
    "&Cyfr.Execution.admit_child/",
    "Admission.step_invoke(",
    "Admission.admit(",
    "Dispatch.run(",
    "Dispatch.claim("
  ]

  defp root, do: Path.expand("../../../..", __DIR__)

  defp code(path) do
    path |> Prima.Test.SourceTree.read() |> Prima.Test.CodeLines.lines() |> Enum.join("\n")
  end

  test "every execution entry point is a classified ingress" do
    found =
      Prima.Test.SourceTree.files!(Path.join(root(), "apps/*/lib/**/*.ex"))
      |> Enum.filter(fn path ->
        code = code(path)
        Enum.any?(@patterns, &String.contains?(code, &1))
      end)
      |> Enum.map(&Path.relative_to(&1, root()))
      |> MapSet.new()

    known = MapSet.new(Map.keys(@allowed))

    unclassified = MapSet.difference(found, known)
    stale = MapSet.difference(known, found)

    assert MapSet.size(unclassified) == 0, """
    A new execution entry point appeared and is not classified as an ingress:

      #{unclassified |> MapSet.to_list() |> Enum.sort() |> Enum.join("\n  ")}

    Every ingress must run under a consent-rooted authority. Add it to
    @allowed here AND to the per-ingress credential gate in
    apps/cyfr/test/cyfr/execution/credentialed_ingress_gate_test.exs.
    """

    assert MapSet.size(stale) == 0, """
    These files no longer start executions — drop them from @allowed:

      #{stale |> MapSet.to_list() |> Enum.sort() |> Enum.join("\n  ")}
    """
  end

  # The ingresses proper. Each starts its root through `Cyfr.Execution`,
  # which derives the authority a run is admitted under from the selected
  # profile's consent; admitting or dispatching directly would skip that.
  @ingress_files ~w(
    apps/cyfr/lib/cyfr/execution/mcp.ex
    apps/cyfr/lib/cyfr/schedules/scheduler.ex
    apps/cyfr/lib/emissary_web/controllers/webhook_controller.ex
    apps/cyfr/lib/emissary/tincture/invoke.ex
  )

  # Where execution is defined, and where a formula's children are
  # admitted under their parent's authority.
  @engine_internals ~w(
    apps/cyfr/lib/cyfr/execution.ex
    apps/cyfr/lib/cyfr/execution/dispatch.ex
    apps/cyfr/lib/cyfr/execution/host/children.ex
  )

  test "every ingress starts its root through Cyfr.Execution" do
    direct =
      Enum.filter(@ingress_files, fn file ->
        root()
        |> Path.join(file)
        |> code()
        |> String.match?(~r/\b(Admission\.(admit|step_invoke)|Dispatch\.(run|claim))\(/)
      end)

    assert direct == [],
           """
           These ingresses admit or dispatch a run directly instead of
           starting it through Cyfr.Execution:

             #{Enum.join(direct, "\n  ")}

           A run started that way is admitted under an authority no consent
           was loaded for.
           """
  end

  test "the ingress roster and the engine internals do not overlap" do
    assert MapSet.disjoint?(MapSet.new(@ingress_files), MapSet.new(@engine_internals))

    for file <- @ingress_files ++ @engine_internals do
      assert Map.has_key?(@allowed, file),
             "#{file} is named here but missing from @allowed — the two rosters must agree"
    end
  end
end
