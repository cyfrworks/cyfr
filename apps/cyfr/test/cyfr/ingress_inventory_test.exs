# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.IngressInventoryTest do
  @moduledoc """
  The §6 "no credentialed execution without a grant" gate, first arm:
  a mechanical inventory of everything that can start an execution.

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
    "apps/opus/lib/opus/mcp.ex" => :mcp,
    "apps/opus/lib/opus/cron_scheduler.ex" => :cron,
    "apps/cyfr/lib/emissary_web/controllers/webhook_controller.ex" => :webhook,
    "apps/cyfr/lib/emissary_web/controllers/tincture_controller.ex" => :tincture,
    "apps/cyfr/lib/prism_web/live/shell_live.ex" => :tincture_console,
    # Formula children run under the parent's authority, never their own.
    "apps/opus/lib/opus/formula_handler.ex" => :in_chain
  }

  @patterns [
    "Opus.run_root(",
    "Opus.run_root_edge(",
    "Cyfr.Execution.run_root(",
    "Cyfr.Execution.run_root_edge(",
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
      Path.wildcard(Path.join(root, "apps/*/lib/**/*.ex"))
      |> Enum.filter(fn path ->
        source = File.read!(path)
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
end
