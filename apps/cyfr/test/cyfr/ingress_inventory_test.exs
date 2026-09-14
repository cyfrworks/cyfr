# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.IngressInventoryTest do
  @moduledoc """
  Inventories execution entry points to verify credential-grant checks.

  A runtime registry of ingresses would be architecture invented for a
  test. Instead the source is scanned for callers of the run family and
  compared against a literal allowlist — so a NEW ingress fails here
  until someone classifies it, which is the fail-closed direction. The
  second arm (`Opus.CredentialedIngressGateTest`) proves each classified
  ingress yields no credentials without a profile.
  """

  use ExUnit.Case, async: true

  # Every non-test module that may start an execution, and what it is.
  # Adding a row is a deliberate act: it means "this is an ingress, and
  # the credential gate covers it".
  @allowed %{
    # The chain and the executor themselves — where execution is defined.
    "apps/opus/lib/opus/chain.ex" => :internal,
    "apps/opus/lib/opus/executor.ex" => :internal,
    "apps/opus/lib/opus.ex" => :facade,
    # Ingresses proper.
    "apps/cyfr/lib/cyfr/execution/mcp.ex" => :mcp,
    "apps/cyfr/lib/cyfr/schedules/scheduler.ex" => :cron,
    "apps/cyfr/lib/emissary_web/controllers/webhook_controller.ex" => :webhook,
    # One implementation behind two tincture surfaces (the HTTP controller
    # and the console shell render its outcomes; neither calls run_root
    # itself any more).
    "apps/cyfr/lib/emissary/tincture/invoke.ex" => :tincture,
    # Formula children run under the parent's authority, never their own.
    "apps/opus/lib/opus/formula_handler.ex" => :in_chain,
    # The agent loop: the turn's root is claimed without a guest, and every
    # call it dispatches is a child of that root.
    "apps/cyfr/lib/aqua/loop.ex" => :in_chain,
    "apps/cyfr/lib/aqua/loop/binding.ex" => :in_chain,
    "apps/cyfr/lib/aqua/loop/turn.ex" => :in_chain
  }

  @patterns [
    "Opus.run_root(",
    "Opus.run_root_edge(",
    "Cyfr.Execution.run_root(",
    "Cyfr.Execution.run_root_edge(",
    "Cyfr.Execution.claim_turn_root(",
    "Cyfr.Execution.run_child(",
    "Opus.run_child(",
    "Opus.Chain.run_root(",
    "Opus.Chain.run_root_edge(",
    "Opus.Chain.run_child(",
    "Opus.Chain.run_child_stream(",
    "Opus.Chain.step_invoke(",
    "Opus.Chain.execute_child(",
    "Opus.Executor.run("
  ]

  test "every execution entry point is a classified ingress" do
    root = Path.expand("../../../..", __DIR__)

    found =
      Cyfr.Test.SourceTree.files!(Path.join(root, "apps/*/lib/**/*.ex"))
      |> Enum.filter(fn path ->
        source = Cyfr.Test.SourceTree.read(path)
        Enum.any?(@patterns, &String.contains?(source, &1))
      end)
      |> Enum.map(&Path.relative_to(&1, root))
      |> MapSet.new()

    known = MapSet.new(Map.keys(@allowed))

    unclassified = MapSet.difference(found, known)
    stale = MapSet.difference(known, found)

    assert MapSet.size(unclassified) == 0, """
    A new execution entry point appeared and is not classified as an ingress:

      #{unclassified |> MapSet.to_list() |> Enum.sort() |> Enum.join("\n  ")}

    Every ingress must run under a consent-rooted authority. Add it to
    @allowed here AND to the per-ingress credential gate in
    apps/opus/test/opus/credentialed_ingress_gate_test.exs.
    """

    assert MapSet.size(stale) == 0, """
    These files no longer start executions — drop them from @allowed:

      #{stale |> MapSet.to_list() |> Enum.sort() |> Enum.join("\n  ")}
    """
  end

  # Which ingresses go through `Cyfr.Execution` rather than naming the
  # engine. The port exists so cyfr has no compile-time path into Opus; an
  # ingress that names the engine is intercepted by no stubbed
  # `:execution_impl` and passes no readiness gate.
  @ingress_files ~w(
    apps/cyfr/lib/cyfr/execution/mcp.ex
    apps/cyfr/lib/cyfr/schedules/scheduler.ex
    apps/cyfr/lib/emissary_web/controllers/webhook_controller.ex
    apps/cyfr/lib/emissary/tincture/invoke.ex
  )

  # The engine's own internals and its facade — where execution IS defined,
  # and the module the port dispatches to.
  @engine_internals ~w(
    apps/opus/lib/opus.ex
    apps/opus/lib/opus/chain.ex
    apps/opus/lib/opus/executor.ex
    apps/opus/lib/opus/formula_handler.ex
  )

  test "every ingress starts its root through the port" do
    root = Path.expand("../../../..", __DIR__)

    direct =
      Enum.filter(@ingress_files, fn file ->
        root
        |> Path.join(file)
        |> Cyfr.Test.SourceTree.read()
        |> String.split("\n")
        |> Enum.reject(&String.match?(&1, ~r/^\s*#/))
        |> Enum.any?(&String.match?(&1, ~r/\bOpus\.(run_root|run_root_edge|run_child)\(/))
      end)

    assert direct == [],
           """
           These ingresses name the engine directly instead of Cyfr.Execution:

             #{Enum.join(direct, "\n  ")}

           A stubbed :execution_impl does not intercept those calls, and they
           skip Cyfr.Execution.available?/0 — so a headless build answers them
           by crashing rather than by refusing.
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
