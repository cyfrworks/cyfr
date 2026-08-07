# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.ConsumptionPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sanctum.Authority
  alias Sanctum.Authority.Blob
  alias Sanctum.Authority.Transition
  alias Sanctum.Test.AuthorityGen, as: Gen

  # §6 "Separate properties", arm 2 — consumable authority: a child
  # receives exactly the selected edge's resources, no more and no less,
  # and every resource traces to the one consent revision the root was
  # built from.

  property "a child's resources are structurally the selected edge, on one consent" do
    check all({graph, meta} <- Gen.graph(self_edges: false), max_runs: 50) do
      auth = Gen.rooted({graph, meta})
      {:ok, source} = Authority.current_node(auth)

      for {to, need} <- Gen.reachable_edges(meta, source) do
        need_arg = if need == "", do: nil, else: need

        {:child, child} = Transition.step(auth, :call, Gen.invoke_at(auth, meta, to, need_arg))

        # Exactly the edge from the (clamped) blob — nothing merged in
        # from the ingress edge, the callee's node, or anywhere else.
        {:ok, edge} = Blob.lookup_edge(auth.policy, source, to, need)
        assert child.resources == edge

        # Lineage: one consent revision, the root's.
        assert child.consent_id == auth.consent_id
        assert child.profile_id == auth.profile_id
        assert child.source_ref == auth.source_ref

        # Tools not on THIS edge are not consumable, whatever other edges
        # or the ingress may grant.
        granted = MapSet.new(edge.tools)

        for tool_action <- ["storage.read", "storage.write", "execution.run"],
            not MapSet.member?(granted, tool_action) do
          [tool, action] = String.split(tool_action, ".")

          assert {:deny, :tool_not_granted} =
                   Transition.step(child, :call, {:tool, %{tool: tool, action: action}})
        end
      end

      # Zero children consume nothing at all.
      {:child_zero, zero} =
        Transition.step(
          auth,
          :call,
          Gen.invoke_at(auth, meta, "formula:evil.corp.x", Gen.compliant_need(auth, meta))
        )

      assert zero.resources == :none
      assert zero.consent_id == nil
    end
  end
end
