# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.TrampolinePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sanctum.Authority.Transition
  alias Sanctum.Test.AuthorityGen, as: Gen

  # §6 "Trampoline closed": unconsented D invokes inert B; B cannot reach
  # its own B→X edges. Without monotone unboundness, onward authority
  # would be a property of the NODE (B's blob entry) rather than of the
  # PATH (how B was reached) — and D would drive B's privileged edges with
  # input D controls.

  property "a node reached through an unconsented interposer cannot use its own edges" do
    check all {graph, meta} <- Gen.graph(), max_runs: 50 do
      auth = Gen.rooted({graph, meta})
      need = Gen.compliant_need(auth, meta)

      # D: dynamically dispatched, unconsented — inert but executing.
      {:child_zero, interposer} =
        Transition.step(
          auth,
          :call,
          Gen.invoke_at(auth, meta, "formula:evil.corp.interposer", need)
        )

      for {b, targets} <- Gen.outgoing(meta), targets != [] do
        # D invokes B. B has its own consented edges in the blob — but this
        # execution of B was reached off-graph, so it is unbound.
        {:child_zero, b_execution} =
          Transition.step(interposer, :call, Gen.invoke_at(interposer, meta, b, nil))

        # None of B's own edges are reachable from here.
        for {to, edge_need} <- targets do
          outcome =
            Transition.step(
              b_execution,
              :call,
              Gen.invoke_at(b_execution, meta, to, edge_need)
            )

          refute match?({:child, _}, outcome),
                 "trampoline: unbound #{b} reached its own edge to #{to}"
        end

        # Nor is any of B's tool authority.
        assert {:deny, :unbound_control_plane} =
                 Transition.step(b_execution, :call, {:tool, %{tool: "storage", action: "read"}})
      end
    end
  end
end
